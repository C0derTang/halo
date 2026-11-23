import Foundation
import GRDB
import HaloCore
import Synchronization

/// Encrypted-at-rest local people graph (GRDB + iOS Data Protection `.complete`).
///
/// Invariants enforced here:
/// - `confirmedGallery(space:)` only returns embeddings owned by a `confirmed` person whose space
///   matches exactly (model ID and dimension).
/// - Cluster records only ever hold unassigned embeddings; `confirm(cluster:as:)` is the only
///   enrollment path that turns a clustering suggestion into a recognizable person (invariant 3).
/// - `forget(_:)` and `eraseEverything()` remove every affected row in one transaction, with
///   `PRAGMA secure_delete = ON` so freed pages are zeroed on disk, then fold the WAL back into the
///   main file. If a reader blocks that checkpoint, the erasure stays pending and is retried after
///   every later write (without waiting for readers) and by `flushPendingErasure()` (waiting).
public final class PeopleStore: PeopleStoring, EnrollmentStoring, PrivacyStoring {
    /// How long a checkpoint/write waits for other connections before giving up.
    public static let defaultBusyTimeout: TimeInterval = 2

    let writer: any DatabaseWriter
    /// The connections' configured busy timeout, restored after a no-wait checkpoint attempt.
    let busyTimeout: TimeInterval
    /// True while an erasure's WAL truncate checkpoint has not completed yet. Set only inside an
    /// erasing write transaction and cleared only inside a successful checkpoint. Both run on the
    /// serialized writer, so a checkpoint can never clear the flag for an erasure it did not cover.
    private let erasurePending = Mutex(false)

    /// Opens (or creates) the store at `path`. On iOS the database file and its `-wal`/`-shm`
    /// siblings get `FileProtectionType.complete`. Prefer a dedicated directory such as
    /// `PeopleStore.defaultDirectory()` so files SQLite recreates later inherit the protection.
    public convenience init(path: String) throws {
        try self.init(path: path, busyTimeout: Self.defaultBusyTimeout)
    }

    convenience init(path: String, busyTimeout: TimeInterval) throws {
        try FileProtection.prepareDatabaseFile(at: path)
        let pool = try DatabasePool(path: path, configuration: Self.configuration(busyTimeout: busyTimeout))
        try FileProtection.protectDatabaseFiles(at: path)
        try self.init(writer: pool, busyTimeout: busyTimeout)
    }

    /// A private in-memory store, for tests and previews.
    public static func inMemory() throws -> PeopleStore {
        try PeopleStore(writer: DatabaseQueue(configuration: configuration()))
    }

    /// `Application Support/HaloStore/people.sqlite`, with the directory created and protected.
    public static func defaultPath() throws -> String {
        let directory = try FileProtection.defaultDirectory()
        return directory.appendingPathComponent("people.sqlite").path
    }

    init(writer: any DatabaseWriter, busyTimeout: TimeInterval = defaultBusyTimeout) throws {
        self.writer = writer
        self.busyTimeout = busyTimeout
        try Schema.migrator.migrate(writer)
    }

    static func configuration(busyTimeout: TimeInterval = defaultBusyTimeout) -> Configuration {
        var config = Configuration()
        config.busyMode = .timeout(busyTimeout)
        config.foreignKeysEnabled = true
        config.label = "HaloStore"
        config.prepareDatabase { db in
            // Zero deleted content instead of leaving it in free pages (forget is irreversible).
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        return config
    }

    // MARK: - People

    public func person(_ id: PersonID) async throws -> Person? {
        try await writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM person WHERE id = ?", arguments: [id.description])
                .map(RowDecoding.person)
        }
    }

    public func allPeople() async throws -> [Person] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM person ORDER BY displayName COLLATE NOCASE, id")
                .map(RowDecoding.person)
        }
    }

    public func upsert(_ person: Person) async throws {
        let birthday = try RowDecoding.encodeBirthday(person.birthday)
        try await write { db in
            // ON CONFLICT DO UPDATE (never INSERT OR REPLACE, which would cascade-delete children).
            try db.execute(
                sql: """
                    INSERT INTO person
                        (id, displayName, relationship, birthday, notes, confirmed, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        displayName = excluded.displayName,
                        relationship = excluded.relationship,
                        birthday = excluded.birthday,
                        notes = excluded.notes,
                        confirmed = excluded.confirmed,
                        createdAt = excluded.createdAt,
                        updatedAt = excluded.updatedAt
                    """,
                arguments: [
                    person.id.description, person.displayName, person.relationship, birthday,
                    person.notes, person.confirmed, person.createdAt.storedValue,
                    person.updatedAt.storedValue,
                ])
        }
    }

    // MARK: - Identities

    public func identities(for id: PersonID) async throws -> [Identity] {
        try await writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM identity WHERE personId = ? ORDER BY kind, value",
                arguments: [id.description]
            ).map(RowDecoding.identity)
        }
    }

    /// Idempotent for the same owner; throws `identityConflict` if another person already owns
    /// the (kind, value) pair, so identity resolution never silently reassigns a handle.
    public func addIdentity(_ identity: Identity) async throws {
        try await write { db in try Self.insertIdentity(identity, in: db) }
    }

    static func insertIdentity(_ identity: Identity, in db: Database) throws {
        if let owner = try Row.fetchOne(
            db, sql: "SELECT personId FROM identity WHERE kind = ? AND value = ?",
            arguments: [identity.kind.rawValue, identity.value])
        {
            let existing = try RowDecoding.personID(owner, "personId", table: Schema.identity)
            guard existing == identity.personID else {
                throw PeopleStoreError.identityConflict(
                    kind: identity.kind, value: identity.value, existingOwner: existing)
            }
            return
        }
        try db.execute(
            sql: "INSERT INTO identity (personId, kind, value) VALUES (?, ?, ?)",
            arguments: [identity.personID.description, identity.kind.rawValue, identity.value])
    }

    public func person(matching kind: Identity.Kind, value: String) async throws -> Person? {
        try await writer.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT person.* FROM person
                    JOIN identity ON identity.personId = person.id
                    WHERE identity.kind = ? AND identity.value = ?
                    """,
                arguments: [kind.rawValue, value]
            ).map(RowDecoding.person)
        }
    }

    // MARK: - Embeddings

    public func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] {
        try await writer.read { db in
            // Inner join on a confirmed owner: unassigned (personId NULL) and unconfirmed-person
            // embeddings can never appear. Space must match on both model ID and dimension.
            try Row.fetchAll(
                db,
                sql: """
                    SELECT embedding.* FROM embedding
                    JOIN person ON person.id = embedding.personId
                    WHERE person.confirmed = 1
                      AND embedding.modelID = ?
                      AND embedding.dimension = ?
                    ORDER BY embedding.personId, embedding.createdAt, embedding.id
                    """,
                arguments: [space.modelID, space.dimension]
            ).map(RowDecoding.embedding)
        }
    }

    public func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws {
        for embedding in embeddings where embedding.vector.count != embedding.space.dimension {
            throw PeopleStoreError.dimensionMismatch(
                expected: embedding.space.dimension, actual: embedding.vector.count)
        }
        try await write { db in
            for embedding in embeddings {
                try db.execute(
                    sql: """
                        INSERT INTO embedding
                            (id, personId, modelID, dimension, vector, source, sourceRef, quality, createdAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            personId = excluded.personId,
                            modelID = excluded.modelID,
                            dimension = excluded.dimension,
                            vector = excluded.vector,
                            source = excluded.source,
                            sourceRef = excluded.sourceRef,
                            quality = excluded.quality,
                            createdAt = excluded.createdAt
                        """,
                    arguments: [
                        embedding.id.uuidString, embedding.personID?.description, embedding.space.modelID,
                        embedding.space.dimension, VectorCodec.encode(embedding.vector),
                        embedding.source.rawValue, embedding.sourceRef, Double(embedding.quality),
                        embedding.createdAt.storedValue,
                    ])
            }
            // An embedding that now belongs to someone can no longer sit in a suggestion cluster.
            let assigned = embeddings.filter { $0.personID != nil }.map(\.id)
            if !assigned.isEmpty {
                try Self.detachFromClusters(assigned, in: db)
            }
        }
    }

    // MARK: - Forget / erase

    /// Irreversibly deletes the person, every row that references them, and every suggestion
    /// cluster that pointed at them together with that cluster's member embeddings.
    public func forget(_ id: PersonID) async throws {
        let key = id.description
        try await writer.write { db in
            try Self.scrubDigest(db, forgetting: key)
            // Clusters suggesting this person hold (unassigned) faces that most likely ARE this
            // person: delete those embeddings, then the clusters themselves.
            try db.execute(
                sql: """
                    DELETE FROM embedding WHERE personId IS NULL AND id IN (
                        SELECT cluster_member.embeddingId FROM cluster_member
                        JOIN cluster ON cluster.id = cluster_member.clusterId
                        WHERE cluster.suggestedPersonId = ?)
                    """,
                arguments: [key])
            try db.execute(sql: "DELETE FROM cluster WHERE suggestedPersonId = ?", arguments: [key])
            for table in Schema.personScopedTables {
                try db.execute(sql: "DELETE FROM \(table) WHERE personId = ?", arguments: [key])
            }
            try db.execute(sql: "DELETE FROM person WHERE id = ?", arguments: [key])
            self.markErasurePending()
        }
        await checkpointPendingErasure(waitForReaders: true)
    }

    /// Kill switch: deletes every row of every table (people, identities, embeddings, clusters,
    /// scan cursor, digest, recognition log) in one transaction, then erases the WAL like `forget`.
    public func eraseEverything() async throws {
        try await writer.write { db in
            for table in try Self.dataTables(db) {
                try db.execute(sql: "DELETE FROM \(table.quotedDatabaseIdentifier)")
            }
            self.markErasurePending()
        }
        await checkpointPendingErasure(waitForReaders: true)
    }

    /// Every table holding app data: all user tables except SQLite's and GRDB's own bookkeeping.
    static func dataTables(_ db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                ORDER BY name
                """)
    }

    /// Whether an erasure's on-disk completion (WAL checkpoint) is still waiting on a reader.
    public var hasPendingErasure: Bool { erasurePending.withLock { $0 } }

    /// Completes a pending erasure: folds the WAL (whose frames hold the zeroed pages) back into the
    /// main file, overwriting the pre-delete pages, and truncates the WAL to zero. Waits up to the
    /// busy timeout for readers. The app calls this when it moves to the background. Returns true
    /// when nothing is pending.
    @discardableResult
    public func flushPendingErasure() async -> Bool {
        await checkpointPendingErasure(waitForReaders: true)
    }

    /// Call only from inside a write transaction that deleted data needing on-disk erasure.
    func markErasurePending() {
        erasurePending.withLock { $0 = true }
    }

    /// Truncate-checkpoints the WAL if an erasure is pending. Without `waitForReaders` the
    /// connection's busy timeout is dropped to zero for the attempt, so an ordinary write never
    /// stalls behind a long-lived reader; it is restored afterwards.
    @discardableResult
    private func checkpointPendingErasure(waitForReaders: Bool) async -> Bool {
        guard hasPendingErasure else { return true }
        let restoreMilliseconds = Int((busyTimeout * 1000).rounded())
        do {
            return try await writer.writeWithoutTransaction { db in
                // Re-check on the writer: another checkpoint may have completed meanwhile.
                guard self.hasPendingErasure else { return true }
                if !waitForReaders {
                    try db.execute(sql: "PRAGMA busy_timeout = 0")
                }
                defer {
                    if !waitForReaders {
                        try? db.execute(sql: "PRAGMA busy_timeout = \(restoreMilliseconds)")
                    }
                }
                try db.checkpoint(.truncate)
                // Still on the writer: no erasing write can have committed since the checkpoint.
                self.erasurePending.withLock { $0 = false }
                return true
            }
        } catch {
            // SQLITE_BUSY: a reader still holds an older snapshot. Stay pending; the next write or
            // flush retries.
            return false
        }
    }

    /// Runs a write transaction, then retries any pending erasure without waiting for readers.
    func write<T: Sendable>(
        _ updates: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        let result = try await writer.write(updates)
        await checkpointPendingErasure(waitForReaders: false)
        return result
    }

    /// Removes digest entries whose handle is one of the forgotten person's handle-like
    /// identities (and not also claimed by someone else). Runs inside the forget transaction.
    private static func scrubDigest(_ db: Database, forgetting key: String) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT json FROM digest WHERE id = 1"),
            let json: Data = row["json"]
        else { return }
        // Fail toward deletion: a digest we cannot read cannot be scrubbed, so drop it entirely
        // (the bridge regenerates it) rather than letting forget fail.
        guard var digest = try? JSONDecoder().decode(InteractionDigest.self, from: json) else {
            try db.execute(sql: "DELETE FROM digest")
            return
        }
        let handleKinds: [Identity.Kind] = [.imessageHandle, .phone, .email]
        let kindList = handleKinds.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        let mine = try Set(
            String.fetchAll(
                db, sql: "SELECT value FROM identity WHERE personId = ? AND kind IN (\(kindList))",
                arguments: [key]))
        guard !mine.isEmpty else { return }
        let others = try Set(
            String.fetchAll(
                db, sql: "SELECT value FROM identity WHERE personId <> ? AND kind IN (\(kindList))",
                arguments: [key]))
        let handles = mine.subtracting(others)
        let lowered = Set(handles.map { $0.lowercased() })
        let before = digest.entries.count
        digest.entries.removeAll { handles.contains($0.handle) || lowered.contains($0.handle.lowercased()) }
        guard digest.entries.count != before else { return }
        try db.execute(
            sql: "UPDATE digest SET json = ? WHERE id = 1", arguments: [try JSONEncoder().encode(digest)])
    }

    // MARK: - Digest

    public func latestDigest() async throws -> InteractionDigest? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT json FROM digest WHERE id = 1"),
                let json: Data = row["json"]
            else { return nil }
            return try JSONDecoder().decode(InteractionDigest.self, from: json)
        }
    }

    /// Replaces the stored digest; only the latest is kept.
    public func saveDigest(_ digest: InteractionDigest) async throws {
        let json = try JSONEncoder().encode(digest)
        try await write { db in
            try db.execute(
                sql: """
                    INSERT INTO digest (id, version, generatedAt, json) VALUES (1, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        version = excluded.version,
                        generatedAt = excluded.generatedAt,
                        json = excluded.json
                    """,
                arguments: [digest.version, digest.generatedAt.storedValue, json])
        }
    }

    // MARK: - Recognition log (for the privacy screen)

    /// Records that `id` was recognized at `at`. Deleted with the person on `forget`.
    public func logRecognition(of id: PersonID, at date: Date = Date()) async throws {
        try await write { db in
            try db.execute(
                sql: "INSERT INTO recognition_log (personId, at) VALUES (?, ?)",
                arguments: [id.description, date.storedValue])
        }
    }

    /// Recognition times for `id`, newest first.
    public func recognitionLog(for id: PersonID) async throws -> [Date] {
        try await writer.read { db in
            try Double.fetchAll(
                db, sql: "SELECT at FROM recognition_log WHERE personId = ? ORDER BY at DESC, id DESC",
                arguments: [id.description]
            ).map(Date.init(storedValue:))
        }
    }
}

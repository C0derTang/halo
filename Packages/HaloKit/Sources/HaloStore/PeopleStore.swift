import Foundation
import GRDB
import HaloCore

/// Encrypted-at-rest local people graph (GRDB + iOS Data Protection `.complete`).
///
/// Invariants enforced here:
/// - `confirmedGallery(space:)` only returns embeddings owned by a `confirmed` person whose space
///   matches exactly (model ID and dimension).
/// - `forget(_:)` removes every row that references the person, in one transaction, with
///   `PRAGMA secure_delete = ON` so freed pages are zeroed on disk.
public final class PeopleStore: PeopleStoring {
    let writer: any DatabaseWriter

    /// Opens (or creates) the store at `path`. On iOS the database file and its `-wal`/`-shm`
    /// siblings get `FileProtectionType.complete`. Prefer a dedicated directory such as
    /// `PeopleStore.defaultDirectory()` so files SQLite recreates later inherit the protection.
    public convenience init(path: String) throws {
        try FileProtection.prepareDatabaseFile(at: path)
        let pool = try DatabasePool(path: path, configuration: Self.configuration())
        try FileProtection.protectDatabaseFiles(at: path)
        try self.init(writer: pool)
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

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Schema.migrator.migrate(writer)
    }

    static func configuration() -> Configuration {
        var config = Configuration()
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
        try await writer.write { db in
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
        try await writer.write { db in
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
        try await writer.write { db in
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
        }
    }

    // MARK: - Forget

    public func forget(_ id: PersonID) async throws {
        let key = id.description
        try await writer.write { db in
            try Self.scrubDigest(db, forgetting: key)
            for table in Schema.personScopedTables {
                try db.execute(sql: "DELETE FROM \(table) WHERE personId = ?", arguments: [key])
            }
            try db.execute(sql: "DELETE FROM person WHERE id = ?", arguments: [key])
        }
        // Fold the WAL (whose frames hold the zeroed pages) back into the main file and truncate
        // it, so no pre-delete page images linger in the -wal sibling. Best effort: a concurrent
        // reader can make it SQLITE_BUSY; secure_delete has already zeroed the content.
        try? await writer.writeWithoutTransaction { db in
            _ = try db.checkpoint(.truncate)
        }
    }

    /// Removes digest entries whose handle is one of the forgotten person's handle-like
    /// identities (and not also claimed by someone else). Runs inside the forget transaction.
    private static func scrubDigest(_ db: Database, forgetting key: String) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT json FROM digest WHERE id = 1"),
            let json: Data = row["json"]
        else { return }
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
        var digest = try JSONDecoder().decode(InteractionDigest.self, from: json)
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
        try await writer.write { db in
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
        try await writer.write { db in
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

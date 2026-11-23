import Foundation
import HaloCore
import Testing

@testable import HaloStore

@Suite struct SchemaTests {
    @Test func migrationsRunOnFreshInMemoryDatabase() async throws {
        let store = try PeopleStore.inMemory()
        #expect(try await store.appliedMigrations() == ["v1", "v2", "v3_faceBox", "v4_memoryHooks"])
        #expect(
            try await store.userTables() == [
                "cluster", "cluster_member", "digest", "embedding", "identity", "memory_hook", "person",
                "recognition_log", "scan_state",
            ])
    }

    @Test func migrationsRunOnFreshFileDatabaseAndPersistAcrossReopen() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }

        let person = Fixture.person("Reopen Test", confirmed: true)
        do {
            let store = try PeopleStore(path: path)
            #expect(try await store.appliedMigrations() == ["v1", "v2", "v3_faceBox", "v4_memoryHooks"])
            try await store.upsert(person)
        }
        let reopened = try PeopleStore(path: path)
        #expect(try await reopened.appliedMigrations() == ["v1", "v2", "v3_faceBox", "v4_memoryHooks"])
        #expect(try await reopened.person(person.id) == person)
    }

    @Test func secureDeletePragmaIsOnInMemory() async throws {
        let store = try PeopleStore.inMemory()
        let value = try await store.pragma("secure_delete")
        #expect(value.reader == 1)
        #expect(value.writer == 1)
    }

    @Test func secureDeletePragmaIsOnForEveryPoolConnection() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PeopleStore(path: path)
        let value = try await store.pragma("secure_delete")
        #expect(value.reader == 1)
        #expect(value.writer == 1)
        #expect(try await store.pragma("foreign_keys").writer == 1)
    }

    @Test func protectedFilesIncludeWALSiblings() {
        #expect(
            FileProtection.databaseFilePaths(for: "/x/people.sqlite") == [
                "/x/people.sqlite", "/x/people.sqlite-wal", "/x/people.sqlite-shm",
            ])
    }
}

@Suite struct PersonTests {
    @Test func crudRoundTrip() async throws {
        let store = try PeopleStore.inMemory()
        var person = Fixture.person("Alex Example", confirmed: false)
        person.birthday = DateComponents(year: 1990, month: 2, day: 28)

        #expect(try await store.person(person.id) == nil)
        try await store.upsert(person)
        #expect(try await store.person(person.id) == person)

        person.displayName = "Alex Q. Example"
        person.relationship = nil
        person.birthday = DateComponents(month: 7, day: 4)
        person.notes = nil
        person.confirmed = true
        person.updatedAt = Fixture.fixedDate.addingTimeInterval(1.5)
        try await store.upsert(person)
        #expect(try await store.person(person.id) == person)

        let other = Fixture.person("Blake Example", confirmed: true)
        try await store.upsert(other)
        #expect(try await store.allPeople() == [person, other])
    }

    @Test func upsertDoesNotCascadeDeleteChildren() async throws {
        let store = try PeopleStore.inMemory()
        var person = Fixture.person("Casey Example", confirmed: true)
        try await store.upsert(person)
        try await store.addIdentity(Identity(personID: person.id, kind: .email, value: "casey@example.com"))
        try await store.addEmbeddings([Fixture.embedding(for: person.id)])

        person.displayName = "Casey Renamed"
        try await store.upsert(person)

        #expect(try await store.identities(for: person.id).count == 1)
        #expect(try await store.confirmedGallery(space: Fixture.spaceA).count == 1)
    }
}

@Suite struct IdentityTests {
    @Test func identityLookupAndUniqueness() async throws {
        let store = try PeopleStore.inMemory()
        let alex = Fixture.person("Alex Example", confirmed: true)
        let blake = Fixture.person("Blake Example", confirmed: false)
        try await store.upsert(alex)
        try await store.upsert(blake)

        let phone = Identity(personID: alex.id, kind: .phone, value: "+15550000001")
        try await store.addIdentity(phone)
        try await store.addIdentity(phone)  // idempotent for the same owner
        try await store.addIdentity(Identity(personID: alex.id, kind: .email, value: "alex@example.com"))
        // Same value under a different kind is a different identity.
        try await store.addIdentity(
            Identity(personID: blake.id, kind: .imessageHandle, value: "+15550000001"))

        #expect(try await store.identities(for: alex.id).count == 2)
        #expect(try await store.person(matching: .phone, value: "+15550000001") == alex)
        #expect(try await store.person(matching: .imessageHandle, value: "+15550000001") == blake)
        #expect(try await store.person(matching: .email, value: "alex@example.com") == alex)
        #expect(try await store.person(matching: .email, value: "nobody@example.com") == nil)
        #expect(try await store.person(matching: .contact, value: "+15550000001") == nil)

        await #expect(
            throws: PeopleStoreError.identityConflict(
                kind: .phone, value: "+15550000001", existingOwner: alex.id)
        ) {
            try await store.addIdentity(Identity(personID: blake.id, kind: .phone, value: "+15550000001"))
        }
        #expect(try await store.person(matching: .phone, value: "+15550000001") == alex)
        #expect(try await store.identities(for: blake.id).count == 1)
    }

    @Test func identityForUnknownPersonIsRejected() async throws {
        let store = try PeopleStore.inMemory()
        await #expect(throws: (any Error).self) {
            try await store.addIdentity(
                Identity(personID: PersonID(), kind: .email, value: "ghost@example.com"))
        }
        #expect(try await store.rowCount("identity") == 0)
    }
}

@Suite struct GalleryTests {
    @Test func galleryExcludesUnconfirmedUnassignedAndOtherSpaces() async throws {
        let store = try PeopleStore.inMemory()
        let confirmed = Fixture.person("Confirmed Example", confirmed: true)
        let unconfirmed = Fixture.person("Suggested Example", confirmed: false)
        try await store.upsert(confirmed)
        try await store.upsert(unconfirmed)

        let good = [
            Fixture.embedding(for: confirmed.id, seed: 0.1), Fixture.embedding(for: confirmed.id, seed: 0.2),
        ]
        try await store.addEmbeddings(good)
        try await store.addEmbeddings([
            Fixture.embedding(for: unconfirmed.id),
            Fixture.embedding(for: nil),
            Fixture.embedding(for: confirmed.id, space: Fixture.spaceOtherModel),
            Fixture.embedding(for: confirmed.id, space: Fixture.spaceSameModelOtherDim),
        ])

        let gallery = try await store.confirmedGallery(space: Fixture.spaceA)
        #expect(Set(gallery) == Set(good))
        #expect(gallery.allSatisfy { $0.personID == confirmed.id && $0.space == Fixture.spaceA })

        #expect(try await store.confirmedGallery(space: Fixture.spaceOtherModel).count == 1)
        #expect(try await store.confirmedGallery(space: Fixture.spaceSameModelOtherDim).count == 1)
        #expect(
            try await store.confirmedGallery(space: EmbeddingSpace(modelID: "unknown", dimension: 4)).isEmpty)
    }

    @Test func confirmationStateControlsGalleryMembership() async throws {
        let store = try PeopleStore.inMemory()
        var person = Fixture.person("Pending Example", confirmed: false)
        try await store.upsert(person)
        try await store.addEmbeddings([Fixture.embedding(for: person.id)])
        #expect(try await store.confirmedGallery(space: Fixture.spaceA).isEmpty)

        person.confirmed = true
        try await store.upsert(person)
        #expect(try await store.confirmedGallery(space: Fixture.spaceA).count == 1)

        person.confirmed = false
        try await store.upsert(person)
        #expect(try await store.confirmedGallery(space: Fixture.spaceA).isEmpty)
    }

    @Test func dimensionMismatchIsRejectedAtomically() async throws {
        let store = try PeopleStore.inMemory()
        let person = Fixture.person("Dim Example", confirmed: true)
        try await store.upsert(person)
        var bad = Fixture.embedding(for: person.id)
        bad.vector = [1, 2, 3]
        await #expect(throws: PeopleStoreError.dimensionMismatch(expected: 4, actual: 3)) {
            try await store.addEmbeddings([Fixture.embedding(for: person.id), bad])
        }
        #expect(try await store.rowCount("embedding") == 0)
    }
}

@Suite struct VectorCodecTests {
    static let specials: [Float] = [
        0, -0.0, 1, -1, .pi, .infinity, -.infinity, .leastNonzeroMagnitude, -.leastNormalMagnitude,
        .greatestFiniteMagnitude, Float(bitPattern: 0x7FC0_1234), Float(bitPattern: 0xFFA0_0001),
    ]

    @Test func encodingIsLittleEndianFloat32() {
        #expect([UInt8](VectorCodec.encode([1.0])) == [0x00, 0x00, 0x80, 0x3F])
        #expect(
            [UInt8](VectorCodec.encode([-2.0, 0.5])) == [0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x3F])
        #expect(VectorCodec.encode(Self.specials).count == Self.specials.count * 4)
    }

    @Test func decodeRejectsTruncatedBlob() {
        #expect(VectorCodec.decode(Data([0, 0, 0x80])) == nil)
        #expect(VectorCodec.decode(Data()) == [])
    }

    @Test func storeRoundTripIsBitExact() async throws {
        let store = try PeopleStore.inMemory()
        let person = Fixture.person("Bits Example", confirmed: true)
        try await store.upsert(person)
        var random = SystemRandomNumberGenerator()
        let randomBits = (0..<500).map { _ in
            Float(bitPattern: UInt32.random(in: .min ... .max, using: &random))
        }
        let vector = Self.specials + randomBits
        let space = EmbeddingSpace(modelID: "synthetic-bits", dimension: vector.count)
        let embedding = FaceEmbedding(
            personID: person.id, space: space, vector: vector, source: .photoLibrary, quality: 0.3,
            createdAt: Fixture.fixedDate)
        try await store.addEmbeddings([embedding])

        let stored = try #require(try await store.confirmedGallery(space: space).first)
        #expect(stored.vector.map(\.bitPattern) == vector.map(\.bitPattern))
        #expect(stored.id == embedding.id)
        #expect(stored.quality.bitPattern == embedding.quality.bitPattern)
        #expect(stored.createdAt == embedding.createdAt)
        #expect(stored.source == .photoLibrary)
    }
}

@Suite struct DigestTests {
    static func digest(_ handles: [String], at seconds: TimeInterval) -> InteractionDigest {
        InteractionDigest(
            generatedAt: Date(timeIntervalSinceReferenceDate: seconds),
            entries: handles.map {
                InteractionDigest.Entry(
                    handle: $0, lastMessageAt: Fixture.fixedDate, lastFromMeAt: nil,
                    lastFromThemAt: Fixture.fixedDate, messagesLast30Days: 3, messagesAllTime: 42,
                    awaitingMyReply: true)
            })
    }

    @Test func saveAndLatest() async throws {
        let store = try PeopleStore.inMemory()
        #expect(try await store.latestDigest() == nil)

        let first = Self.digest(["+15550000001"], at: 1000.25)
        try await store.saveDigest(first)
        #expect(try await store.latestDigest() == first)

        let second = Self.digest(["+15550000002", "someone@example.com"], at: 2000.5)
        try await store.saveDigest(second)
        #expect(try await store.latestDigest() == second)
        #expect(try await store.rowCount("digest") == 1)
    }
}

@Suite struct ForgetTests {
    /// Builds a person who appears in every table, plus a bystander who must survive.
    static func populate(_ store: PeopleStore) async throws -> (target: Person, bystander: Person) {
        let target = Fixture.person("Forget Me", confirmed: true)
        let bystander = Fixture.person("Keep Me", confirmed: true)
        try await store.upsert(target)
        try await store.upsert(bystander)

        try await store.addIdentity(Identity(personID: target.id, kind: .phone, value: "+15550000009"))
        try await store.addIdentity(
            Identity(personID: target.id, kind: .imessageHandle, value: "Target@Example.com"))
        try await store.addIdentity(
            Identity(personID: target.id, kind: .contact, value: "synthetic-contact-1"))
        try await store.addIdentity(Identity(personID: target.id, kind: .photoCluster, value: "cluster-7"))
        try await store.addIdentity(Identity(personID: bystander.id, kind: .phone, value: "+15550000002"))

        try await store.addEmbeddings([
            Fixture.embedding(for: target.id, seed: 0.1),
            Fixture.embedding(for: target.id, seed: 0.2),
            Fixture.embedding(for: target.id, space: Fixture.spaceOtherModel),
            Fixture.embedding(for: bystander.id, seed: 0.3),
            Fixture.embedding(for: nil),
        ])
        try await store.logRecognition(of: target.id, at: Fixture.fixedDate)
        try await store.logRecognition(of: target.id, at: Fixture.fixedDate.addingTimeInterval(60))
        try await store.logRecognition(of: bystander.id, at: Fixture.fixedDate)
        try await store.saveDigest(
            DigestTests.digest(["+15550000009", "target@example.com", "+15550000002"], at: 3000))
        return (target, bystander)
    }

    static func assertForgotten(_ store: PeopleStore, target: Person, bystander: Person) async throws {
        // Zero rows mention the person anywhere, in any table (incl. digest JSON).
        let mentions = try await store.rowsMentioning(target.id)
        #expect(!mentions.isEmpty)
        for (table, count) in mentions {
            #expect(count == 0, "table \(table) still references the forgotten person")
        }
        #expect(try await store.person(target.id) == nil)
        #expect(try await store.identities(for: target.id).isEmpty)
        #expect(try await store.recognitionLog(for: target.id).isEmpty)
        #expect(try await store.person(matching: .phone, value: "+15550000009") == nil)
        #expect(try await store.person(matching: .photoCluster, value: "cluster-7") == nil)
        for space in [Fixture.spaceA, Fixture.spaceOtherModel] {
            #expect(try await store.confirmedGallery(space: space).allSatisfy { $0.personID != target.id })
        }
        let handles = try #require(try await store.latestDigest()).entries.map(\.handle)
        #expect(handles == ["+15550000002"])

        // The bystander and unassigned embeddings are untouched.
        #expect(try await store.person(bystander.id) == bystander)
        #expect(try await store.identities(for: bystander.id).count == 1)
        #expect(try await store.recognitionLog(for: bystander.id) == [Fixture.fixedDate])
        #expect(try await store.confirmedGallery(space: Fixture.spaceA).count == 1)
        #expect(try await store.rowCount("embedding") == 2)
        #expect(try await store.rowCount("identity") == 1)
        #expect(try await store.rowCount("recognition_log") == 1)
        #expect(try await store.rowCount("person") == 1)
    }

    @Test func forgetCascadeLeavesZeroRowsInMemory() async throws {
        let store = try PeopleStore.inMemory()
        let (target, bystander) = try await Self.populate(store)
        #expect(try await store.recognitionLog(for: target.id).count == 2)
        #expect(try await store.rowsMentioning(target.id).values.reduce(0, +) > 0)

        try await store.forget(target.id)
        try await Self.assertForgotten(store, target: target, bystander: bystander)
    }

    /// Raw database files under `path` that still contain any trace of `person` (name, UUID or one
    /// of the synthetic handles `populate` gave them).
    static func rawTraces(of person: Person, at path: String) -> [String] {
        let needles = [
            person.displayName, person.id.description, "+15550000009", "Target@Example.com",
            "target@example.com", "synthetic-contact-1", "cluster-7",
        ]
        var traces: [String] = []
        for file in FileProtection.databaseFilePaths(for: path) {
            guard let bytes = FileManager.default.contents(atPath: file) else { continue }
            for needle in needles where bytes.range(of: Data(needle.utf8)) != nil {
                traces.append("\((file as NSString).lastPathComponent): \(needle)")
            }
        }
        return traces
    }

    @Test func forgetErasesRawFilesWhileStoreIsStillOpen() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PeopleStore(path: path)
        let (target, bystander) = try await Self.populate(store)
        #expect(!Self.rawTraces(of: target, at: path).isEmpty)

        try await store.forget(target.id)

        // Store still open: secure_delete zeroed the cells and the truncate checkpoint folded the
        // WAL into the main file, so neither the main db nor the -wal holds any trace.
        #expect(!store.hasPendingErasure)
        #expect(Self.rawTraces(of: target, at: path) == [])
        try await Self.assertForgotten(store, target: target, bystander: bystander)

        let reopened = try PeopleStore(path: path)
        try await Self.assertForgotten(reopened, target: target, bystander: bystander)
    }

    @Test func blockedCheckpointStaysPendingUntilFlushed() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PeopleStore(path: path, busyTimeout: 0.05)
        let (target, bystander) = try await Self.populate(store)
        #expect(await store.flushPendingErasure())  // nothing pending yet

        // A reader pinned to a pre-forget snapshot blocks the truncate checkpoint.
        let reader = store.holdReadTransaction()
        try await store.forget(target.id)
        #expect(store.hasPendingErasure)
        #expect(!Self.rawTraces(of: target, at: path).isEmpty)  // old pages still in the main db
        #expect(await store.flushPendingErasure() == false)
        try await store.logRecognition(of: bystander.id, at: Fixture.fixedDate)  // write-retry fails too
        #expect(store.hasPendingErasure)
        // Logically gone already, even before the on-disk erasure completes.
        #expect(try await store.person(target.id) == nil)
        #expect(try await store.rowsMentioning(target.id).values.reduce(0, +) == 0)

        reader.release()
        #expect(await store.flushPendingErasure())
        #expect(!store.hasPendingErasure)
        #expect(Self.rawTraces(of: target, at: path) == [])
    }

    @Test func pendingErasureIsRetriedOnNextWrite() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PeopleStore(path: path, busyTimeout: 0.05)
        let (target, bystander) = try await Self.populate(store)

        let reader = store.holdReadTransaction()
        try await store.forget(target.id)
        #expect(store.hasPendingErasure)
        reader.release()

        var edited = bystander
        edited.notes = "Edited after forget"
        try await store.upsert(edited)
        #expect(!store.hasPendingErasure)
        #expect(Self.rawTraces(of: target, at: path) == [])
    }

    @Test func forgetDropsUndecodableDigestInsteadOfFailing() async throws {
        let store = try PeopleStore.inMemory()
        let (target, bystander) = try await Self.populate(store)
        try await store.overwriteDigestJSON(Data("not a digest \(target.id)".utf8))

        try await store.forget(target.id)

        #expect(try await store.latestDigest() == nil)
        #expect(try await store.rowCount("digest") == 0)
        #expect(try await store.rowsMentioning(target.id).values.reduce(0, +) == 0)
        #expect(try await store.person(target.id) == nil)
        #expect(try await store.person(bystander.id) == bystander)
    }

    @Test func forgetUnknownPersonIsNoOp() async throws {
        let store = try PeopleStore.inMemory()
        let (_, bystander) = try await Self.populate(store)
        try await store.forget(PersonID())
        #expect(try await store.rowCount("person") == 2)
        #expect(try await store.person(bystander.id) == bystander)
    }

    @Test func forgetKeepsDigestHandlesClaimedByAnotherPerson() async throws {
        let store = try PeopleStore.inMemory()
        let target = Fixture.person("Shared Handle Target", confirmed: true)
        let other = Fixture.person("Shared Handle Other", confirmed: true)
        try await store.upsert(target)
        try await store.upsert(other)
        try await store.addIdentity(Identity(personID: target.id, kind: .phone, value: "+15550000077"))
        try await store.addIdentity(
            Identity(personID: other.id, kind: .imessageHandle, value: "+15550000077"))
        try await store.saveDigest(DigestTests.digest(["+15550000077"], at: 10))

        try await store.forget(target.id)
        #expect(try await store.latestDigest()?.entries.map(\.handle) == ["+15550000077"])
        #expect(try await store.rowsMentioning(target.id).values.reduce(0, +) == 0)
    }
}

@Suite struct RecognitionLogTests {
    @Test func logIsNewestFirst() async throws {
        let store = try PeopleStore.inMemory()
        let person = Fixture.person("Log Example", confirmed: true)
        try await store.upsert(person)
        let early = Fixture.fixedDate
        let late = early.addingTimeInterval(3600)
        try await store.logRecognition(of: person.id, at: early)
        try await store.logRecognition(of: person.id, at: late)
        #expect(try await store.recognitionLog(for: person.id) == [late, early])
    }
}

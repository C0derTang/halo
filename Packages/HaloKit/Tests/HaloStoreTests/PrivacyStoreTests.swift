import Foundation
import HaloCore
import Testing

@testable import HaloStore

@Suite struct ForgetSuggestedClusterTests {
    @Test func forgetDeletesSuggestedClustersAndTheirMembers() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let world = try await EnrollmentWorld(store: PeopleStore(path: path))
        let store = world.store
        let other = Fixture.person("Other Known", confirmed: true)
        try await store.upsert(other)
        try await store.replaceClusters([
            world.cluster("looks-like-known", world.ids(0, 1), suggested: world.known.id),
            world.cluster("looks-like-other", world.ids(2, 3), suggested: other.id),
            world.cluster("no-suggestion", world.ids(4)),
        ])
        let doomed = world.faces[0...1].flatMap(Fixture.needles(for:))
        #expect(!Fixture.rawTraces(of: doomed, at: path).isEmpty)

        try await store.forget(world.known.id)

        #expect(try await store.clusters().map(\.id) == ["looks-like-other", "no-suggestion"])
        #expect(try await store.embeddings(ids: world.ids(0, 1)).isEmpty)
        #expect(try await store.embeddings(ids: world.ids(2, 3, 4, 5)).count == 4)
        #expect(try await store.rowCount("cluster_member") == 3)
        for (table, count) in try await store.rowsMentioning(world.known.id) {
            #expect(count == 0, "table \(table) still references the forgotten person")
        }
        // Store still open, no reader: the suggested faces are gone from the raw files too.
        #expect(!store.hasPendingErasure)
        #expect(Fixture.rawTraces(of: doomed, at: path) == [])
        #expect(!Fixture.rawTraces(of: Fixture.needles(for: world.faces[2]), at: path).isEmpty)
    }

    @Test func forgetOfConfirmedClusterPersonRemovesTheEnrolledFaces() async throws {
        let world = try await EnrollmentWorld()
        let store = world.store
        try await store.replaceClusters([world.cluster("cluster-x", world.ids(0, 1))])
        try await store.confirm(cluster: "cluster-x", as: world.newcomer.id)

        try await store.forget(world.newcomer.id)

        #expect(try await store.embeddings(ids: world.ids(0, 1)).isEmpty)
        #expect(try await store.person(matching: .photoCluster, value: "cluster-x") == nil)
        #expect(try await store.rowsMentioning(world.newcomer.id).values.reduce(0, +) == 0)
    }
}

@Suite struct EraseEverythingTests {
    /// Populates every data table, returning raw-byte needles for everything personal.
    static func populateEverything(_ store: PeopleStore) async throws -> [Data] {
        let world = try await EnrollmentWorld(store: store)
        try await store.addIdentity(
            Identity(personID: world.known.id, kind: .phone, value: "+15550000041"))
        try await store.replaceClusters([world.cluster("cluster-erase-me", world.ids(0, 1, 2))])
        try await store.confirm(cluster: "cluster-erase-me", as: world.newcomer.id)
        try await store.replaceClusters([
            world.cluster("cluster-pending-41", world.ids(3, 4), suggested: world.known.id)
        ])
        try await store.setScanCursor("synthetic-scan-cursor-41")
        try await store.logRecognition(of: world.known.id, at: Fixture.fixedDate)
        try await store.saveDigest(DigestTests.digest(["+15550000041"], at: 41))
        try await store.addHook(
            MemoryHook(personID: world.known.id, text: "synthetic-hook-41", source: .userNote))

        for table in try await store.userTables() {
            #expect(try await store.rowCount(table) > 0, "fixture leaves \(table) empty")
        }
        let strings = [
            world.known.displayName, world.newcomer.displayName, world.known.id.description,
            world.newcomer.id.description, "+15550000041", "cluster-erase-me", "cluster-pending-41",
            "synthetic-scan-cursor-41", "synthetic-hook-41",
        ]
        return strings.map { Data($0.utf8) } + world.faces.flatMap(Fixture.needles(for:))
    }

    @Test func eraseEverythingLeavesEveryTableEmptyAndTheFilesClean() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PeopleStore(path: path)
        let needles = try await Self.populateEverything(store)
        #expect(!Fixture.rawTraces(of: needles, at: path).isEmpty)

        try await store.eraseEverything()

        for table in try await store.userTables() {
            #expect(try await store.rowCount(table) == 0, "table \(table) not erased")
        }
        #expect(!store.hasPendingErasure)
        #expect(Fixture.rawTraces(of: needles, at: path) == [])
        #expect(try await store.appliedMigrations() == ["v1", "v2", "v4_memoryHooks"])  // schema survives

        // Still usable afterwards, and the erasure holds across a reopen.
        try await store.upsert(Fixture.person("Fresh Start", confirmed: true))
        let reopened = try PeopleStore(path: path)
        #expect(try await reopened.allPeople().map(\.displayName) == ["Fresh Start"])
        #expect(try await reopened.scanCursor() == nil)
    }

    @Test func eraseEverythingInMemory() async throws {
        let store = try PeopleStore.inMemory()
        _ = try await Self.populateEverything(store)
        try await store.eraseEverything()
        for table in try await store.userTables() {
            #expect(try await store.rowCount(table) == 0, "table \(table) not erased")
        }
    }

    @Test func eraseBlockedByReaderStaysPendingUntilFlushed() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PeopleStore(path: path, busyTimeout: 0.05)
        let needles = try await Self.populateEverything(store)

        let reader = store.holdReadTransaction()
        try await store.eraseEverything()
        #expect(store.hasPendingErasure)
        #expect(try await store.rowCount("person") == 0)  // logically gone already
        #expect(await store.flushPendingErasure() == false)

        reader.release()
        #expect(await store.flushPendingErasure())
        #expect(!store.hasPendingErasure)
        #expect(Fixture.rawTraces(of: needles, at: path) == [])
    }
}

@Suite struct PendingErasureTests {
    @Test func ordinaryWriteDoesNotWaitForReadersWhileErasureIsPending() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A long busy timeout: forget/flush wait it out, ordinary writes must not.
        let store = try PeopleStore(path: path, busyTimeout: 1)
        let (target, bystander) = try await ForgetTests.populate(store)

        let reader = store.holdReadTransaction()
        try await store.forget(target.id)  // waits ~1 s for the reader, then stays pending
        #expect(store.hasPendingErasure)

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await store.logRecognition(of: bystander.id, at: Fixture.fixedDate)
        }
        #expect(elapsed < .milliseconds(200), "ordinary write blocked for \(elapsed)")
        #expect(store.hasPendingErasure)
        // The no-wait attempt restored the configured busy timeout.
        #expect(try await store.pragma("busy_timeout").writer == 1000)

        reader.release()
        #expect(await store.flushPendingErasure())
        #expect(ForgetTests.rawTraces(of: target, at: path) == [])
    }

    @Test func overlappingForgetsNeverLoseThePendingFlag() async throws {
        for round in 0..<4 {
            let (directory, path) = try Fixture.temporaryDatabasePath()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try PeopleStore(path: path, busyTimeout: 0.02)
            var people: [(Person, FaceEmbedding)] = []
            for index in 0..<6 {
                let person = Fixture.person("Overlap \(round)-\(index) Example", confirmed: true)
                let face = Fixture.traceableEmbedding(for: person.id, tag: round * 100 + index)
                try await store.upsert(person)
                try await store.addEmbeddings([face])
                people.append((person, face))
            }
            let needles = people.flatMap { [Data($0.0.displayName.utf8)] + Fixture.needles(for: $0.1) }

            let reader = store.holdReadTransaction()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (person, _) in people {
                    group.addTask { try await store.forget(person.id) }
                }
                // Release the reader while other forgets are still in flight.
                try await group.next()
                reader.release()
                try await group.waitForAll()
            }

            // Whenever the flag reads clear, the on-disk erasure of EVERY forget must be complete.
            if !store.hasPendingErasure {
                #expect(Fixture.rawTraces(of: needles, at: path) == [], "round \(round)")
            }
            #expect(await store.flushPendingErasure())
            #expect(Fixture.rawTraces(of: needles, at: path) == [], "round \(round)")
            #expect(try await store.rowCount("person") == 0)
        }
    }
}

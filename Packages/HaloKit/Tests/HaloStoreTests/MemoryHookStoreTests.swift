import Foundation
import HaloCore
import Testing

@testable import HaloStore

@Suite struct MemoryHookStoreTests {
    static let now = Fixture.fixedDate

    static func hook(
        _ person: PersonID, _ text: String, source: MemoryHook.Source = .userNote, age: TimeInterval = 0,
        expiresIn: TimeInterval? = nil
    ) -> MemoryHook {
        MemoryHook(
            personID: person, text: text, source: source, createdAt: now.addingTimeInterval(-age),
            expiresAt: expiresIn.map { now.addingTimeInterval($0) })
    }

    @Test func addAndFetchRoundTripsNewestFirst() async throws {
        let store = try PeopleStore.inMemory()
        let person = Fixture.person("Hook Person", confirmed: true)
        try await store.upsert(person)
        let old = Self.hook(person.id, "older hook", age: 100)
        let new = Self.hook(person.id, "newer hook", source: .moment, age: 10, expiresIn: 3600)
        try await store.addHook(old)
        try await store.addHook(new)
        #expect(try await store.hooks(for: person.id, now: Self.now) == [new, old])
    }

    @Test func hooksAreScopedPerPerson() async throws {
        let store = try PeopleStore.inMemory()
        let a = Fixture.person("A Hook", confirmed: true)
        let b = Fixture.person("B Hook", confirmed: true)
        try await store.upsert(a)
        try await store.upsert(b)
        try await store.addHook(Self.hook(a.id, "for a"))
        #expect(try await store.hooks(for: b.id, now: Self.now).isEmpty)
    }

    @Test func addForUnknownPersonOrDuplicateIDThrows() async throws {
        let store = try PeopleStore.inMemory()
        let person = Fixture.person("Dup", confirmed: true)
        try await store.upsert(person)
        let ghost = PersonID()
        await #expect(throws: PeopleStoreError.unknownPerson(ghost)) {
            try await store.addHook(Self.hook(ghost, "orphan"))
        }
        let hook = Self.hook(person.id, "once")
        try await store.addHook(hook)
        await #expect(throws: (any Error).self) { try await store.addHook(hook) }
        #expect(try await store.rowCount("memory_hook") == 1)
    }

    @Test func deleteRemovesOnlyThatHook() async throws {
        let store = try PeopleStore.inMemory()
        let person = Fixture.person("Del", confirmed: true)
        try await store.upsert(person)
        let keep = Self.hook(person.id, "keep")
        let drop = Self.hook(person.id, "drop")
        try await store.addHook(keep)
        try await store.addHook(drop)
        try await store.deleteHook(id: drop.id)
        try await store.deleteHook(id: UUID())  // unknown id is a no-op
        #expect(try await store.hooks(for: person.id, now: Self.now) == [keep])
    }

    @Test func expiredHooksAreHiddenAtTheBoundary() async throws {
        let store = try PeopleStore.inMemory()
        let person = Fixture.person("Expiry", confirmed: true)
        try await store.upsert(person)
        let forever = Self.hook(person.id, "no expiry", age: 3)
        let future = Self.hook(person.id, "future", age: 2, expiresIn: 1)
        let exactly = Self.hook(person.id, "exactly now", age: 1, expiresIn: 0)
        let past = Self.hook(person.id, "past", age: 0, expiresIn: -1)
        for hook in [forever, future, exactly, past] { try await store.addHook(hook) }

        #expect(try await store.hooks(for: person.id, now: Self.now) == [future, forever])
        let later = Self.now.addingTimeInterval(2)
        #expect(try await store.hooks(for: person.id, now: later) == [forever])
        let earlier = Self.now.addingTimeInterval(-10)
        #expect(try await store.hooks(for: person.id, now: earlier).count == 4)
    }

    @Test func replaceSwapsOnlyTheGivenSource() async throws {
        let store = try PeopleStore.inMemory()
        let person = Fixture.person("Replace", confirmed: true)
        let other = Fixture.person("Bystander", confirmed: true)
        try await store.upsert(person)
        try await store.upsert(other)
        let note = Self.hook(person.id, "my note", source: .userNote, age: 50)
        let stale = Self.hook(person.id, "stale summary", source: .onDeviceSummary, age: 40)
        let bystander = Self.hook(other.id, "other summary", source: .onDeviceSummary)
        for hook in [note, stale, bystander] { try await store.addHook(hook) }

        let fresh1 = Self.hook(person.id, "fresh one", source: .onDeviceSummary, age: 2)
        let fresh2 = Self.hook(person.id, "fresh two", source: .onDeviceSummary, age: 1)
        try await store.replaceHooks(for: person.id, source: .onDeviceSummary, with: [fresh1, fresh2])
        #expect(try await store.hooks(for: person.id, now: Self.now) == [fresh2, fresh1, note])
        #expect(try await store.hooks(for: other.id, now: Self.now) == [bystander])

        try await store.replaceHooks(for: person.id, source: .onDeviceSummary, with: [])
        #expect(try await store.hooks(for: person.id, now: Self.now) == [note])
    }

    @Test func failedReplaceLeavesPreviousHooksIntact() async throws {
        let store = try PeopleStore.inMemory()
        let person = Fixture.person("Atomic", confirmed: true)
        try await store.upsert(person)
        let existing = Self.hook(person.id, "existing summary", source: .onDeviceSummary)
        try await store.addHook(existing)

        // Duplicate IDs fail on the second insert, after the old rows were already deleted.
        let first = Self.hook(person.id, "new one", source: .onDeviceSummary)
        var clash = Self.hook(person.id, "new two", source: .onDeviceSummary)
        clash.id = first.id
        await #expect(throws: (any Error).self) {
            try await store.replaceHooks(for: person.id, source: .onDeviceSummary, with: [first, clash])
        }
        #expect(try await store.hooks(for: person.id, now: Self.now) == [existing])

        // A hook for someone else is rejected up front.
        let stranger = Self.hook(PersonID(), "wrong owner", source: .onDeviceSummary)
        await #expect(throws: PeopleStoreError.hookPersonMismatch(hook: stranger.id, expected: person.id)) {
            try await store.replaceHooks(for: person.id, source: .onDeviceSummary, with: [stranger])
        }
        #expect(try await store.hooks(for: person.id, now: Self.now) == [existing])
    }

    @Test func hooksSurviveReopen() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let person = Fixture.person("Persist", confirmed: true)
        let hook = Self.hook(person.id, "persisted hook", expiresIn: 60)
        do {
            let store = try PeopleStore(path: path)
            try await store.upsert(person)
            try await store.addHook(hook)
        }
        let reopened = try PeopleStore(path: path)
        #expect(try await reopened.hooks(for: person.id, now: Self.now) == [hook])
    }
}

@Suite struct MemoryPrivacyTests {
    static let hookText = "synthetic-hook-text-zq81"
    static let excerptText = "synthetic-excerpt-text-kd47"
    static let handle = "+15550000058"

    static func digestWithExcerpts() -> InteractionDigest {
        func entry(_ handle: String, _ text: String) -> InteractionDigest.Entry {
            InteractionDigest.Entry(
                handle: handle, lastMessageAt: Fixture.fixedDate, lastFromMeAt: nil,
                lastFromThemAt: Fixture.fixedDate, messagesLast30Days: 2, messagesAllTime: 9,
                awaitingMyReply: false,
                recentMessages: [
                    InteractionDigest.DigestMessage(date: Fixture.fixedDate, fromMe: false, text: text),
                    InteractionDigest.DigestMessage(date: Fixture.fixedDate, fromMe: true, text: "ok"),
                ])
        }
        return InteractionDigest(
            generatedAt: Fixture.fixedDate,
            entries: [entry(handle, excerptText), entry("+15550000059", "bystander-excerpt-text-mm02")])
    }

    /// Target and bystander, each with hooks; target also has a digest entry with excerpts.
    static func populate(_ store: PeopleStore) async throws -> (target: Person, bystander: Person) {
        let target = Fixture.person("Hook Target", confirmed: true)
        let bystander = Fixture.person("Hook Bystander", confirmed: true)
        try await store.upsert(target)
        try await store.upsert(bystander)
        try await store.addIdentity(Identity(personID: target.id, kind: .imessageHandle, value: handle))
        try await store.addIdentity(
            Identity(personID: bystander.id, kind: .imessageHandle, value: "+15550000059"))
        try await store.addHook(MemoryHookStoreTests.hook(target.id, hookText))
        try await store.addHook(
            MemoryHookStoreTests.hook(
                target.id, hookText + "-summary", source: .onDeviceSummary, expiresIn: 3600))
        try await store.addHook(MemoryHookStoreTests.hook(bystander.id, "bystander-hook-text-pp63"))
        try await store.saveDigest(digestWithExcerpts())
        return (target, bystander)
    }

    @Test func excerptsRoundTripThroughTheStore() async throws {
        let store = try PeopleStore.inMemory()
        let digest = Self.digestWithExcerpts()
        try await store.saveDigest(digest)
        let loaded = try #require(try await store.latestDigest())
        #expect(loaded == digest)
        #expect(loaded.entries.first?.recentMessages?.first?.text == Self.excerptText)
    }

    @Test func forgetRemovesHooksAndExcerptsEvenFromRawBytes() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PeopleStore(path: path)
        let (target, bystander) = try await Self.populate(store)
        let doomed = [Self.hookText, Self.hookText + "-summary", Self.excerptText].map { Data($0.utf8) }
        let kept = [Data("bystander-hook-text-pp63".utf8), Data("bystander-excerpt-text-mm02".utf8)]
        #expect(Fixture.rawTraces(of: doomed + kept, at: path).count >= 5)

        try await store.forget(target.id)

        #expect(try await store.hooks(for: target.id, now: MemoryHookStoreTests.now).isEmpty)
        #expect(try await store.hooks(for: bystander.id, now: MemoryHookStoreTests.now).count == 1)
        let remaining = try #require(try await store.latestDigest())
        #expect(remaining.entries.map(\.handle) == ["+15550000059"])
        for (table, count) in try await store.rowsMentioning(target.id) {
            #expect(count == 0, "table \(table) still references the forgotten person")
        }
        #expect(!store.hasPendingErasure)
        #expect(Fixture.rawTraces(of: doomed, at: path) == [])
        #expect(Fixture.rawTraces(of: kept, at: path).count >= 2)
    }

    @Test func forgetBlockedByReaderCompletesOnFlush() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PeopleStore(path: path, busyTimeout: 0.05)
        let (target, _) = try await Self.populate(store)
        let doomed = [Self.hookText, Self.excerptText].map { Data($0.utf8) }

        let reader = store.holdReadTransaction()
        try await store.forget(target.id)
        #expect(store.hasPendingErasure)
        reader.release()
        #expect(await store.flushPendingErasure())
        #expect(Fixture.rawTraces(of: doomed, at: path) == [])
    }

    @Test func eraseEverythingRemovesHooksAndExcerptsFromRawBytes() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PeopleStore(path: path)
        _ = try await Self.populate(store)
        let needles = [
            Self.hookText, Self.excerptText, "bystander-hook-text-pp63", "bystander-excerpt-text-mm02",
        ].map { Data($0.utf8) }
        #expect(!Fixture.rawTraces(of: needles, at: path).isEmpty)

        try await store.eraseEverything()

        #expect(try await store.rowCount("memory_hook") == 0)
        #expect(!store.hasPendingErasure)
        #expect(Fixture.rawTraces(of: needles, at: path) == [])
    }

    @Test func deletedAndReplacedHooksLeaveNoRawBytes() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PeopleStore(path: path)
        let person = Fixture.person("Scrub", confirmed: true)
        try await store.upsert(person)
        let doomed = MemoryHookStoreTests.hook(person.id, "deleted-hook-text-aa11")
        let stale = MemoryHookStoreTests.hook(
            person.id, "replaced-hook-text-bb22", source: .onDeviceSummary)
        try await store.addHook(doomed)
        try await store.addHook(stale)
        let needles = ["deleted-hook-text-aa11", "replaced-hook-text-bb22"].map { Data($0.utf8) }
        #expect(Fixture.rawTraces(of: needles, at: path).count >= 2)

        try await store.deleteHook(id: doomed.id)
        try await store.replaceHooks(for: person.id, source: .onDeviceSummary, with: [])
        _ = await store.flushPendingErasure()
        #expect(Fixture.rawTraces(of: needles, at: path) == [])
    }
}

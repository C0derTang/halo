import Foundation
import HaloCore

@testable import HaloMemory

/// In-memory `PeopleStoring & MemoryStoring`. Synthetic data only.
actor FakeMemoryStore: PeopleStoring, MemoryStoring {
    var people: [PersonID: Person] = [:]
    var idents: [Identity] = []
    var digest: InteractionDigest?
    var storedHooks: [MemoryHook] = []
    private(set) var replaceCalls: [PersonID] = []
    private(set) var hookReads: [PersonID] = []
    func resetHookReads() { hookReads = [] }

    func seed(_ person: Person, handles: [(Identity.Kind, String)] = []) {
        people[person.id] = person
        for (kind, value) in handles {
            idents.append(Identity(personID: person.id, kind: kind, value: value))
        }
    }
    func setDigest(_ digest: InteractionDigest?) { self.digest = digest }
    func setConfirmed(_ id: PersonID, _ confirmed: Bool) { people[id]?.confirmed = confirmed }
    func rename(_ id: PersonID, _ name: String) { people[id]?.displayName = name }

    // PeopleStoring
    func person(_ id: PersonID) async throws -> Person? { people[id] }
    func allPeople() async throws -> [Person] { Array(people.values) }
    func upsert(_ person: Person) async throws { people[person.id] = person }
    func identities(for id: PersonID) async throws -> [Identity] { idents.filter { $0.personID == id } }
    func addIdentity(_ identity: Identity) async throws { idents.append(identity) }
    func person(matching kind: Identity.Kind, value: String) async throws -> Person? {
        idents.first { $0.kind == kind && $0.value == value }.flatMap { people[$0.personID] }
    }
    func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] { [] }
    func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws {}
    func forget(_ id: PersonID) async throws {
        people[id] = nil
        idents.removeAll { $0.personID == id }
        storedHooks.removeAll { $0.personID == id }
    }
    func latestDigest() async throws -> InteractionDigest? { digest }
    func saveDigest(_ digest: InteractionDigest) async throws { self.digest = digest }

    // MemoryStoring
    func hooks(for person: PersonID, now: Date) async throws -> [MemoryHook] {
        hookReads.append(person)
        return storedHooks.filter { $0.personID == person && ($0.expiresAt.map { $0 > now } ?? true) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    func addHook(_ hook: MemoryHook) async throws { storedHooks.append(hook) }
    func replaceHooks(for person: PersonID, source: MemoryHook.Source, with hooks: [MemoryHook]) async throws
    {
        replaceCalls.append(person)
        storedHooks.removeAll { $0.personID == person && $0.source == source }
        storedHooks.append(contentsOf: hooks)
    }
    func deleteHook(id: UUID) async throws { storedHooks.removeAll { $0.id == id } }

    func allHooks(for person: PersonID) -> [MemoryHook] { storedHooks.filter { $0.personID == person } }
}

/// Scripted generator. Records who it was asked about; never touches a real model.
actor FakeHookGenerator: MemoryHookGenerating {
    var available: Bool
    var texts: [String]
    var failure: (any Error)?
    /// People for whom generation always throws.
    var failingPeople: Set<PersonID> = []
    /// When set, `hooks` suspends until `release()` (used to test cancellation mid-run).
    var blockUntilReleased = false
    private(set) var calls: [(person: PersonID, messages: [InteractionDigest.DigestMessage])] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var started: [CheckedContinuation<Void, Never>] = []

    init(available: Bool = true, texts: [String] = ["Started a new job at Acme"]) {
        self.available = available
        self.texts = texts
    }

    var isAvailable: Bool { available }

    func setAvailable(_ value: Bool) { available = value }
    func setTexts(_ value: [String]) { texts = value }
    func setFailure(_ error: (any Error)?) { failure = error }
    func setFailing(_ people: Set<PersonID>) { failingPeople = people }
    func setBlocking(_ value: Bool) { blockUntilReleased = value }
    var callCount: Int { calls.count }
    var askedAbout: [PersonID] { calls.map(\.person) }

    /// Resumes once a `hooks` call has started.
    func waitUntilCalled() async {
        if !calls.isEmpty { return }
        await withCheckedContinuation { started.append($0) }
    }
    func release() {
        blockUntilReleased = false
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func hooks(for person: Person, messages: [InteractionDigest.DigestMessage], now: Date) async throws
        -> [MemoryHook]
    {
        calls.append((person.id, messages))
        for waiter in started { waiter.resume() }
        started = []
        if blockUntilReleased { await withCheckedContinuation { waiters.append($0) } }
        if let failure { throw failure }
        if failingPeople.contains(person.id) { throw FakeGenerationError() }
        return texts.map {
            MemoryHook(personID: person.id, text: $0, source: .onDeviceSummary, createdAt: now)
        }
    }
}

struct FakeGenerationError: Error {}

enum Fixture {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func message(_ text: String, minutesAgo: Double = 10, fromMe: Bool = false)
        -> InteractionDigest.DigestMessage
    {
        .init(date: t0.addingTimeInterval(-minutesAgo * 60), fromMe: fromMe, text: text)
    }

    static func entry(_ handle: String, _ messages: [InteractionDigest.DigestMessage]?)
        -> InteractionDigest.Entry
    {
        .init(
            handle: handle, lastMessageAt: messages?.first?.date, lastFromMeAt: nil, lastFromThemAt: nil,
            messagesLast30Days: messages?.count ?? 0, messagesAllTime: messages?.count ?? 0,
            awaitingMyReply: false, recentMessages: messages)
    }

    static func digest(_ entries: [InteractionDigest.Entry]) -> InteractionDigest {
        InteractionDigest(generatedAt: t0, entries: entries)
    }
}

import CoreGraphics
import Foundation
import HaloCore
import Testing

@testable import HaloUI

private final class PeopleFakeStore: PeopleStoring, EnrollmentStoring, PrivacyStoring, @unchecked Sendable {
    private let lock = NSLock()
    var people: [Person]
    var idents: [Identity] = []
    var digest: InteractionDigest?
    var gallery: [FaceEmbedding] = []
    var log: [PersonID: [Date]] = [:]
    var records: [ClusterRecord] = []
    var forgetCount = 0

    init(people: [Person]) { self.people = people }

    func person(_ id: PersonID) async throws -> Person? { people.first { $0.id == id } }
    func allPeople() async throws -> [Person] { people }
    func upsert(_ person: Person) async throws {
        lock.withLock {
            people.removeAll { $0.id == person.id }
            people.append(person)
        }
    }
    func identities(for id: PersonID) async throws -> [Identity] { idents.filter { $0.personID == id } }
    func addIdentity(_ identity: Identity) async throws {}
    func person(matching kind: Identity.Kind, value: String) async throws -> Person? { nil }
    func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] { gallery }
    func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws {}
    func forget(_ id: PersonID) async throws { lock.withLock { forgetCount += 1 } }
    func latestDigest() async throws -> InteractionDigest? { digest }
    func saveDigest(_ digest: InteractionDigest) async throws {}

    func unassignedEmbeddings(space: EmbeddingSpace) async throws -> [FaceEmbedding] { [] }
    func embeddings(ids: [UUID]) async throws -> [FaceEmbedding] { [] }
    func replaceClusters(_ clusters: [ClusterRecord]) async throws {}
    func clusters() async throws -> [ClusterRecord] { records }
    func confirm(cluster id: String, as person: PersonID) async throws {}
    func deleteEmbeddings(ids: [UUID]) async throws {}
    func removeIdentity(_ identity: Identity) async throws {}
    func scanCursor() async throws -> String? { nil }
    func setScanCursor(_ cursor: String?) async throws {}

    func logRecognition(of id: PersonID, at date: Date) async throws {}
    func recognitionLog(for id: PersonID) async throws -> [Date] { log[id] ?? [] }
    var hasPendingErasure: Bool { false }
    func flushPendingErasure() async -> Bool { true }
    func eraseEverything() async throws {}
}

private struct NoThumbs: FaceThumbnailProvider {
    func thumbnail(for embedding: FaceEmbedding) async -> CGImage? { nil }
}

/// Records the inputs it was given and encodes them in the label so tests can compare.
private final class RecordingRanker: LabelRanking, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(Person, [Identity], InteractionDigest?, Date)] = []
    var calls: [(Person, [Identity], InteractionDigest?, Date)] { lock.withLock { _calls } }
    func label(for person: Person, identities: [Identity], digest: InteractionDigest?, now: Date)
        -> LabelData
    {
        lock.withLock { _calls.append((person, identities, digest, now)) }
        return LabelData(
            personID: person.id, title: person.displayName,
            subtitle: "\(identities.count)|\(digest?.entries.count ?? -1)|\(now.timeIntervalSince1970)")
    }
}

private let space = EmbeddingSpace(modelID: "t", dimension: 2)
private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func entry(_ handle: String, _ at: Date?) -> InteractionDigest.Entry {
    .init(
        handle: handle, lastMessageAt: at, lastFromMeAt: nil, lastFromThemAt: nil,
        messagesLast30Days: 1, messagesAllTime: 1, awaitingMyReply: false)
}

@MainActor
@Suite struct PeopleListModelTests {
    @Test func listsConfirmedOnlyAndCountsReview() async {
        let a = Person(displayName: "Ann", confirmed: true)
        let b = Person(displayName: "Bob", confirmed: false)
        let store = PeopleFakeStore(people: [a, b])
        store.records = [ClusterRecord(id: "c", memberIDs: [], representativeID: UUID(), cohesion: 1)]
        let model = PeopleListModel(store: store)
        await model.load()
        #expect(model.rows.map(\.person.displayName) == ["Ann"])
        #expect(model.needsReviewCount == 1)
    }

    @Test func ordersByLastInteractionThenNameAndNilLast() async {
        let a = Person(displayName: "Ann", confirmed: true)
        let b = Person(displayName: "Bea", confirmed: true)
        let c = Person(displayName: "Cy", confirmed: true)
        let d = Person(displayName: "Al", confirmed: true)
        let store = PeopleFakeStore(people: [a, b, c, d])
        store.idents = [
            Identity(personID: a.id, kind: .phone, value: "+1"),
            Identity(personID: b.id, kind: .email, value: "b@x.com"),
            Identity(personID: c.id, kind: .imessageHandle, value: "+3"),
        ]
        store.digest = InteractionDigest(
            generatedAt: t0,
            entries: [entry("+1", t0), entry("B@X.com", t0.addingTimeInterval(100)), entry("+3", nil)])
        let model = PeopleListModel(store: store)
        await model.load()
        #expect(model.rows.map(\.person.displayName) == ["Bea", "Ann", "Al", "Cy"])
        model.sort = .name
        #expect(model.rows.map(\.person.displayName) == ["Al", "Ann", "Bea", "Cy"])
    }

    @Test func searchFiltersByName() async {
        let store = PeopleFakeStore(people: [
            Person(displayName: "Ann", confirmed: true), Person(displayName: "Bob", confirmed: true),
        ])
        let model = PeopleListModel(store: store)
        await model.load()
        model.searchText = "  bo "
        #expect(model.rows.map(\.person.displayName) == ["Bob"])
        model.searchText = "zzz"
        #expect(model.rows.isEmpty)
    }
}

@MainActor
@Suite struct PersonDetailModelTests {
    private func make(
        _ store: PeopleFakeStore, _ person: Person, ranker: RecordingRanker = RecordingRanker(),
        forget: @escaping @Sendable (Person) async -> Bool = { _ in true }
    ) -> PersonDetailModel {
        PersonDetailModel(
            personID: person.id, store: store, thumbnails: NoThumbs(), ranker: ranker, space: space,
            now: { t0 }, forget: forget)
    }

    @Test func editPreservesConfirmedAndOtherFields() async {
        let p = Person(displayName: "Ann", relationship: "x", notes: "n", confirmed: true)
        let store = PeopleFakeStore(people: [p])
        let model = make(store, p)
        await model.load()
        #expect(await model.save(name: " Anna ", relationship: " Friend "))
        let saved = store.people.first!
        #expect(saved.displayName == "Anna")
        #expect(saved.relationship == "Friend")
        #expect(saved.confirmed)
        #expect(saved.notes == "n")
        #expect(saved.id == p.id)
    }

    @Test func editNeverConfirmsUnconfirmed() async {
        let p = Person(displayName: "Bob", confirmed: false)
        let store = PeopleFakeStore(people: [p])
        let model = make(store, p)
        await model.load()
        _ = await model.save(name: "Bobby", relationship: "")
        #expect(store.people.first!.confirmed == false)
        #expect(store.people.first!.relationship == nil)
    }

    @Test func emptyNameRejected() async {
        let p = Person(displayName: "Ann", confirmed: true)
        let store = PeopleFakeStore(people: [p])
        let model = make(store, p)
        await model.load()
        #expect(await model.save(name: "  ", relationship: "x") == false)
        #expect(store.people.first!.displayName == "Ann")
    }

    @Test func forgetDelegatesOnceAndNeverTouchesStore() async {
        let p = Person(displayName: "Ann", confirmed: true)
        let store = PeopleFakeStore(people: [p])
        let calls = Counter()
        let model = make(store, p) { _ in
            await calls.increment()
            return true
        }
        await model.load()
        #expect(await model.confirmForget())
        #expect(await model.confirmForget() == false)
        #expect(await calls.value == 1)
        #expect(store.forgetCount == 0)
        #expect(model.didForget)
    }

    @Test func failedForgetCanRetry() async {
        let p = Person(displayName: "Ann", confirmed: true)
        let store = PeopleFakeStore(people: [p])
        let calls = Counter()
        let model = make(store, p) { _ in
            let n = await calls.increment()
            return n > 1
        }
        await model.load()
        #expect(await model.confirmForget() == false)
        #expect(model.errorMessage != nil)
        #expect(await model.confirmForget())
        #expect(await calls.value == 2)
    }

    @Test func labelPreviewUsesSameRankerInputsAsLens() async {
        let p = Person(displayName: "Ann", relationship: "Pal", confirmed: true)
        let store = PeopleFakeStore(people: [p])
        store.idents = [Identity(personID: p.id, kind: .phone, value: "+1")]
        store.digest = InteractionDigest(generatedAt: t0, entries: [entry("+1", t0)])
        let ranker = RecordingRanker()
        let model = make(store, p, ranker: ranker)
        await model.load()
        let call = ranker.calls.last!
        #expect(call.0 == p)
        #expect(call.1 == store.idents)
        #expect(call.2 == store.digest)
        #expect(call.3 == t0)
        let expected = ranker.label(for: p, identities: store.idents, digest: store.digest, now: t0)
        #expect(model.labelPreview == expected)
    }

    @Test func previewReceivesStoreWideIdentities() async {
        let p = Person(displayName: "Ann", confirmed: true)
        let q = Person(displayName: "Quin", confirmed: true)
        let store = PeopleFakeStore(people: [p, q])
        store.idents = [
            Identity(personID: p.id, kind: .phone, value: "+1"),
            Identity(personID: q.id, kind: .phone, value: "+1"),
        ]
        let ranker = RecordingRanker()
        let model = make(store, p, ranker: ranker)
        await model.load()
        #expect(Set(ranker.calls.last!.1) == Set(store.idents))
        #expect(model.identities == [store.idents[0]])
    }

    @Test func facesCappedAtTwelveAndFilteredToPerson() async {
        let p = Person(displayName: "Ann", confirmed: true)
        let other = PersonID()
        let store = PeopleFakeStore(people: [p])
        store.gallery =
            (0..<15).map { _ in
                FaceEmbedding(
                    personID: p.id, space: space, vector: [1, 0], source: .photoLibrary, quality: 1)
            }
            + [
                FaceEmbedding(
                    personID: other, space: space, vector: [1, 0], source: .photoLibrary, quality: 1)
            ]
        store.log[p.id] = [t0, t0.addingTimeInterval(50)]
        let model = make(store, p)
        await model.load()
        #expect(model.faceCount == 15)
        #expect(model.faces.count == 12)
        #expect(model.recognitions == [t0.addingTimeInterval(50), t0])
    }
}

private actor Counter {
    var value = 0
    @discardableResult func increment() -> Int {
        value += 1
        return value
    }
}

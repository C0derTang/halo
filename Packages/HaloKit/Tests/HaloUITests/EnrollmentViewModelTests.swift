import CoreGraphics
import Foundation
import HaloCore
import Testing

@testable import HaloUI

private actor FakeStore: EnrollmentStoring, PeopleStoring {
    var people: [Person]
    var records: [ClusterRecord]
    var embeds: [FaceEmbedding]
    var confirmCalls: [(String, PersonID)] = []
    var deleteCalls: [[UUID]] = []
    var forgotten: [PersonID] = []
    var failConfirm = false

    init(people: [Person] = [], records: [ClusterRecord], embeds: [FaceEmbedding]) {
        self.people = people
        self.records = records
        self.embeds = embeds
    }

    func setFailConfirm(_ v: Bool) { failConfirm = v }

    func unassignedEmbeddings(space: EmbeddingSpace) async throws -> [FaceEmbedding] { embeds }
    func embeddings(ids: [UUID]) async throws -> [FaceEmbedding] { embeds.filter { ids.contains($0.id) } }
    func replaceClusters(_ clusters: [ClusterRecord]) async throws { records = clusters }
    func clusters() async throws -> [ClusterRecord] { records }
    func confirm(cluster id: String, as person: PersonID) async throws {
        struct Boom: Error {}
        if failConfirm { throw Boom() }
        confirmCalls.append((id, person))
        records.removeAll { $0.id == id }
    }
    func deleteEmbeddings(ids: [UUID]) async throws {
        deleteCalls.append(ids)
        embeds.removeAll { ids.contains($0.id) }
    }
    func removeIdentity(_ identity: Identity) async throws {}
    func scanCursor() async throws -> String? { nil }
    func setScanCursor(_ cursor: String?) async throws {}

    func person(_ id: PersonID) async throws -> Person? { people.first { $0.id == id } }
    func allPeople() async throws -> [Person] { people }
    func upsert(_ person: Person) async throws { people.append(person) }
    func identities(for id: PersonID) async throws -> [Identity] { [] }
    func addIdentity(_ identity: Identity) async throws {}
    func person(matching kind: Identity.Kind, value: String) async throws -> Person? { nil }
    func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] { [] }
    func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws {}
    func forget(_ id: PersonID) async throws {
        forgotten.append(id)
        people.removeAll { $0.id == id }
    }
    func latestDigest() async throws -> InteractionDigest? { nil }
    func saveDigest(_ digest: InteractionDigest) async throws {}
}

private struct FakeThumbs: FaceThumbnailProvider {
    func thumbnail(for embedding: FaceEmbedding) async -> CGImage? { nil }
}

private let space = EmbeddingSpace(modelID: "test", dimension: 2)

private func embeds(_ n: Int) -> [FaceEmbedding] {
    (0..<n).map { i in
        FaceEmbedding(
            space: space, vector: [1, 0], source: .photoLibrary, sourceRef: "asset-\(i)", quality: 0.9)
    }
}

private func record(_ id: String, _ e: [FaceEmbedding], suggested: PersonID? = nil) -> ClusterRecord {
    ClusterRecord(
        id: id, memberIDs: e.map(\.id), representativeID: e[0].id, suggestedPersonID: suggested,
        cohesion: 0.9)
}

@MainActor
private func makeModel(
    people: [Person] = [], clusters: [[FaceEmbedding]], suggested: PersonID? = nil
) async -> (EnrollmentViewModel, FakeStore) {
    let all = clusters.flatMap { $0 }
    let recs = clusters.enumerated().map { record("c\($0.offset)", $0.element, suggested: suggested) }
    let store = FakeStore(people: people, records: recs, embeds: all)
    let model = EnrollmentViewModel(store: store, thumbnails: FakeThumbs())
    await model.load()
    return (model, store)
}

@MainActor
@Suite struct EnrollmentViewModelTests {
    @Test func loadCapsThumbnailsAtEightAndKeepsRepresentative() async {
        let (model, _) = await makeModel(clusters: [embeds(12)])
        let card = try! #require(model.current)
        #expect(card.members.count == 8)
        #expect(card.cluster.memberIDs.count == 12)
        #expect(card.representative.id == card.cluster.representativeID)
    }

    @Test func confirmExistingCallsStoreOnceWithRightIDs() async {
        let alex = Person(displayName: "Alex", confirmed: true)
        let (model, store) = await makeModel(people: [alex], clusters: [embeds(3), embeds(2)])
        let card = try! #require(model.current)
        #expect(await model.confirm(card, as: alex))
        let calls = await store.confirmCalls
        #expect(calls.count == 1)
        #expect(calls[0].0 == card.id)
        #expect(calls[0].1 == alex.id)
        #expect(model.remaining == 1)
    }

    @Test func confirmNewPersonCreatesUnconfirmedThenConfirmsOnce() async {
        let (model, store) = await makeModel(clusters: [embeds(3)])
        let card = try! #require(model.current)
        #expect(await model.confirmNewPerson(named: "  Sam Rivera ", for: card))
        let people = await store.people
        #expect(people.count == 1)
        #expect(people[0].displayName == "Sam Rivera")
        #expect(people[0].confirmed == false)  // only the store's confirm makes them recognizable
        let calls = await store.confirmCalls
        #expect(calls.count == 1)
        #expect(calls[0].1 == people[0].id)
        #expect(model.remaining == 0)
    }

    @Test func blankNameDoesNothing() async {
        let (model, store) = await makeModel(clusters: [embeds(3)])
        let card = try! #require(model.current)
        #expect(await model.confirmNewPerson(named: "   ", for: card) == false)
        #expect(await store.people.isEmpty)
        #expect(await store.confirmCalls.isEmpty)
    }

    @Test func failedConfirmKeepsClusterAndRemovesOrphanPerson() async {
        let (model, store) = await makeModel(clusters: [embeds(3)])
        await store.setFailConfirm(true)
        let card = try! #require(model.current)
        #expect(await model.confirmNewPerson(named: "Sam", for: card) == false)
        #expect(model.remaining == 1)
        #expect(model.errorMessage != nil)
        #expect(await store.people.isEmpty)
        #expect(await store.forgotten.count == 1)
    }

    @Test func suggestionNeverAppliedUntilTapped() async {
        let alex = Person(displayName: "Alex", confirmed: true)
        let (model, store) = await makeModel(people: [alex], clusters: [embeds(3)], suggested: alex.id)
        let card = try! #require(model.current)
        #expect(card.suggestedPerson?.id == alex.id)
        // Loading, skipping and viewing never confirm.
        model.skip(card)
        model.reviewSkipped()
        #expect(await store.confirmCalls.isEmpty)
        #expect(await model.acceptSuggestion(for: card))
        let calls = await store.confirmCalls
        #expect(calls.count == 1)
        #expect(calls[0].1 == alex.id)
    }

    @Test func acceptSuggestionWithoutSuggestionIsNoOp() async {
        let (model, store) = await makeModel(clusters: [embeds(2)])
        let card = try! #require(model.current)
        #expect(await model.acceptSuggestion(for: card) == false)
        #expect(await store.confirmCalls.isEmpty)
    }

    @Test func rejectFacesDeletesExactlyThoseIDs() async {
        let e = embeds(4)
        let (model, store) = await makeModel(clusters: [e])
        let card = try! #require(model.current)
        let stray = [e[1].id, e[3].id]
        #expect(await model.reject(faces: stray, from: card))
        let calls = await store.deleteCalls
        #expect(calls.count == 1)
        #expect(Set(calls[0]) == Set(stray))
        #expect(await store.confirmCalls.isEmpty)
        let updated = try! #require(model.current)
        #expect(Set(updated.cluster.memberIDs) == Set([e[0].id, e[2].id]))
        #expect(updated.members.count == 2)
    }

    @Test func rejectIgnoresIDsOutsideCluster() async {
        let (model, store) = await makeModel(clusters: [embeds(2), embeds(2)])
        let card = try! #require(model.current)
        let other = model.cards[1].cluster.memberIDs[0]
        #expect(await model.reject(faces: [other], from: card) == false)
        #expect(await store.deleteCalls.isEmpty)
    }

    @Test func rejectingRepresentativePromotesAnotherMember() async {
        let e = embeds(3)
        let (model, _) = await makeModel(clusters: [e])
        let card = try! #require(model.current)
        _ = await model.reject(faces: [e[0].id], from: card)
        let updated = try! #require(model.current)
        #expect(updated.cluster.representativeID == e[1].id)
        #expect(updated.representative.id == e[1].id)
    }

    @Test func rejectingEveryFaceDropsCard() async {
        let e = embeds(2)
        let (model, _) = await makeModel(clusters: [e])
        let card = try! #require(model.current)
        _ = await model.reject(faces: e.map(\.id), from: card)
        #expect(model.current == nil)
    }

    @Test func skipKeepsClusterAndWritesNothing() async {
        let (model, store) = await makeModel(clusters: [embeds(2), embeds(2)])
        let first = try! #require(model.current)
        model.skip(first)
        #expect(model.remaining == 1)
        #expect(model.skippedCount == 1)
        #expect(model.current?.id != first.id)
        #expect(model.cards.count == 2)
        #expect(await store.deleteCalls.isEmpty)
        #expect(await store.confirmCalls.isEmpty)
        model.reviewSkipped()
        #expect(model.remaining == 2)
    }

    @Test func neverSuggestDeletesAllMembers() async {
        let e = embeds(5)
        let (model, store) = await makeModel(clusters: [e, embeds(2)])
        let card = try! #require(model.current)
        #expect(await model.neverSuggest(card))
        let calls = await store.deleteCalls
        #expect(calls.count == 1)
        #expect(Set(calls[0]) == Set(e.map(\.id)))
        #expect(await store.confirmCalls.isEmpty)
        #expect(model.remaining == 1)
    }

    @Test func progressCountsAndText() async {
        let (model, _) = await makeModel(clusters: [embeds(1), embeds(1), embeds(1)])
        #expect(model.remaining == 3)
        #expect(model.progressText == "3 left")
        model.skip(model.current!)
        #expect(model.progressText == "2 left")
        let card = model.current!
        _ = await model.neverSuggest(card)
        #expect(model.progressText == "1 left")
    }

    @Test func loadDropsClustersWhoseMembersWereDeleted() async {
        let e = embeds(2)
        let store = FakeStore(records: [record("gone", e)], embeds: [])
        let model = EnrollmentViewModel(store: store, thumbnails: FakeThumbs())
        await model.load()
        #expect(model.cards.isEmpty)
    }

    @Test func searchPeopleFiltersCaseInsensitively() async {
        let people = [
            Person(displayName: "Zed"), Person(displayName: "alexandra"), Person(displayName: "Bob"),
        ]
        let (model, _) = await makeModel(people: people, clusters: [embeds(1)])
        #expect(await model.searchPeople("ALEX").map(\.displayName) == ["alexandra"])
        #expect(await model.searchPeople("").map(\.displayName) == ["alexandra", "Bob", "Zed"])
    }
}

import Foundation
import HaloCore

actor FakePeopleStore: PeopleStoring {
    var people: [PersonID: Person] = [:]
    var idents: [Identity] = []

    func person(_ id: PersonID) async throws -> Person? { people[id] }
    func allPeople() async throws -> [Person] { Array(people.values) }
    func upsert(_ person: Person) async throws { people[person.id] = person }
    func identities(for id: PersonID) async throws -> [Identity] { idents.filter { $0.personID == id } }
    func addIdentity(_ identity: Identity) async throws {
        if !idents.contains(identity) { idents.append(identity) }
    }
    func person(matching kind: Identity.Kind, value: String) async throws -> Person? {
        guard let i = idents.first(where: { $0.kind == kind && $0.value == value }) else { return nil }
        return people[i.personID]
    }
    func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] { [] }
    func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws {}
    func forget(_ id: PersonID) async throws {
        people[id] = nil
        idents.removeAll { $0.personID == id }
    }
    func latestDigest() async throws -> InteractionDigest? { nil }
    func saveDigest(_ digest: InteractionDigest) async throws {}
}

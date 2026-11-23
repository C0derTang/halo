import Foundation
import HaloBridgeKit
import HaloCore
import Synchronization

/// In-memory `KeyStore`. Tests never touch the real Keychain.
final class MemoryKeyStore: KeyStore {
    private let items = Mutex<[String: Data]>([:])
    func read(account: String) throws -> Data? { items.withLock { $0[account] } }
    func write(_ data: Data, account: String) throws { items.withLock { $0[account] = data } }
    func delete(account: String) throws { _ = items.withLock { $0.removeValue(forKey: account) } }
}

struct FakeStoreFailure: Error {}

/// Minimal `PeopleStoring` that records the saved digest.
actor RecordingStore: PeopleStoring {
    private(set) var saved: [InteractionDigest] = []
    var idents: [Identity] = []
    var people: [PersonID: Person] = [:]
    var failSave = false

    func add(_ person: Person, identities: [Identity]) {
        people[person.id] = person
        idents += identities
    }
    func setFailSave(_ v: Bool) { failSave = v }

    func person(_ id: PersonID) async throws -> Person? { people[id] }
    func allPeople() async throws -> [Person] { Array(people.values) }
    func upsert(_ person: Person) async throws { people[person.id] = person }
    func identities(for id: PersonID) async throws -> [Identity] { idents.filter { $0.personID == id } }
    func addIdentity(_ identity: Identity) async throws { idents.append(identity) }
    func person(matching kind: Identity.Kind, value: String) async throws -> Person? {
        guard let i = idents.first(where: { $0.kind == kind && $0.value == value }) else { return nil }
        return people[i.personID]
    }
    func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] { [] }
    func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws {}
    func forget(_ id: PersonID) async throws {}
    func latestDigest() async throws -> InteractionDigest? { saved.last }
    func saveDigest(_ digest: InteractionDigest) async throws {
        if failSave { throw FakeStoreFailure() }
        saved.append(digest)
    }
}

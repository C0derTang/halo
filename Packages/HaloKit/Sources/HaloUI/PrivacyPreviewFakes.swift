#if DEBUG
    import Foundation
    import HaloCore
    import SwiftUI

    /// In-memory fakes for previews and tests. Synthetic data only.
    struct FakeAuthenticator: Authenticating {
        var succeeds = true
        func authenticate(reason: String) async -> Bool { succeeds }
    }

    final class FakePrivacyStore: PrivacyStoring, PeopleStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var people: [Person]
        private var log: [PersonID: [Date]]
        private var pending: Bool
        private var forgetCalls: [PersonID] = []
        private var eraseCalls = 0
        private var flushCalls = 0

        init(people: [Person] = [], log: [PersonID: [Date]] = [:], pending: Bool = false) {
            self.people = people
            self.log = log
            self.pending = pending
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        var forgotten: [PersonID] { locked { forgetCalls } }
        var eraseCount: Int { locked { eraseCalls } }
        var flushCount: Int { locked { flushCalls } }

        // PrivacyStoring
        func logRecognition(of id: PersonID, at date: Date) async throws {
            locked { log[id, default: []].append(date) }
        }
        func recognitionLog(for id: PersonID) async throws -> [Date] { locked { log[id] ?? [] } }
        var hasPendingErasure: Bool { locked { pending } }
        func flushPendingErasure() async -> Bool {
            locked {
                flushCalls += 1
                pending = false
                return true
            }
        }
        func eraseEverything() async throws {
            locked {
                eraseCalls += 1
                people = []
                log = [:]
            }
        }

        // PeopleStoring
        func person(_ id: PersonID) async throws -> Person? { locked { people.first { $0.id == id } } }
        func allPeople() async throws -> [Person] { locked { people } }
        func upsert(_ person: Person) async throws {
            locked {
                people.removeAll { $0.id == person.id }
                people.append(person)
            }
        }
        func identities(for id: PersonID) async throws -> [Identity] { [] }
        func addIdentity(_ identity: Identity) async throws {}
        func person(matching kind: Identity.Kind, value: String) async throws -> Person? { nil }
        func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] { [] }
        func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws {}
        func forget(_ id: PersonID) async throws {
            locked {
                forgetCalls.append(id)
                people.removeAll { $0.id == id }
                log[id] = nil
            }
        }
        func latestDigest() async throws -> InteractionDigest? { nil }
        func saveDigest(_ digest: InteractionDigest) async throws {}
    }

    extension FakePrivacyStore {
        static func sample() -> FakePrivacyStore {
            let a = Person(displayName: "Sample Alex", confirmed: true)
            let b = Person(displayName: "Sample Blake", confirmed: false)
            return FakePrivacyStore(
                people: [b, a], log: [a.id: [Date(), Date(timeIntervalSinceNow: -3600)]])
        }
    }

    #Preview("SettingsView") {
        SettingsView(
            model: PrivacySettingsViewModel(
                store: FakePrivacyStore.sample(), authenticator: FakeAuthenticator()))
    }
#endif

#if DEBUG
    import CoreGraphics
    import Foundation
    import HaloCore

    /// Synthetic fakes for previews and tests only.
    enum EnrollmentPreviewFakes {
        struct Thumbs: FaceThumbnailProvider {
            func thumbnail(for embedding: FaceEmbedding) async -> CGImage? { nil }
        }

        actor Store: EnrollmentStoring, PeopleStoring {
            var people: [Person] = [Person(displayName: "Alex Example", confirmed: true)]
            var records: [ClusterRecord]
            let embeds: [FaceEmbedding]

            init() {
                let space = EmbeddingSpace(modelID: "preview", dimension: 2)
                let e = (0..<5).map { _ in
                    FaceEmbedding(space: space, vector: [1, 0], source: .photoLibrary, quality: 0.9)
                }
                embeds = e
                records = [
                    ClusterRecord(id: "c1", memberIDs: e.map(\.id), representativeID: e[0].id, cohesion: 0.9)
                ]
            }

            func unassignedEmbeddings(space: EmbeddingSpace) async throws -> [FaceEmbedding] { embeds }
            func embeddings(ids: [UUID]) async throws -> [FaceEmbedding] {
                embeds.filter { ids.contains($0.id) }
            }
            func replaceClusters(_ clusters: [ClusterRecord]) async throws { records = clusters }
            func clusters() async throws -> [ClusterRecord] { records }
            func confirm(cluster id: String, as person: PersonID) async throws {
                records.removeAll { $0.id == id }
            }
            func deleteEmbeddings(ids: [UUID]) async throws {}
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
            func forget(_ id: PersonID) async throws { people.removeAll { $0.id == id } }
            func latestDigest() async throws -> InteractionDigest? { nil }
            func saveDigest(_ digest: InteractionDigest) async throws {}
        }

        @MainActor static func model() -> EnrollmentViewModel {
            EnrollmentViewModel(store: Store(), thumbnails: Thumbs())
        }
    }
#endif

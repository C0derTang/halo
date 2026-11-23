import Foundation
import GRDB
import HaloCore
import Testing

@testable import HaloStore

@Suite struct FaceBoxStoreTests {
    @Test func roundTripsWithAndWithoutFaceBox() async throws {
        let store = try PeopleStore.inMemory()
        var withBox = Fixture.embedding(for: nil, seed: 0.5)
        withBox.faceBox = CGRect(x: 0.25, y: 0.125, width: 0.5, height: 0.375)
        let withoutBox = Fixture.embedding(for: nil, seed: 0.7)
        try await store.addEmbeddings([withBox, withoutBox])

        let loaded = try await store.embeddings(ids: [withBox.id, withoutBox.id])
        #expect(loaded == [withBox, withoutBox])
        #expect(loaded[0].faceBox == CGRect(x: 0.25, y: 0.125, width: 0.5, height: 0.375))
        #expect(loaded[1].faceBox == nil)
        #expect(try await store.unassignedEmbeddings(space: Fixture.spaceA).count == 2)
    }

    @Test func confirmedGalleryCarriesFaceBox() async throws {
        let store = try PeopleStore.inMemory()
        let person = Fixture.person("Box Test", confirmed: true)
        try await store.upsert(person)
        var embedding = Fixture.embedding(for: person.id)
        embedding.faceBox = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        try await store.addEmbeddings([embedding])
        #expect(try await store.confirmedGallery(space: Fixture.spaceA) == [embedding])
    }

    @Test func rewritingAnEmbeddingUpdatesAndClearsItsBox() async throws {
        let store = try PeopleStore.inMemory()
        var embedding = Fixture.embedding(for: nil)
        embedding.faceBox = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        try await store.addEmbeddings([embedding])
        embedding.faceBox = nil
        try await store.addEmbeddings([embedding])
        #expect(try await store.embeddings(ids: [embedding.id]).first?.faceBox == nil)
    }

    @Test func v2DataMigratesAdditivelyWithNilFaceBox() async throws {
        let queue = try DatabaseQueue(configuration: PeopleStore.configuration())
        try Schema.migrator.migrate(queue, upTo: "v2")
        let id = UUID()
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO embedding
                        (id, personId, modelID, dimension, vector, source, sourceRef, quality, createdAt)
                    VALUES (?, NULL, ?, ?, ?, 'photoLibrary', 'old-ref', 0.5, 1.0)
                    """,
                arguments: [
                    id.uuidString, Fixture.spaceA.modelID, Fixture.spaceA.dimension,
                    VectorCodec.encode([1, 2, 3, 4]),
                ])
        }

        let store = try PeopleStore(writer: queue)
        #expect(try await store.appliedMigrations() == ["v1", "v2", "v3_faceBox", "v4_memoryHooks"])
        let old = try #require(try await store.embeddings(ids: [id]).first)
        #expect(old.faceBox == nil)
        #expect(old.vector == [1, 2, 3, 4])
        #expect(old.sourceRef == "old-ref")
    }
}

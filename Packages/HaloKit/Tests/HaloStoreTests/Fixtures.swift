import Foundation
import HaloCore

@testable import HaloStore

/// Synthetic fixtures only — no real people, faces or handles.
enum Fixture {
    static let spaceA = EmbeddingSpace(modelID: "synthetic-face-v1", dimension: 4)
    static let spaceSameModelOtherDim = EmbeddingSpace(modelID: "synthetic-face-v1", dimension: 3)
    static let spaceOtherModel = EmbeddingSpace(modelID: "synthetic-face-v2", dimension: 4)

    static let fixedDate = Date(timeIntervalSinceReferenceDate: 800_000_000.123_456_7)

    static func person(_ name: String, confirmed: Bool) -> Person {
        Person(
            displayName: name, relationship: "Test relation", notes: "Synthetic", confirmed: confirmed,
            createdAt: fixedDate, updatedAt: fixedDate)
    }

    static func embedding(
        for person: PersonID?, space: EmbeddingSpace = spaceA, seed: Float = 0.5
    ) -> FaceEmbedding {
        let vector = (0..<space.dimension).map { Float($0 + 1) * seed }
        return FaceEmbedding(
            personID: person, space: space, vector: vector, source: .liveCapture, sourceRef: "synthetic-ref",
            quality: 0.8, createdAt: fixedDate)
    }

    static func temporaryDatabasePath() throws -> (directory: URL, path: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaloStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("people.sqlite").path)
    }
}

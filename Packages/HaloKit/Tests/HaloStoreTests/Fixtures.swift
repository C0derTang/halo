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

    /// An embedding whose vector bytes and `sourceRef` are distinctive enough to grep for in raw
    /// database files. `tag` must be unique per embedding within a test.
    static func traceableEmbedding(for person: PersonID?, tag: Int) -> FaceEmbedding {
        let base = Float(tag) + 7_654.321
        return FaceEmbedding(
            personID: person, space: spaceA, vector: [base, -base * 3, base / 7, -base * 11],
            source: .photoLibrary, sourceRef: "synthetic-photo-\(tag)-ref", quality: 0.9,
            createdAt: fixedDate.addingTimeInterval(Double(tag)))
    }

    /// Byte needles that identify `embedding` on disk: its ID, sourceRef and packed vector.
    static func needles(for embedding: FaceEmbedding) -> [Data] {
        [
            Data(embedding.id.uuidString.utf8), Data((embedding.sourceRef ?? "").utf8),
            VectorCodec.encode(embedding.vector),
        ]
    }

    /// Descriptions of every needle found in the database file or its `-wal`/`-shm` siblings.
    static func rawTraces(of needles: [Data], at path: String) -> [String] {
        var traces: [String] = []
        for file in FileProtection.databaseFilePaths(for: path) {
            guard let bytes = FileManager.default.contents(atPath: file) else { continue }
            for needle in needles where !needle.isEmpty && bytes.range(of: needle) != nil {
                let label =
                    String(data: needle, encoding: .utf8) ?? needle.map { String($0) }.joined(separator: ",")
                traces.append("\((file as NSString).lastPathComponent): \(label)")
            }
        }
        return traces
    }

    static func temporaryDatabasePath() throws -> (directory: URL, path: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaloStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("people.sqlite").path)
    }
}

import Foundation
import HaloCore
import HaloMatching

// Synthetic fixtures only: hand-made or seeded-random vectors, no real faces.

let space4 = EmbeddingSpace(modelID: "synthetic-4", dimension: 4)

func makeMatcher(_ gallery: [FaceEmbedding], space: EmbeddingSpace = space4) -> GalleryMatcher {
    GalleryMatcher(gallery: gallery, space: space)
}

func embedding(_ person: PersonID?, _ vector: [Float], space: EmbeddingSpace = space4) -> FaceEmbedding {
    FaceEmbedding(personID: person, space: space, vector: vector, source: .liveCapture, quality: 1)
}

/// Unit vector in the x/y plane at `degrees` from the x axis.
func planar(_ degrees: Float) -> [Float] {
    let radians = degrees * .pi / 180
    return [cos(radians), sin(radians), 0, 0]
}

func approxEqual(_ a: Float, _ b: Float, tolerance: Float = 1e-5) -> Bool {
    abs(a - b) <= tolerance
}

/// Deterministic PRNG so the perf fixture is reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func randomUnitVector(dimension: Int, using rng: inout SplitMix64) -> [Float] {
    let raw = (0..<dimension).map { _ in Float.random(in: -1...1, using: &rng) }
    let norm = raw.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return raw.map { $0 / norm }
}

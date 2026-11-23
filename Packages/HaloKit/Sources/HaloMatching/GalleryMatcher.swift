import Accelerate
import HaloCore

/// Open-set face matcher over the user's confirmed gallery (invariants 1, 3, 4).
///
/// - Only embeddings with a `personID` take part; unconfirmed (nil-person) embeddings never match.
/// - Similarity is cosine. Gallery rows and the query are re-normalized here, so non-normalized
///   input is tolerated; zero, NaN and infinite vectors are rejected (gallery rows are dropped,
///   a bad query is `.unknown`).
/// - A person's score is the **max** cosine over that person's embeddings. Max (rather than the
///   mean) keeps one good enrollment photo useful when the others are off-pose; the margin test
///   below is what protects against false positives.
/// - The margin is measured between *distinct people*, so many embeddings of the same person
///   never make a match look ambiguous.
///
/// All thresholds come from the `MatchPolicy` passed to `match`; there are no others.
public struct GalleryMatcher: FaceMatching {
    /// The embedding space of the gallery, or nil when no usable embedding was supplied.
    public let space: EmbeddingSpace?
    /// Row-major `embeddingCount x dimension` matrix of L2-normalized vectors, grouped by person.
    private let matrix: [Float]
    /// Distinct people, in the same order as `ranges`.
    private let people: [PersonID]
    /// Row range in `matrix` for each entry of `people`.
    private let ranges: [Range<Int>]

    /// Vector length every query must have; 0 for an empty gallery.
    public var dimension: Int { space?.dimension ?? 0 }
    /// Number of usable gallery embeddings.
    public var embeddingCount: Int { ranges.last?.upperBound ?? 0 }
    /// Number of distinct people in the gallery.
    public var personCount: Int { people.count }

    /// Builds the gallery.
    ///
    /// The space of the first usable embedding becomes the gallery space; embeddings from any other
    /// space, with a vector length that does not match their space, without a `personID`, or with
    /// a zero/non-finite vector are ignored. Vectors from different models are never compared.
    public init(gallery: [FaceEmbedding]) {
        var space: EmbeddingSpace?
        var rowsByPerson: [PersonID: [[Float]]] = [:]
        var order: [PersonID] = []

        for embedding in gallery {
            guard let personID = embedding.personID,
                embedding.space.dimension > 0,
                embedding.vector.count == embedding.space.dimension,
                let unit = Self.normalized(embedding.vector)
            else { continue }
            if let space, space != embedding.space { continue }
            space = embedding.space
            if rowsByPerson[personID] == nil { order.append(personID) }
            rowsByPerson[personID, default: []].append(unit)
        }

        var matrix: [Float] = []
        var ranges: [Range<Int>] = []
        matrix.reserveCapacity(gallery.count * (space?.dimension ?? 0))
        var row = 0
        for personID in order {
            let rows = rowsByPerson[personID] ?? []
            for vector in rows { matrix.append(contentsOf: vector) }
            ranges.append(row..<(row + rows.count))
            row += rows.count
        }

        self.space = space
        self.matrix = matrix
        self.people = order
        self.ranges = ranges
    }

    public func match(_ vector: [Float], policy: MatchPolicy) -> MatchResult {
        let scores = personScores(for: vector)
        guard !scores.isEmpty else { return .unknown }

        var best = (index: -1, score: -Float.infinity)
        var second = -Float.infinity
        for (index, score) in scores.enumerated() {
            guard score.isFinite else { return .unknown }
            if score > best.score {
                second = best.score
                best = (index, score)
            } else if score > second {
                second = score
            }
        }
        guard best.index >= 0 else { return .unknown }

        // Written as "must reach" checks so a NaN policy value fails closed to unknown/ambiguous.
        guard best.score >= policy.minSimilarity else { return .unknown }
        // With a single enrolled person there is no runner-up; use the cosine floor (-1).
        let runnerUp = second.isFinite ? second : -1
        let margin = best.score - runnerUp
        // An exact tie between two people is ambiguous whatever the policy says.
        guard margin > 0, margin >= policy.minMargin else { return .ambiguous }
        return .known(people[best.index], similarity: best.score, margin: margin)
    }

    /// Cosine similarity of `vector` to each person (max over their embeddings), in `people` order.
    /// Empty when the gallery is empty or the query is unusable (wrong length, zero, non-finite).
    func personScores(for vector: [Float]) -> [Float] {
        let dimension = self.dimension
        guard !people.isEmpty, vector.count == dimension, let query = Self.normalized(vector) else {
            return []
        }
        let rowCount = embeddingCount
        var rowScores = [Float](repeating: 0, count: rowCount)
        matrix.withUnsafeBufferPointer { a in
            query.withUnsafeBufferPointer { q in
                rowScores.withUnsafeMutableBufferPointer { c in
                    // (rowCount x dimension) * (dimension x 1) -> (rowCount x 1)
                    vDSP_mmul(
                        a.baseAddress!, 1, q.baseAddress!, 1, c.baseAddress!, 1,
                        vDSP_Length(rowCount), 1, vDSP_Length(dimension))
                }
            }
        }
        return ranges.map { vDSP.maximum(rowScores[$0]) }
    }

    /// Unit-length copy of `vector`, or nil if it is empty, zero, or contains NaN/infinity.
    static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = vDSP.sumOfSquares(vector).squareRoot()
        guard norm.isFinite, norm > 0 else { return nil }
        return vDSP.divide(vector, norm)
    }
}

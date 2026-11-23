import Accelerate
import Foundation
import HaloCore

/// Clusters unlabeled face embeddings for the enrollment triage UI.
///
/// Algorithm: Chinese Whispers over a thresholded cosine-similarity graph. Similarities are
/// computed in blocks with BLAS (`vDSP_mmul` against a pre-transposed matrix), keeping each face's `maxNeighbors` strongest links
/// at or above the threshold, so memory is O(n * maxNeighbors) rather than O(n^2).
/// Determinism: faces are sorted by id, label updates run in that fixed order, and ties break
/// toward the smallest label, so output is independent of input order and RNG-free.
public struct FaceClusterer: Sendable {
    public var config: ClusteringConfig

    public init(config: ClusteringConfig = ClusteringConfig()) {
        self.config = config
    }

    // MARK: Clustering

    public func cluster(_ embeddings: [FaceEmbedding]) throws -> ClusteringResult {
        let (space, usable, lowQuality) = try prepare(embeddings)
        guard let space else {
            return ClusteringResult(clusters: [], unclustered: [], lowQuality: lowQuality)
        }
        let n = usable.count
        let dim = space.dimension
        var flat = [Float](repeating: 0, count: n * dim)
        for (i, e) in usable.enumerated() {
            flat.replaceSubrange(i * dim..<(i + 1) * dim, with: normalized(e.vector))
        }

        let labels = whisper(flat: flat, n: n, dim: dim)

        var groups: [Int: [Int]] = [:]
        for i in 0..<n { groups[labels[i], default: []].append(i) }
        var clusters: [FaceCluster] = []
        var unclustered: [UUID] = []
        for (_, idx) in groups {
            if idx.count >= max(config.minClusterSize, 1) {
                clusters.append(makeCluster(space: space, indices: idx, embeddings: usable, flat: flat))
            } else {
                unclustered.append(contentsOf: idx.map { usable[$0].id })
            }
        }
        return ClusteringResult(
            clusters: sortClusters(clusters), unclustered: sortIDs(unclustered),
            lowQuality: sortIDs(lowQuality))
    }

    // MARK: Incremental

    /// Attaches new faces to the closest existing cluster whose centroid is at or above the
    /// threshold; the remainder is re-clustered among itself. Existing cluster ids are preserved.
    /// - Parameter existingEmbeddings: the embeddings for the members of `existing` (looked up by id).
    public func assign(
        newEmbeddings: [FaceEmbedding], to existing: [FaceCluster],
        existingEmbeddings: [FaceEmbedding]
    ) throws -> ClusteringResult {
        let (space, usable, lowQuality) = try prepare(newEmbeddings)
        guard let space else {
            return ClusteringResult(
                clusters: sortClusters(existing), unclustered: [], lowQuality: sortIDs(lowQuality))
        }
        if existing.contains(where: { $0.space != space }) { throw ClusteringError.mixedEmbeddingSpaces }
        if existing.contains(where: { $0.centroid.count != space.dimension }) {
            throw ClusteringError.invalidCluster(
                id: existing.first { $0.centroid.count != space.dimension }!.id)
        }
        if existingEmbeddings.contains(where: { $0.space != space }) {
            throw ClusteringError.mixedEmbeddingSpaces
        }
        let pool = Dictionary(existingEmbeddings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let ordered = existing.sorted { $0.id.uuidString < $1.id.uuidString }
        var additions: [[FaceEmbedding]] = Array(repeating: [], count: ordered.count)
        var remainder: [FaceEmbedding] = []
        for e in usable {
            let v = normalized(e.vector)
            var best = -1
            var bestSim = config.similarityThreshold
            for (ci, c) in ordered.enumerated() {
                let s = dot(v, c.centroid)
                if s >= bestSim && (best < 0 || s > bestSim) {
                    best = ci
                    bestSim = s
                }
            }
            if best >= 0 { additions[best].append(e) } else { remainder.append(e) }
        }

        var result: [FaceCluster] = []
        for (ci, c) in ordered.enumerated() {
            if additions[ci].isEmpty {
                result.append(c)
                continue
            }
            var members: [FaceEmbedding] = []
            for id in c.memberIDs {
                guard let m = pool[id] else { throw ClusteringError.missingMemberEmbedding(id: id) }
                members.append(m)
            }
            members.append(contentsOf: additions[ci])
            members.sort { $0.id.uuidString < $1.id.uuidString }
            var flat: [Float] = []
            flat.reserveCapacity(members.count * space.dimension)
            for m in members { flat.append(contentsOf: normalized(m.vector)) }
            var updated = makeCluster(
                space: space, indices: Array(0..<members.count), embeddings: members, flat: flat)
            updated.id = c.id
            result.append(updated)
        }
        let rest = try cluster(remainder)
        result.append(contentsOf: rest.clusters)
        return ClusteringResult(
            clusters: sortClusters(result), unclustered: rest.unclustered,
            lowQuality: sortIDs(lowQuality))
    }

    // MARK: Suggestion

    /// Closest confirmed person to the cluster, if clearly above threshold. Suggestion only: the
    /// caller must show it to the user and nothing here confirms or labels anyone (invariant 3).
    /// `confirmedGallery` must contain only embeddings of confirmed people; embeddings without a
    /// `personID` are ignored.
    public func suggest(for cluster: FaceCluster, confirmedGallery: [FaceEmbedding]) throws
        -> PersonSuggestion?
    {
        var best: [PersonID: Float] = [:]
        for g in confirmedGallery {
            guard let pid = g.personID else { continue }
            guard g.space == cluster.space else { throw ClusteringError.mixedEmbeddingSpaces }
            guard g.vector.count == cluster.space.dimension else {
                throw ClusteringError.dimensionMismatch(embeddingID: g.id)
            }
            let s = dot(normalized(g.vector), cluster.centroid)
            if s > (best[pid] ?? -.infinity) { best[pid] = s }
        }
        let ranked = best.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key.description < $1.key.description
        }
        guard let top = ranked.first, top.value >= config.suggestionThreshold else { return nil }
        let second = ranked.count > 1 ? ranked[1].value : -1
        let margin = top.value - second
        guard margin >= config.suggestionMargin else { return nil }
        return PersonSuggestion(personID: top.key, similarity: top.value, margin: margin)
    }

    // MARK: Internals

    /// Validates, filters by quality, and sorts by id. Never mutates the caller's values.
    private func prepare(_ embeddings: [FaceEmbedding]) throws -> (
        EmbeddingSpace?, [FaceEmbedding], [UUID]
    ) {
        guard let first = embeddings.first else { return (nil, [], []) }
        let space = first.space
        var usable: [FaceEmbedding] = []
        var low: [UUID] = []
        for e in embeddings {
            if e.space != space { throw ClusteringError.mixedEmbeddingSpaces }
            if e.vector.count != space.dimension || space.dimension <= 0 {
                throw ClusteringError.dimensionMismatch(embeddingID: e.id)
            }
            let norm = sqrt(vDSP.sumOfSquares(e.vector))
            if !norm.isFinite || norm == 0 { throw ClusteringError.invalidVector(embeddingID: e.id) }
            if e.quality < config.minQuality { low.append(e.id) } else { usable.append(e) }
        }
        usable.sort { $0.id.uuidString < $1.id.uuidString }
        return (space, usable, low)
    }

    private func whisper(flat: [Float], n: Int, dim: Int) -> [Int] {
        let adjacency = buildGraph(flat: flat, n: n, dim: dim)
        var labels = Array(0..<n)
        for _ in 0..<max(config.maxIterations, 1) {
            var changed = false
            for i in 0..<n {
                let edges = adjacency[i]
                if edges.isEmpty { continue }
                var weights: [Int: Float] = [:]
                for (j, w) in edges { weights[labels[j], default: 0] += w }
                var bestLabel = labels[i]
                var bestWeight = -Float.infinity
                for (l, w) in weights where w > bestWeight || (w == bestWeight && l < bestLabel) {
                    bestLabel = l
                    bestWeight = w
                }
                if bestLabel != labels[i] {
                    labels[i] = bestLabel
                    changed = true
                }
            }
            if !changed { break }
        }
        return labels
    }

    /// Symmetric kNN graph: edges at/above threshold, strongest `maxNeighbors` per node.
    private func buildGraph(flat: [Float], n: Int, dim: Int) -> [[(Int, Float)]] {
        guard n > 0 else { return [] }
        let blockRows = max(1, min(n, 4_000_000 / max(n, 1)))
        var sims = [Float](repeating: 0, count: blockRows * n)
        // Transpose once: (n x dim) -> (dim x n), so each block is a plain row-major product.
        var transposed = [Float](repeating: 0, count: n * dim)
        flat.withUnsafeBufferPointer { src in
            transposed.withUnsafeMutableBufferPointer { dst in
                vDSP_mtrans(src.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(dim), vDSP_Length(n))
            }
        }
        var edgeSets = [[Int: Float]](repeating: [:], count: n)
        var start = 0
        while start < n {
            let rows = min(blockRows, n - start)
            flat.withUnsafeBufferPointer { all in
                transposed.withUnsafeBufferPointer { bt in
                    sims.withUnsafeMutableBufferPointer { c in
                        vDSP_mmul(
                            all.baseAddress! + start * dim, 1, bt.baseAddress!, 1, c.baseAddress!, 1,
                            vDSP_Length(rows), vDSP_Length(n), vDSP_Length(dim))
                    }
                }
            }
            for r in 0..<rows {
                let i = start + r
                var cands: [(Int, Float)] = []
                let base = r * n
                for j in 0..<n where j != i && sims[base + j] >= config.similarityThreshold {
                    cands.append((j, sims[base + j]))
                }
                if cands.count > config.maxNeighbors {
                    cands.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                    cands.removeLast(cands.count - config.maxNeighbors)
                }
                for (j, s) in cands {
                    edgeSets[i][j] = s
                    edgeSets[j][i] = s
                }
            }
            start += rows
        }
        return edgeSets.map { $0.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
    }

    private func makeCluster(
        space: EmbeddingSpace, indices: [Int], embeddings: [FaceEmbedding], flat: [Float]
    ) -> FaceCluster {
        let dim = space.dimension
        var sum = [Float](repeating: 0, count: dim)
        for i in indices {
            for d in 0..<dim { sum[d] += flat[i * dim + d] }
        }
        let count = Float(indices.count)
        let sumSq = vDSP.sumOfSquares(sum)
        let cohesion: Float = indices.count > 1 ? (sumSq - count) / (count * (count - 1)) : 1
        // Mean similarity of member i to the others is (v_i . sum - 1) / (n - 1): argmax is the medoid.
        let ordered = indices.sorted { embeddings[$0].id.uuidString < embeddings[$1].id.uuidString }
        var medoid = ordered[0]
        var medoidScore = -Float.infinity
        for i in ordered {
            let s = dot(Array(flat[i * dim..<(i + 1) * dim]), sum)
            if s > medoidScore {
                medoidScore = s
                medoid = i
            }
        }
        let ids = ordered.map { embeddings[$0].id }
        return FaceCluster(
            id: ids[0], space: space, memberIDs: ids, representativeID: embeddings[medoid].id,
            cohesion: min(max(cohesion, -1), 1), centroid: normalized(sum))
    }

    private func sortClusters(_ c: [FaceCluster]) -> [FaceCluster] {
        c.sorted { $0.size != $1.size ? $0.size > $1.size : $0.id.uuidString < $1.id.uuidString }
    }

    private func sortIDs(_ ids: [UUID]) -> [UUID] { ids.sorted { $0.uuidString < $1.uuidString } }
}

private func dot(_ a: [Float], _ b: [Float]) -> Float {
    vDSP.dot(a, b)
}

private func normalized(_ v: [Float]) -> [Float] {
    let norm = sqrt(vDSP.sumOfSquares(v))
    guard norm > 0, norm.isFinite else { return v }
    return vDSP.divide(v, norm)
}

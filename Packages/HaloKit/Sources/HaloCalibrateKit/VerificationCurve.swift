import Accelerate
import Foundation

/// A similarity score for one verification pair.
public struct ScoredPair: Hashable, Sendable {
    public var score: Float
    /// True for a same-person pair.
    public var isGenuine: Bool
    /// Fold for k-fold accuracy (LFW: 0..<10).
    public var fold: Int

    public init(score: Float, isGenuine: Bool, fold: Int = 0) {
        self.score = score
        self.isGenuine = isGenuine
        self.fold = fold
    }
}

/// Error counts at one threshold. The decision rule is the matcher's: **accept iff
/// `score >= threshold`** (`GalleryMatcher`: `best.score >= policy.minSimilarity`).
public struct OperatingPoint: Hashable, Sendable {
    public var threshold: Float
    /// Impostor pairs accepted (`score >= threshold`).
    public var falseAccepts: Int
    public var impostorCount: Int
    /// Genuine pairs rejected (`score < threshold`).
    public var falseRejects: Int
    public var genuineCount: Int

    public init(threshold: Float, falseAccepts: Int, impostorCount: Int, falseRejects: Int, genuineCount: Int)
    {
        self.threshold = threshold
        self.falseAccepts = falseAccepts
        self.impostorCount = impostorCount
        self.falseRejects = falseRejects
        self.genuineCount = genuineCount
    }

    /// False accept rate; 0 when there are no impostors.
    public var far: Double { impostorCount == 0 ? 0 : Double(falseAccepts) / Double(impostorCount) }
    /// False reject rate; 0 when there are no genuine pairs.
    public var frr: Double { genuineCount == 0 ? 0 : Double(falseRejects) / Double(genuineCount) }
    /// Fraction of all pairs decided correctly.
    public var accuracy: Double {
        let total = impostorCount + genuineCount
        guard total > 0 else { return 0 }
        return Double(total - falseAccepts - falseRejects) / Double(total)
    }
}

/// FAR/FRR as functions of the similarity threshold, from genuine and impostor score samples.
///
/// Non-finite scores are dropped (and counted in `droppedScores`): they cannot be ordered.
public struct VerificationCurve: Sendable {
    /// Genuine scores, ascending.
    public let genuine: [Float]
    /// Impostor scores, ascending.
    public let impostor: [Float]
    public let droppedScores: Int

    public init(genuineScores: [Float], impostorScores: [Float]) {
        let g = genuineScores.filter(\.isFinite)
        let i = impostorScores.filter(\.isFinite)
        droppedScores = genuineScores.count - g.count + impostorScores.count - i.count
        genuine = g.sorted()
        impostor = i.sorted()
    }

    public init(pairs: [ScoredPair]) {
        self.init(
            genuineScores: pairs.filter(\.isGenuine).map(\.score),
            impostorScores: pairs.filter { !$0.isGenuine }.map(\.score))
    }

    /// Smallest FAR this sample can distinguish from zero: one false accept.
    public var farResolution: Double { impostor.isEmpty ? 1 : 1 / Double(impostor.count) }

    public func point(at threshold: Float) -> OperatingPoint {
        OperatingPoint(
            threshold: threshold,
            falseAccepts: impostor.count - Self.countBelow(threshold, in: impostor),
            impostorCount: impostor.count,
            falseRejects: Self.countBelow(threshold, in: genuine),
            genuineCount: genuine.count)
    }

    /// The **lowest** threshold whose FAR is `<= targetFAR` (lowest = best recall at that FAR).
    ///
    /// With `N` impostors, at most `k = floor(targetFAR * N)` may be accepted, so the threshold is just
    /// above the `(k+1)`-th highest impostor score. Returns nil without impostors or for a negative or
    /// non-finite target. When `k >= N`, every pair is accepted and the threshold is the lowest score
    /// (capped at the cosine floor -1).
    public func threshold(forFAR targetFAR: Double) -> OperatingPoint? {
        guard !impostor.isEmpty, targetFAR.isFinite, targetFAR >= 0 else { return nil }
        let n = impostor.count
        // The epsilon keeps e.g. 0.2 * 5 from flooring to 0 through representation error.
        let allowed = Int((targetFAR * Double(n) + 1e-9).rounded(.down))
        if allowed >= n {
            let lowest = min(impostor[0], genuine.first ?? impostor[0], -1)
            return point(at: lowest)
        }
        return point(at: impostor[n - 1 - allowed].nextUp)
    }

    /// Every distinct operating point: one threshold at each distinct score, plus one above the
    /// highest score (accept nothing). Ordered by ascending threshold (FAR descending).
    public func rocPoints() -> [OperatingPoint] {
        let thresholds = Array(Set(genuine + impostor)).sorted()
        var points = thresholds.map { point(at: $0) }
        if let top = thresholds.last { points.append(point(at: top.nextUp)) }
        return points
    }

    /// The operating point with the highest accuracy over `rocPoints()` (ties: lowest threshold).
    public func bestAccuracy() -> OperatingPoint? {
        var best: OperatingPoint?
        for p in rocPoints() where p.accuracy > (best?.accuracy ?? -1) {
            best = p
        }
        return best
    }

    /// Equal error rate: the ROC point minimizing `|FAR - FRR|`, reported as `(FAR + FRR) / 2`.
    public func equalErrorRate() -> (rate: Double, point: OperatingPoint)? {
        guard let p = rocPoints().min(by: { abs($0.far - $0.frr) < abs($1.far - $1.frr) }) else { return nil }
        return ((p.far + p.frr) / 2, p)
    }

    /// Standard LFW k-fold accuracy: for each fold, pick the best-accuracy threshold on the other
    /// folds and score the held-out fold with it. Returns the per-fold accuracies, in fold order.
    public static func kFoldAccuracy(_ pairs: [ScoredPair]) -> [Double] {
        let folds = Set(pairs.map(\.fold)).sorted()
        guard folds.count > 1 else { return [] }
        return folds.map { fold in
            let train = VerificationCurve(pairs: pairs.filter { $0.fold != fold })
            let test = VerificationCurve(pairs: pairs.filter { $0.fold == fold })
            guard let threshold = train.bestAccuracy()?.threshold else { return 0 }
            return test.point(at: threshold).accuracy
        }
    }

    /// Number of elements `< value` in an ascending array (binary search).
    static func countBelow(_ value: Float, in sorted: [Float]) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Cosine scores of every unordered pair `(i, j)`, `i < j`, split by whether `labels` agree.
    /// `vectors` must be L2-normalized and of equal length. O(n²) dot products.
    public static func allPairScores<Label: Hashable>(vectors: [[Float]], labels: [Label])
        -> (genuine: [Float], impostor: [Float])
    {
        precondition(vectors.count == labels.count, "one label per vector")
        let n = vectors.count
        guard n > 1, let dimension = vectors.first?.count, dimension > 0 else { return ([], []) }
        precondition(vectors.allSatisfy { $0.count == dimension }, "vectors must share a dimension")
        let matrix = vectors.flatMap { $0 }
        var genuine: [Float] = []
        var impostor: [Float] = []
        impostor.reserveCapacity(n * (n - 1) / 2)
        var row = [Float](repeating: 0, count: n)
        matrix.withUnsafeBufferPointer { m in
            for i in 0..<(n - 1) {
                let rest = n - i - 1
                row.withUnsafeMutableBufferPointer { out in
                    // (rest x d) * (d x 1): rows i+1..<n against row i.
                    vDSP_mmul(
                        m.baseAddress! + (i + 1) * dimension, 1, m.baseAddress! + i * dimension, 1,
                        out.baseAddress!, 1, vDSP_Length(rest), 1, vDSP_Length(dimension))
                }
                for k in 0..<rest {
                    if labels[i] == labels[i + 1 + k] {
                        genuine.append(row[k])
                    } else {
                        impostor.append(row[k])
                    }
                }
            }
        }
        return (genuine, impostor)
    }
}

/// Order statistics for reporting score/margin distributions.
public enum Percentiles {
    /// Nearest-rank percentile (`p` in 0...100) of `values`; nil when empty.
    /// The rank is `ceil(p / 100 * n)`, clamped to `1...n`.
    public static func nearestRank(_ p: Double, of values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

import Accelerate
import HaloCore

/// An embedding with its (benchmark) identity label. Vectors must be L2-normalized.
public struct LabeledEmbedding: Sendable {
    public var identity: String
    public var vector: [Float]

    public init(identity: String, vector: [Float]) {
        self.identity = identity
        self.vector = vector
    }
}

/// A simulated gallery: `enrolled` identities with their enrollment vectors, probes of those
/// identities (`knownProbes`), and probes of everyone else (`unknownProbes`, the open-set case).
public struct GallerySplit: Sendable {
    /// Enrolled identities, sorted by name, with their enrollment vectors.
    public var enrolled: [(identity: String, vectors: [[Float]])]
    public var knownProbes: [LabeledEmbedding]
    public var unknownProbes: [LabeledEmbedding]
}

/// How a gallery scored one probe: the best and second-best enrolled *person*.
public struct ProbeScore: Hashable, Sendable {
    /// The probe's true identity.
    public var truth: String
    /// Whether `truth` is enrolled in the gallery.
    public var isEnrolled: Bool
    /// Best-scoring enrolled identity; nil for an empty gallery.
    public var top1: String?
    /// Max cosine over `top1`'s enrollment vectors.
    public var top1Score: Float
    /// Best score of any other person; nil when the gallery has one person.
    public var top2Score: Float?

    public init(truth: String, isEnrolled: Bool, top1: String?, top1Score: Float, top2Score: Float?) {
        self.truth = truth
        self.isEnrolled = isEnrolled
        self.top1 = top1
        self.top1Score = top1Score
        self.top2Score = top2Score
    }

    /// Top-1 minus top-2; against the cosine floor -1 with a single person (as `GalleryMatcher`).
    public var margin: Float { top1Score - (top2Score ?? -1) }
    /// True when the best candidate is the right person.
    public var top1IsCorrect: Bool { top1 != nil && top1 == truth }

    /// The matcher's decision for this probe under `policy`. Mirrors `GalleryMatcher.match`
    /// (similarity gate, then margin gate with exact ties ambiguous); kept in lockstep by a test.
    public func decision(_ policy: MatchPolicy) -> ProbeDecision {
        guard top1 != nil, top1Score.isFinite else { return .unknown }
        guard top1Score >= policy.minSimilarity else { return .unknown }
        let m = margin
        guard m > 0, m >= policy.minMargin else { return .ambiguous }
        return top1IsCorrect ? .correct : .wrongLabel
    }
}

public enum ProbeDecision: Hashable, Sendable {
    /// Labeled with the right name.
    case correct
    /// Labeled with a wrong name: the error invariant 4 ranks worst.
    case wrongLabel
    /// Rejected by the margin gate.
    case ambiguous
    /// Rejected by the similarity gate.
    case unknown
}

/// Per-frame open-set outcome counts for one policy.
public struct OpenSetStats: Hashable, Sendable {
    public var policy: MatchPolicy
    public var knownProbes = 0
    public var unknownProbes = 0
    public var correct = 0
    /// Enrolled probes given another enrolled person's name.
    public var wrongOnKnown = 0
    /// Non-enrolled probes given an enrolled person's name.
    public var wrongOnUnknown = 0
    public var ambiguous = 0
    public var rejected = 0

    public var probes: Int { knownProbes + unknownProbes }
    public var wrongLabels: Int { wrongOnKnown + wrongOnUnknown }
    /// Wrong names per probe (frame).
    public var falseLabelRate: Double { probes == 0 ? 0 : Double(wrongLabels) / Double(probes) }
    /// Correct names per enrolled probe.
    public var knownRecall: Double { knownProbes == 0 ? 0 : Double(correct) / Double(knownProbes) }
}

/// Margin distributions of correct vs wrong top-1 candidates.
public struct MarginSummary: Hashable, Sendable {
    public var count: Int
    public var p1: Float?
    public var p5: Float?
    public var p50: Float?
    public var p95: Float?
    public var p99: Float?
    public var max: Float?

    public init(_ margins: [Float]) {
        count = margins.count
        p1 = Percentiles.nearestRank(1, of: margins)
        p5 = Percentiles.nearestRank(5, of: margins)
        p50 = Percentiles.nearestRank(50, of: margins)
        p95 = Percentiles.nearestRank(95, of: margins)
        p99 = Percentiles.nearestRank(99, of: margins)
        max = margins.max()
    }
}

/// Emulates the app's gallery on a labeled benchmark: enroll N identities, probe with the rest.
public enum OpenSetSimulation {
    /// Picks `gallerySize` identities (seeded shuffle of those with more than `enrollPerPerson`
    /// images), enrolls the first `enrollPerPerson` images of each (input order) and probes with the
    /// remaining ones. Every image of a non-enrolled identity is an unknown probe.
    public static func split(
        _ items: [LabeledEmbedding], gallerySize: Int, enrollPerPerson: Int = 1, seed: UInt64
    ) -> GallerySplit {
        var byIdentity: [String: [[Float]]] = [:]
        for item in items { byIdentity[item.identity, default: []].append(item.vector) }
        let perPerson = max(1, enrollPerPerson)
        var eligible = byIdentity.filter { $0.value.count > perPerson }.keys.sorted()
        var rng = SeededGenerator(seed: seed)
        eligible.shuffle(using: &rng)
        let chosen = Set(eligible.prefix(max(0, gallerySize)))

        var enrolled: [(identity: String, vectors: [[Float]])] = []
        var known: [LabeledEmbedding] = []
        var unknown: [LabeledEmbedding] = []
        for identity in byIdentity.keys.sorted() {
            let vectors = byIdentity[identity] ?? []
            if chosen.contains(identity) {
                enrolled.append((identity, Array(vectors.prefix(perPerson))))
                known += vectors.dropFirst(perPerson).map { LabeledEmbedding(identity: identity, vector: $0) }
            } else {
                unknown += vectors.map { LabeledEmbedding(identity: identity, vector: $0) }
            }
        }
        return GallerySplit(enrolled: enrolled, knownProbes: known, unknownProbes: unknown)
    }

    /// Scores every probe against the gallery: per-person max cosine, then top-1 and top-2 people.
    public static func score(_ split: GallerySplit) -> [ProbeScore] {
        let people = split.enrolled.map(\.identity)
        var owner: [Int] = []
        var matrix: [Float] = []
        var dimension = 0
        for (index, person) in split.enrolled.enumerated() {
            for vector in person.vectors {
                dimension = vector.count
                owner.append(index)
                matrix += vector
            }
        }
        let rows = owner.count
        let enrolled = Set(people)
        let probes = split.knownProbes + split.unknownProbes
        var rowScores = [Float](repeating: 0, count: rows)
        return probes.map { probe in
            let isEnrolled = enrolled.contains(probe.identity)
            guard rows > 0, probe.vector.count == dimension else {
                return ProbeScore(
                    truth: probe.identity, isEnrolled: isEnrolled, top1: nil, top1Score: -.infinity,
                    top2Score: nil)
            }
            matrix.withUnsafeBufferPointer { m in
                probe.vector.withUnsafeBufferPointer { q in
                    rowScores.withUnsafeMutableBufferPointer { out in
                        vDSP_mmul(
                            m.baseAddress!, 1, q.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(rows), 1,
                            vDSP_Length(dimension))
                    }
                }
            }
            var personScores = [Float](repeating: -.infinity, count: people.count)
            for (row, person) in owner.enumerated() {
                personScores[person] = Swift.max(personScores[person], rowScores[row])
            }
            return topTwo(personScores, people: people, truth: probe.identity, isEnrolled: isEnrolled)
        }
    }

    /// Top-1 / top-2 people from per-person scores (first index wins an exact tie for top-1; the
    /// tied runner-up then gives margin 0, which the decision treats as ambiguous).
    static func topTwo(_ scores: [Float], people: [String], truth: String, isEnrolled: Bool) -> ProbeScore {
        var best = (index: -1, score: -Float.infinity)
        var second = -Float.infinity
        for (index, score) in scores.enumerated() {
            if score > best.score {
                second = best.score
                best = (index, score)
            } else if score > second {
                second = score
            }
        }
        return ProbeScore(
            truth: truth, isEnrolled: isEnrolled, top1: best.index >= 0 ? people[best.index] : nil,
            top1Score: best.score, top2Score: scores.count > 1 ? second : nil)
    }

    public static func evaluate(_ scores: [ProbeScore], policy: MatchPolicy) -> OpenSetStats {
        var stats = OpenSetStats(policy: policy)
        for s in scores {
            if s.isEnrolled { stats.knownProbes += 1 } else { stats.unknownProbes += 1 }
            switch s.decision(policy) {
            case .correct: stats.correct += 1
            case .wrongLabel:
                if s.isEnrolled { stats.wrongOnKnown += 1 } else { stats.wrongOnUnknown += 1 }
            case .ambiguous: stats.ambiguous += 1
            case .unknown: stats.rejected += 1
            }
        }
        return stats
    }

    /// The smallest candidate `minMargin` (searched in ascending order) whose per-frame false-label
    /// rate at `minSimilarity` is `<= maxFalseLabelRate`. Nil when no candidate gets there.
    public static func suggestMinMargin(
        _ scores: [ProbeScore], minSimilarity: Float, maxFalseLabelRate: Double, candidates: [Float]
    ) -> OpenSetStats? {
        for margin in candidates.sorted() {
            let stats = evaluate(
                scores, policy: MatchPolicy(minSimilarity: minSimilarity, minMargin: margin, minVotes: 1))
            if stats.falseLabelRate <= maxFalseLabelRate { return stats }
        }
        return nil
    }

    /// Margins of probes whose top-1 clears `minSimilarity` (the ones the margin gate decides),
    /// split into right and wrong top-1 candidates.
    public static func marginSummaries(_ scores: [ProbeScore], minSimilarity: Float)
        -> (correct: MarginSummary, wrong: MarginSummary)
    {
        let gated = scores.filter { $0.top1 != nil && $0.top1Score >= minSimilarity }
        return (
            MarginSummary(gated.filter(\.top1IsCorrect).map(\.margin)),
            MarginSummary(gated.filter { !$0.top1IsCorrect }.map(\.margin))
        )
    }
}

/// Deterministic SplitMix64 PRNG so simulations are reproducible from a seed.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

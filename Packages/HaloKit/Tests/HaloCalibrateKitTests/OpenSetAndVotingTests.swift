import Foundation
import HaloCore
import HaloMatching
import Testing

@testable import HaloCalibrateKit

// Synthetic vectors and hand-made probe scores only.

private func probe(_ truth: String, enrolled: Bool, top1: String, _ s1: Float, _ s2: Float?) -> ProbeScore {
    ProbeScore(truth: truth, isEnrolled: enrolled, top1: top1, top1Score: s1, top2Score: s2)
}

private func unit(_ v: [Float]) -> [Float] {
    let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return v.map { $0 / n }
}

private func randomUnit(_ dimension: Int, _ rng: inout SeededGenerator) -> [Float] {
    unit((0..<dimension).map { _ in Float.random(in: -1...1, using: &rng) })
}

// MARK: - Decisions

@Test func decisionFollowsSimilarityThenMarginGates() {
    let policy = MatchPolicy(minSimilarity: 0.5, minMargin: 0.1, minVotes: 1)
    #expect(probe("A", enrolled: true, top1: "A", 0.8, 0.6).decision(policy) == .correct)
    #expect(probe("A", enrolled: true, top1: "B", 0.8, 0.6).decision(policy) == .wrongLabel)
    #expect(probe("X", enrolled: false, top1: "B", 0.8, 0.6).decision(policy) == .wrongLabel)
    #expect(probe("A", enrolled: true, top1: "A", 0.4, 0.1).decision(policy) == .unknown)
    #expect(probe("A", enrolled: true, top1: "A", 0.8, 0.75).decision(policy) == .ambiguous)
    // Exact tie is ambiguous even with a zero margin policy.
    let zero = MatchPolicy(minSimilarity: 0.5, minMargin: 0, minVotes: 1)
    #expect(probe("A", enrolled: true, top1: "A", 0.8, 0.8).decision(zero) == .ambiguous)
    // Single enrolled person: margin against the cosine floor.
    #expect(probe("A", enrolled: true, top1: "A", 0.8, nil).margin == 1.8)
    #expect(
        ProbeScore(truth: "A", isEnrolled: true, top1: nil, top1Score: -.infinity, top2Score: nil)
            .decision(zero) == .unknown)
}

@Test func decisionsMatchGalleryMatcher() {
    // Lockstep check: the simulation's decision must equal the app's matcher on the same vectors.
    var rng = SeededGenerator(seed: 3)
    let dimension = 8
    var items: [LabeledEmbedding] = []
    for person in 0..<12 {
        let centre = randomUnit(dimension, &rng)
        for _ in 0..<4 {
            let noisy = zip(centre, randomUnit(dimension, &rng)).map { $0 + 0.6 * $1 }
            items.append(LabeledEmbedding(identity: "P\(person)", vector: unit(noisy)))
        }
    }
    let split = OpenSetSimulation.split(items, gallerySize: 6, enrollPerPerson: 2, seed: 1)
    #expect(split.enrolled.count == 6)
    let space = EmbeddingSpace(modelID: "synthetic-8", dimension: dimension)
    var ids: [String: PersonID] = [:]
    var gallery: [FaceEmbedding] = []
    for person in split.enrolled {
        let id = PersonID()
        ids[person.identity] = id
        gallery += person.vectors.map {
            FaceEmbedding(personID: id, space: space, vector: $0, source: .liveCapture, quality: 1)
        }
    }
    let matcher = GalleryMatcher(gallery: gallery, space: space)
    let probes = split.knownProbes + split.unknownProbes
    let scores = OpenSetSimulation.score(split)
    #expect(scores.count == probes.count)
    let policies = [
        MatchPolicy(minSimilarity: 0.2, minMargin: 0, minVotes: 1),
        MatchPolicy(minSimilarity: 0.5, minMargin: 0.05, minVotes: 1),
        MatchPolicy(minSimilarity: 0.7, minMargin: 0.15, minVotes: 1),
    ]
    for policy in policies {
        for (score, p) in zip(scores, probes) {
            let expected: ProbeDecision
            switch matcher.match(p.vector, policy: policy) {
            case .known(let id, _, _): expected = id == ids[p.identity] ? .correct : .wrongLabel
            case .ambiguous: expected = .ambiguous
            case .unknown: expected = .unknown
            }
            #expect(score.decision(policy) == expected)
        }
    }
}

// MARK: - Gallery split

@Test func splitEnrollsEligibleIdentitiesDeterministically() {
    let v: [Float] = [1, 0]
    var items: [LabeledEmbedding] = []
    for name in ["A", "B", "C", "D"] {
        items += (0..<3).map { _ in LabeledEmbedding(identity: name, vector: v) }
    }
    items.append(LabeledEmbedding(identity: "Solo", vector: v))  // one image: never enrolled
    let a = OpenSetSimulation.split(items, gallerySize: 2, seed: 9)
    let b = OpenSetSimulation.split(items, gallerySize: 2, seed: 9)
    #expect(a.enrolled.map(\.identity) == b.enrolled.map(\.identity))
    #expect(a.enrolled.count == 2)
    #expect(a.enrolled.allSatisfy { $0.vectors.count == 1 })
    #expect(a.knownProbes.count == 4)  // 2 identities x (3 - 1)
    #expect(a.unknownProbes.count == 7)  // 2 identities x 3 + Solo
    #expect(!a.enrolled.contains { $0.identity == "Solo" })
    let all = OpenSetSimulation.split(items, gallerySize: 99, seed: 9)
    #expect(all.enrolled.count == 4)
}

@Test func scoreTakesPerPersonMaxAndTopTwo() {
    let split = GallerySplit(
        enrolled: [("A", [[1, 0], [0, 1]]), ("B", [[0.6, 0.8]])],
        knownProbes: [LabeledEmbedding(identity: "A", vector: [0, 1])],
        unknownProbes: [LabeledEmbedding(identity: "Z", vector: [0.8, 0.6])])
    let scores = OpenSetSimulation.score(split)
    // Probe (0,1): A = max(0, 1) = 1, B = 0.8.
    #expect(scores[0].top1 == "A")
    #expect(abs(scores[0].top1Score - 1) < 1e-6)
    #expect(abs((scores[0].top2Score ?? 0) - 0.8) < 1e-6)
    #expect(scores[0].isEnrolled)
    // Probe (0.8,0.6): A = max(0.8, 0.6) = 0.8, B = 0.96.
    #expect(scores[1].top1 == "B")
    #expect(!scores[1].isEnrolled)
    #expect(!scores[1].top1IsCorrect)
}

// MARK: - Open-set stats and margin suggestion

private let marginFixture = [
    probe("A", enrolled: true, top1: "A", 0.8, 0.6),  // correct, margin 0.20
    probe("X", enrolled: false, top1: "A", 0.7, 0.65),  // wrong, margin 0.05
    probe("B", enrolled: true, top1: "A", 0.9, 0.78),  // wrong, margin 0.12
    probe("C", enrolled: true, top1: "C", 0.3, 0.1),  // below similarity
]

@Test func evaluateCountsOutcomes() {
    let stats = OpenSetSimulation.evaluate(
        marginFixture, policy: MatchPolicy(minSimilarity: 0.5, minMargin: 0.1, minVotes: 1))
    #expect(stats.knownProbes == 3)
    #expect(stats.unknownProbes == 1)
    #expect(stats.correct == 1)
    #expect(stats.wrongOnKnown == 1)
    #expect(stats.wrongOnUnknown == 0)
    #expect(stats.ambiguous == 1)
    #expect(stats.rejected == 1)
    #expect(stats.falseLabelRate == 0.25)
    #expect(abs(stats.knownRecall - 1.0 / 3.0) < 1e-12)
}

@Test func suggestMinMarginPicksSmallestMeetingTarget() throws {
    let stats = try #require(
        OpenSetSimulation.suggestMinMargin(
            marginFixture, minSimilarity: 0.5, maxFalseLabelRate: 0, candidates: [0.3, 0.1, 0, 0.15]))
    #expect(stats.policy.minMargin == 0.15)
    #expect(stats.wrongLabels == 0)
    #expect(stats.correct == 1)
    // A looser target accepts one wrong label in four probes.
    let loose = try #require(
        OpenSetSimulation.suggestMinMargin(
            marginFixture, minSimilarity: 0.5, maxFalseLabelRate: 0.25, candidates: [0, 0.1, 0.15]))
    #expect(loose.policy.minMargin == 0.1)
    // Unreachable: a wrong label with a huge margin.
    let hopeless = [probe("X", enrolled: false, top1: "A", 0.9, 0.0)]
    #expect(
        OpenSetSimulation.suggestMinMargin(
            hopeless, minSimilarity: 0.5, maxFalseLabelRate: 0, candidates: [0, 0.3])
            == nil)
}

@Test func marginSummariesSplitCorrectAndWrong() {
    let (correct, wrong) = OpenSetSimulation.marginSummaries(marginFixture, minSimilarity: 0.5)
    #expect(correct.count == 1)
    #expect(wrong.count == 2)
    #expect(abs((wrong.max ?? 0) - 0.12) < 1e-6)
    #expect(abs((correct.p50 ?? 0) - 0.2) < 1e-6)
}

// MARK: - Voting

private let good = probe("A", enrolled: true, top1: "A", 0.8, 0.3)
private let bad = probe("A", enrolled: true, top1: "B", 0.8, 0.3)
private let lowScore = probe("A", enrolled: true, top1: "A", 0.2, 0.1)
private let votingPolicy = MatchPolicy(minSimilarity: 0.5, minMargin: 0.1, minVotes: 2)

@Test func twoVotesLetAWrongPairThrough() {
    let track = SimulatedTrack(truth: "A", isEnrolled: true, frames: [bad, bad, good, good, good])
    let stats = VotingSimulation.simulate([track], policy: votingPolicy)
    #expect(stats.tracks == 1)
    #expect(stats.tracksEverWrong == 1)
    // Frame 2 takes B; frame 3 keeps it (B is still 2 of 3 in the window); frame 4 switches to A.
    #expect(stats.wrongLabelFrames == 2)
    #expect(stats.knownTracksEverCorrect == 1)
    #expect(stats.totalFrames == 5)
}

@Test func threeVotesBlockTheSameTrack() {
    var policy = votingPolicy
    policy.minVotes = 3
    let track = SimulatedTrack(truth: "A", isEnrolled: true, frames: [bad, bad, good, good, good])
    let stats = VotingSimulation.simulate([track], policy: policy)
    #expect(stats.tracksEverWrong == 0)
    #expect(stats.wrongLabelFrames == 0)
    #expect(stats.knownTrackRecall == 1)
}

@Test func unknownIdentityTrackNamedIsAlwaysWrong() {
    let impostor = probe("X", enrolled: false, top1: "A", 0.8, 0.3)
    let tracks = [
        SimulatedTrack(truth: "X", isEnrolled: false, frames: [impostor, impostor, impostor]),
        SimulatedTrack(truth: "A", isEnrolled: true, frames: [lowScore, lowScore, lowScore]),
    ]
    let stats = VotingSimulation.simulate(tracks, policy: votingPolicy)
    #expect(stats.tracks == 2)
    #expect(stats.knownTracks == 1)
    #expect(stats.tracksEverWrong == 1)
    #expect(stats.wrongLabelFrames == 2)
    #expect(stats.trackFalseLabelRate == 0.5)
    #expect(stats.knownTrackRecall == 0)
}

@Test func makeTracksIsDeterministicAndSingleIdentity() {
    let scores = [good, bad, lowScore, probe("X", enrolled: false, top1: "A", 0.8, 0.3)]
    let a = VotingSimulation.makeTracks(scores, framesPerTrack: 6, tracksPerIdentity: 3, seed: 5)
    let b = VotingSimulation.makeTracks(scores, framesPerTrack: 6, tracksPerIdentity: 3, seed: 5)
    #expect(a.count == 6)  // 2 identities x 3 tracks
    #expect(a.map { $0.frames.map(\.top1Score) } == b.map { $0.frames.map(\.top1Score) })
    #expect(
        a.allSatisfy { track in track.frames.count == 6 && track.frames.allSatisfy { $0.truth == track.truth }
        })
    #expect(a.filter { !$0.isEnrolled }.count == 3)
}

// MARK: - Recommendation

@Test func roundUpToHundredthNeverLoosens() {
    #expect(Recommender.roundUpToHundredth(0.3) == 0.3)
    #expect(Recommender.roundUpToHundredth(0.301) == 0.31)
    #expect(Recommender.roundUpToHundredth(0.29999) == 0.3)
    #expect(Recommender.roundUpToHundredth(Float(0.42).nextUp) == 0.43)
    var rng = SeededGenerator(seed: 11)
    for _ in 0..<1000 {
        let value = Float.random(in: -1...1, using: &rng)
        let rounded = Recommender.roundUpToHundredth(value)
        #expect(rounded >= value)
        #expect(rounded - value < 0.0101)
    }
}

@Test func minVotesPicksSmallestMeetingTarget() {
    func stats(_ n: Int, wrong: Int) -> VotingStats {
        var s = VotingStats(policy: MatchPolicy(minSimilarity: 0.5, minMargin: 0.1, minVotes: n))
        s.tracks = 1000
        s.tracksEverWrong = wrong
        return s
    }
    #expect(
        Recommender.minVotes(
            [stats(4, wrong: 0), stats(2, wrong: 5), stats(3, wrong: 1)], maxTrackFalseLabelRate: 0.001) == 3)
    #expect(
        Recommender.minVotes(
            [stats(2, wrong: 9), stats(3, wrong: 4), stats(4, wrong: 4)], maxTrackFalseLabelRate: 0.001) == 4)
    #expect(Recommender.minVotes([], maxTrackFalseLabelRate: 0.001) == nil)
}

@Test func minMarginTakesHardestGalleryAndFallback() {
    func gallery(_ margin: Float?) -> GalleryResult {
        let base = OpenSetStats(policy: MatchPolicy(minSimilarity: 0.4, minMargin: margin ?? 0, minVotes: 1))
        return GalleryResult(
            gallerySize: 10, margins: (MarginSummary([]), MarginSummary([])),
            suggested: margin == nil ? nil : base, atRecommended: base, atConservative: base)
    }
    #expect(Recommender.minMargin([gallery(0.02), gallery(0.05)], fallback: 0.3) == 0.05)
    #expect(Recommender.minMargin([gallery(0.02), gallery(nil)], fallback: 0.3) == 0.3)
}

@Test func reportRendersPolicyAndTables() {
    let curve = VerificationCurve(
        genuineScores: [0.9, 0.8, 0.6, 0.4], impostorScores: [0.7, 0.5, 0.3, 0.2, 0.1])
    let summary = VerificationSummary(
        name: "pairs.txt", curve: curve, farTargets: [0.2, 0.001], fixedThresholds: [0.5],
        kFold: [1, 0.5])
    let report = CalibrationReport(
        modelID: "synthetic-model", dataset: "synthetic", date: "2026-01-01", imagesReferenced: 9,
        imagesEmbedded: 9, pairsSkipped: 0, standard: summary, extended: nil, farTarget: 0.001,
        galleries: [], voting: [], framesPerTrack: 10,
        recommended: MatchPolicy(minSimilarity: 0.31, minMargin: 0.05, minVotes: 3), notes: ["note"])
    let md = report.markdown()
    #expect(md.contains("`synthetic-model`"))
    #expect(md.contains("MatchPolicy(minSimilarity: 0.31, minMargin: 0.05, minVotes: 3)"))
    #expect(md.contains("| pairs.txt | 4 | 5 | 20.000% | 0.5000 | 20.0000% | 25.00% |"))
    #expect(md.contains("(below resolution)"))  // 0.1% of 5 impostors
    #expect(md.contains("accuracy: 75.00% ± 25.00%"))
    #expect(md.contains("- note"))
}

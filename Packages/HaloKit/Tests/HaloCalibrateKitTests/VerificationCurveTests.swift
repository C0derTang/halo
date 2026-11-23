import Foundation
import Testing

@testable import HaloCalibrateKit

// Synthetic scores only. The hand-computed fixture below is the reference for the FAR/FRR math:
//   genuine  = [0.9, 0.8, 0.6, 0.4]
//   impostor = [0.7, 0.5, 0.3, 0.2, 0.1]
// Decision rule: accept iff score >= threshold.

private let genuine: [Float] = [0.9, 0.8, 0.6, 0.4]
private let impostor: [Float] = [0.7, 0.5, 0.3, 0.2, 0.1]
private let fixture = VerificationCurve(genuineScores: genuine, impostorScores: impostor)

@Test func pointCountsAcceptsAtOrAboveThreshold() {
    let p = fixture.point(at: 0.5)
    #expect(p.falseAccepts == 2)  // 0.7, 0.5 (equal counts as accepted, like the matcher)
    #expect(p.falseRejects == 1)  // 0.4
    #expect(p.far == 0.4)
    #expect(p.frr == 0.25)
    #expect(abs(p.accuracy - 6.0 / 9.0) < 1e-12)
}

@Test func thresholdForFARIsJustAboveTheAllowedImpostor() throws {
    // FAR 20% of 5 impostors allows k = 1 false accept: threshold just above the 2nd-highest (0.5).
    let p = try #require(fixture.threshold(forFAR: 0.2))
    #expect(p.threshold == Float(0.5).nextUp)
    #expect(p.falseAccepts == 1)
    #expect(p.far == 0.2)
    #expect(p.falseRejects == 1)
    #expect(p.frr == 0.25)
}

@Test func thresholdForZeroFARClearsTheHighestImpostor() throws {
    for target in [0.0, 0.19] {  // 0.19 * 5 = 0.95 -> no false accept allowed
        let p = try #require(fixture.threshold(forFAR: target))
        #expect(p.threshold == Float(0.7).nextUp)
        #expect(p.falseAccepts == 0)
        #expect(p.falseRejects == 2)  // 0.6, 0.4
    }
}

@Test func thresholdForFullFARAcceptsEverything() throws {
    let p = try #require(fixture.threshold(forFAR: 1))
    #expect(p.falseAccepts == 5)
    #expect(p.falseRejects == 0)
    #expect(p.threshold <= -1)
}

@Test func thresholdForFARRejectsBadInput() {
    #expect(fixture.threshold(forFAR: -0.1) == nil)
    #expect(fixture.threshold(forFAR: .nan) == nil)
    #expect(VerificationCurve(genuineScores: genuine, impostorScores: []).threshold(forFAR: 0.1) == nil)
}

@Test func tiedImpostorsStayAtOrBelowTarget() throws {
    // k = 1 allowed, but the three tied impostors can only be accepted or rejected together.
    let curve = VerificationCurve(genuineScores: [0.9], impostorScores: [0.5, 0.5, 0.5])
    let p = try #require(curve.threshold(forFAR: 0.34))
    #expect(p.falseAccepts == 0)
    #expect(p.threshold == Float(0.5).nextUp)
}

@Test func thresholdIsTheLowestMeetingTarget() throws {
    // Property on seeded random scores: FAR(t) <= target, and the next-lower impostor score breaks it.
    var rng = SeededGenerator(seed: 7)
    let imp = (0..<1000).map { _ in Float.random(in: -0.3...0.6, using: &rng) }
    let gen = (0..<300).map { _ in Float.random(in: 0.2...0.9, using: &rng) }
    let curve = VerificationCurve(genuineScores: gen, impostorScores: imp)
    for target in [0.0, 0.001, 0.01, 0.05, 0.5] {
        let p = try #require(curve.threshold(forFAR: target))
        #expect(p.far <= target)
        let lowerImpostor = try #require(curve.impostor.last { $0 < p.threshold })
        #expect(curve.point(at: lowerImpostor).far > target)
    }
}

@Test func rocPointsCoverEveryDistinctThreshold() {
    let points = fixture.rocPoints()
    #expect(points.count == 10)  // 9 distinct scores + "accept nothing"
    #expect(points.first?.falseAccepts == 5)
    #expect(points.first?.falseRejects == 0)
    #expect(points.last?.falseAccepts == 0)
    #expect(points.last?.falseRejects == 4)
    for (a, b) in zip(points, points.dropFirst()) {
        #expect(a.threshold < b.threshold)
        #expect(a.far >= b.far)
        #expect(a.frr <= b.frr)
    }
}

@Test func bestAccuracyPrefersLowestTiedThreshold() throws {
    // 7/9 at thresholds 0.4, 0.6 and 0.8; nothing does better.
    let best = try #require(fixture.bestAccuracy())
    #expect(best.threshold == 0.4)
    #expect(abs(best.accuracy - 7.0 / 9.0) < 1e-12)
}

@Test func equalErrorRateFromFixture() throws {
    // |FAR - FRR| is smallest at t = 0.6: FAR 0.2, FRR 0.25.
    let eer = try #require(fixture.equalErrorRate())
    #expect(eer.point.threshold == 0.6)
    #expect(abs(eer.rate - 0.225) < 1e-12)
}

@Test func nonFiniteScoresAreDropped() {
    let curve = VerificationCurve(genuineScores: [0.9, .nan], impostorScores: [0.1, .infinity])
    #expect(curve.genuine == [0.9])
    #expect(curve.impostor == [0.1])
    #expect(curve.droppedScores == 2)
}

@Test func countBelowHandlesDuplicates() {
    let sorted: [Float] = [0.1, 0.2, 0.2, 0.2, 0.5]
    #expect(VerificationCurve.countBelow(0.2, in: sorted) == 1)
    #expect(VerificationCurve.countBelow(0.3, in: sorted) == 4)
    #expect(VerificationCurve.countBelow(0.0, in: sorted) == 0)
    #expect(VerificationCurve.countBelow(9, in: sorted) == 5)
    #expect(VerificationCurve.countBelow(1, in: []) == 0)
}

@Test func farResolutionIsOneImpostor() {
    #expect(fixture.farResolution == 0.2)
}

@Test func kFoldAccuracyUsesOtherFoldsThreshold() {
    // Fold 0 trained on fold 1 picks t = 0.5 -> perfect on fold 0. Fold 1 trained on fold 0 picks
    // t = 0.9 -> rejects both fold-1 pairs -> 50%.
    let pairs = [
        ScoredPair(score: 0.9, isGenuine: true, fold: 0), ScoredPair(score: 0.1, isGenuine: false, fold: 0),
        ScoredPair(score: 0.5, isGenuine: true, fold: 1), ScoredPair(score: 0.6, isGenuine: false, fold: 1),
    ]
    #expect(VerificationCurve.kFoldAccuracy(pairs) == [1.0, 0.5])
    #expect(VerificationCurve.kFoldAccuracy(Array(pairs.prefix(2))).isEmpty)
}

@Test func allPairScoresSplitsByLabel() {
    let c = Float(cos(Double.pi / 3))
    let s = Float(sin(Double.pi / 3))
    let vectors: [[Float]] = [[1, 0], [c, s], [0, 1]]
    let result = VerificationCurve.allPairScores(vectors: vectors, labels: ["a", "a", "b"])
    #expect(result.genuine.count == 1)
    #expect(abs(result.genuine[0] - 0.5) < 1e-6)
    #expect(result.impostor.count == 2)
    #expect(abs(result.impostor[0] - 0) < 1e-6)
    #expect(abs(result.impostor[1] - s) < 1e-6)
    #expect(VerificationCurve.allPairScores(vectors: [[1, 0]], labels: ["a"]).impostor.isEmpty)
}

@Test func nearestRankPercentiles() {
    let values: [Float] = (1...10).map(Float.init).shuffled()
    #expect(Percentiles.nearestRank(50, of: values) == 5)
    #expect(Percentiles.nearestRank(1, of: values) == 1)
    #expect(Percentiles.nearestRank(95, of: values) == 10)
    #expect(Percentiles.nearestRank(0, of: values) == 1)
    #expect(Percentiles.nearestRank(100, of: values) == 10)
    #expect(Percentiles.nearestRank(50, of: []) == nil)
}

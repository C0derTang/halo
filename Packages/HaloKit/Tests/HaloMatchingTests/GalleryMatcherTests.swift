import Foundation
import HaloCore
import Testing

@testable import HaloMatching

private let alice = PersonID()
private let bob = PersonID()
private let policy = MatchPolicy.conservative

@Suite struct GalleryMatcherTests {
    // MARK: Known

    @Test func exactMatchIsKnown() {
        let matcher = makeMatcher([embedding(alice, planar(0)), embedding(bob, planar(90))])
        guard case .known(let id, let similarity, let margin) = matcher.match(planar(0), policy: policy)
        else {
            Issue.record("expected .known")
            return
        }
        #expect(id == alice)
        #expect(approxEqual(similarity, 1))
        #expect(approxEqual(margin, 1))
    }

    @Test func conformsToFaceMatching() {
        let matcher: any FaceMatching = makeMatcher([embedding(alice, planar(0))])
        #expect(matcher.match(planar(0), policy: policy) != .unknown)
    }

    @Test func nonNormalizedInputIsNormalized() {
        let matcher = makeMatcher([
            embedding(alice, [3, 0, 0, 0]), embedding(bob, [0, 0.2, 0, 0]),
        ])
        guard case .known(let id, let similarity, _) = matcher.match([0.01, 0, 0, 0], policy: policy) else {
            Issue.record("expected .known")
            return
        }
        #expect(id == alice)
        #expect(approxEqual(similarity, 1))
    }

    @Test func singlePersonGalleryUsesCosineFloorAsRunnerUp() {
        let matcher = makeMatcher([embedding(alice, planar(0))])
        guard case .known(let id, let similarity, let margin) = matcher.match(planar(0), policy: policy)
        else {
            Issue.record("expected .known")
            return
        }
        #expect(id == alice)
        #expect(approxEqual(similarity, 1))
        #expect(approxEqual(margin, 2))
    }

    // MARK: Open-set rejection

    @Test func belowThresholdIsUnknown() {
        let matcher = makeMatcher([embedding(alice, planar(0)), embedding(bob, planar(180))])
        // Probe sits just below the policy threshold (and far from bob): clear margin, but still not
        // similar enough. Derived from the policy so recalibration can't silently invalidate it.
        let belowDegrees = acos(policy.minSimilarity - 0.05) * 180 / .pi
        #expect(matcher.match(planar(belowDegrees), policy: policy) == .unknown)
    }

    @Test func atThresholdIsKnown() {
        let matcher = makeMatcher([embedding(alice, planar(0)), embedding(bob, planar(180))])
        let strict = MatchPolicy(minSimilarity: 0.5 - 1e-4, minMargin: 0.08, minVotes: 3)
        #expect(matcher.match(planar(60), policy: strict) != .unknown)
    }

    @Test func twoPeopleWithinMarginAreAmbiguous() {
        let matcher = makeMatcher([embedding(alice, planar(0)), embedding(bob, planar(20))])
        // 9° from alice, 11° from bob: both well above threshold, gap ~0.006 < 0.08.
        #expect(matcher.match(planar(9), policy: policy) == .ambiguous)
    }

    @Test func clearMarginBetweenPeopleIsKnown() {
        let matcher = makeMatcher([embedding(alice, planar(0)), embedding(bob, planar(60))])
        // cos(5°) ≈ 0.996 vs cos(55°) ≈ 0.574: margin ≈ 0.42.
        guard case .known(let id, _, let margin) = matcher.match(planar(5), policy: policy) else {
            Issue.record("expected .known")
            return
        }
        #expect(id == alice)
        #expect(approxEqual(margin, cos(5 * .pi / 180) - cos(55 * .pi / 180)))
    }

    @Test func exactTieIsAmbiguousEvenWithZeroMarginPolicy() {
        let matcher = makeMatcher([embedding(alice, planar(0)), embedding(bob, planar(0))])
        let lenient = MatchPolicy(minSimilarity: 0.1, minMargin: 0, minVotes: 1)
        #expect(matcher.match(planar(0), policy: lenient) == .ambiguous)
    }

    @Test func nanPolicyFailsClosed() {
        let matcher = makeMatcher([embedding(alice, planar(0)), embedding(bob, planar(90))])
        let nanSimilarity = MatchPolicy(minSimilarity: .nan, minMargin: 0.08, minVotes: 3)
        let nanMargin = MatchPolicy(minSimilarity: 0.55, minMargin: .nan, minVotes: 3)
        #expect(matcher.match(planar(0), policy: nanSimilarity) == .unknown)
        #expect(matcher.match(planar(0), policy: nanMargin) == .ambiguous)
    }

    // MARK: Same person, many embeddings

    @Test func samePersonManyEmbeddingsIsKnownNotAmbiguous() {
        let gallery = [
            embedding(alice, planar(0)), embedding(alice, planar(2)), embedding(alice, planar(4)),
            embedding(alice, planar(-3)), embedding(bob, planar(90)),
        ]
        let matcher = makeMatcher(gallery)
        #expect(matcher.embeddingCount == 5)
        #expect(matcher.personCount == 2)
        guard case .known(let id, let similarity, let margin) = matcher.match(planar(1), policy: policy)
        else {
            Issue.record("expected .known, same-person embeddings must not create ambiguity")
            return
        }
        #expect(id == alice)
        #expect(approxEqual(similarity, cos(1 * .pi / 180)))
        // Margin is to bob (89° away), not to alice's other embeddings.
        #expect(approxEqual(margin, cos(1 * .pi / 180) - cos(89 * .pi / 180)))
    }

    @Test func samePersonOnlyGalleryIsKnown() {
        let gallery = (0..<20).map { embedding(alice, planar(Float($0) * 0.1)) }
        let matcher = makeMatcher(gallery)
        #expect(matcher.personCount == 1)
        guard case .known(let id, _, _) = matcher.match(planar(1), policy: policy) else {
            Issue.record("expected .known")
            return
        }
        #expect(id == alice)
    }

    @Test func personScoreIsMaxOverEmbeddings() {
        let matcher = makeMatcher([
            embedding(alice, planar(80)), embedding(alice, planar(0)), embedding(bob, planar(90)),
        ])
        let scores = matcher.personScores(for: planar(0))
        #expect(scores.count == 2)
        #expect(approxEqual(scores[0], 1))
        #expect(approxEqual(scores[1], 0))
    }

    // MARK: Unconfirmed embeddings

    @Test func nilPersonEmbeddingsAreIgnored() {
        let matcher = makeMatcher([embedding(nil, planar(0)), embedding(bob, planar(90))])
        #expect(matcher.embeddingCount == 1)
        #expect(matcher.personCount == 1)
        // The exact match is unconfirmed; bob is orthogonal → nobody.
        #expect(matcher.match(planar(0), policy: policy) == .unknown)
    }

    @Test func onlyNilPersonEmbeddingsIsEmptyGallery() {
        let matcher = makeMatcher([embedding(nil, planar(0)), embedding(nil, planar(45))])
        #expect(matcher.personCount == 0)
        #expect(matcher.match(planar(0), policy: policy) == .unknown)
    }

    // MARK: Malformed input

    @Test func emptyGalleryIsUnknown() {
        let matcher = makeMatcher([])
        #expect(matcher.space == space4)
        #expect(matcher.embeddingCount == 0)
        #expect(matcher.personCount == 0)
        #expect(matcher.match(planar(0), policy: policy) == .unknown)
        #expect(matcher.match([], policy: policy) == .unknown)
    }

    @Test func nonPositiveSpaceDimensionIsEmptyGallery() {
        let broken = EmbeddingSpace(modelID: "synthetic-broken", dimension: 0)
        let matcher = makeMatcher([embedding(alice, [], space: broken)], space: broken)
        #expect(matcher.personCount == 0)
        #expect(matcher.match([], policy: policy) == .unknown)
    }

    @Test func queryDimensionMismatchIsUnknown() {
        let matcher = makeMatcher([embedding(alice, planar(0))])
        #expect(matcher.match([1, 0, 0], policy: policy) == .unknown)
        #expect(matcher.match([1, 0, 0, 0, 0], policy: policy) == .unknown)
        #expect(matcher.match([], policy: policy) == .unknown)
    }

    @Test func galleryRowsWithWrongLengthOrOtherSpaceAreIgnored() {
        let other = EmbeddingSpace(modelID: "synthetic-other", dimension: 4)
        let matcher = makeMatcher([
            embedding(alice, planar(0)),
            embedding(bob, [1, 0, 0]),  // length disagrees with its space
            embedding(bob, planar(0), space: other),  // different model: never compared
        ])
        #expect(matcher.space == space4)
        #expect(matcher.personCount == 1)
        guard case .known(let id, _, _) = matcher.match(planar(0), policy: policy) else {
            Issue.record("expected .known")
            return
        }
        #expect(id == alice)
    }

    @Test func onlyRowsFromTheRequestedSpaceSurviveWhenItAppearsSecond() {
        // Same dimension, different model: must never be compared even though the shapes fit.
        let other = EmbeddingSpace(modelID: "synthetic-other", dimension: 4)
        let gallery = [
            embedding(bob, planar(0), space: other),
            embedding(bob, planar(1), space: other),
            embedding(alice, planar(90)),
            embedding(alice, planar(91)),
        ]
        let matcher = makeMatcher(gallery, space: space4)
        #expect(matcher.space == space4)
        #expect(matcher.embeddingCount == 2)
        #expect(matcher.personCount == 1)
        // Bob's other-model rows would be an exact match; only alice (orthogonal) is in the gallery.
        #expect(matcher.match(planar(0), policy: policy) == .unknown)
        guard case .known(let id, _, _) = matcher.match(planar(90), policy: policy) else {
            Issue.record("expected .known")
            return
        }
        #expect(id == alice)

        let otherMatcher = makeMatcher(gallery, space: other)
        #expect(otherMatcher.embeddingCount == 2)
        guard case .known(let otherID, _, _) = otherMatcher.match(planar(0), policy: policy) else {
            Issue.record("expected .known")
            return
        }
        #expect(otherID == bob)
    }

    @Test func impreciseNormalizationFailsClosed() {
        // Finite, non-zero, but its sum of squares is a single subnormal ulp: sqrt is far off and
        // the "normalized" vector is not unit length. Must be rejected, not scored.
        let degenerate: [Float] = [3e-23, 0, 0, 0]
        #expect(GalleryMatcher.normalized(degenerate) == nil)
        let matcher = makeMatcher([embedding(alice, planar(0)), embedding(bob, degenerate)])
        #expect(matcher.embeddingCount == 1)
        #expect(matcher.match(degenerate, policy: policy) == .unknown)
        // Tiny but well-conditioned input still normalizes.
        #expect(GalleryMatcher.normalized([1e-10, 0, 0, 0]) != nil)
    }

    @Test func zeroOrNonFiniteQueryIsUnknown() {
        let matcher = makeMatcher([embedding(alice, planar(0)), embedding(bob, planar(90))])
        #expect(matcher.match([0, 0, 0, 0], policy: policy) == .unknown)
        #expect(matcher.match([.nan, 0, 0, 0], policy: policy) == .unknown)
        #expect(matcher.match([1, .nan, 0, 0], policy: policy) == .unknown)
        #expect(matcher.match([.infinity, 0, 0, 0], policy: policy) == .unknown)
        #expect(matcher.match([-.infinity, 1, 0, 0], policy: policy) == .unknown)
    }

    @Test func zeroOrNonFiniteGalleryRowsAreDropped() {
        let matcher = makeMatcher([
            embedding(alice, planar(0)),
            embedding(bob, [0, 0, 0, 0]),
            embedding(bob, [.nan, 1, 0, 0]),
            embedding(bob, [.infinity, 0, 0, 0]),
        ])
        #expect(matcher.embeddingCount == 1)
        #expect(matcher.personCount == 1)
        guard case .known(let id, _, _) = matcher.match(planar(0), policy: policy) else {
            Issue.record("expected .known")
            return
        }
        #expect(id == alice)
    }

    // MARK: Performance (non-gating)

    @Test func performance10kBy512() {
        let dimension = 512
        let space = EmbeddingSpace(modelID: "synthetic-512", dimension: dimension)
        var rng = SplitMix64(seed: 42)
        let people = (0..<1_000).map { _ in PersonID() }
        var gallery: [FaceEmbedding] = []
        gallery.reserveCapacity(10_000)
        for index in 0..<10_000 {
            let vector = randomUnitVector(dimension: dimension, using: &rng)
            gallery.append(embedding(people[index % people.count], vector, space: space))
        }
        let matcher = makeMatcher(gallery, space: space)
        #expect(matcher.embeddingCount == 10_000)

        let query = gallery[1_234].vector
        let clock = ContinuousClock()
        var durations: [Duration] = []
        var result = MatchResult.unknown
        for _ in 0..<25 {
            durations.append(clock.measure { result = matcher.match(query, policy: policy) })
        }
        durations.sort()
        let median = durations[durations.count / 2]
        print("GalleryMatcher 10k x 512: median \(median), min \(durations[0]) over \(durations.count) runs")

        // Correctness only; the < 5 ms target is reported above, not asserted (CI timing is noisy).
        guard case .known(let id, _, _) = result else {
            Issue.record("expected .known for a query equal to a gallery row")
            return
        }
        #expect(id == people[1_234 % people.count])
    }
}

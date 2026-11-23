import HaloCore
import Testing

@testable import HaloMatching

private let alice = PersonID()
private let bob = PersonID()
private let track = TrackID(1)
private let other = TrackID(2)

private func known(_ person: PersonID, _ similarity: Float = 0.9) -> MatchResult {
    .known(person, similarity: similarity, margin: 0.2)
}

private func isKnown(_ result: MatchResult, as person: PersonID) -> Bool {
    if case .known(let id, _, _) = result { return id == person }
    return false
}

/// Feeds `results` to `voter` for `trackID` and returns every emitted stable identity.
@discardableResult
private func feed(_ voter: inout TrackVoter, _ results: [MatchResult], trackID: TrackID = track)
    -> [MatchResult]
{
    results.map { voter.record($0, for: trackID) }
}

@Suite struct TrackVoterTests {
    let policy = MatchPolicy.conservative  // minVotes = 3

    @Test func labelsOnlyAfterMinVotesConsecutiveAgreeing() {
        var voter = TrackVoter(policy: policy)
        let out = feed(&voter, [known(alice), known(alice), known(alice)])
        #expect(out[0] == .unknown)
        #expect(out[1] == .unknown)
        #expect(isKnown(out[2], as: alice))
        #expect(isKnown(voter.identity(for: track), as: alice))
    }

    @Test func unknownResetsStreak() {
        var voter = TrackVoter(policy: policy)
        let out = feed(&voter, [known(alice), known(alice), .unknown, known(alice), known(alice)])
        #expect(out.allSatisfy { $0 == .unknown })
        #expect(isKnown(voter.record(known(alice), for: track), as: alice))
    }

    @Test func ambiguousResetsStreak() {
        var voter = TrackVoter(policy: policy)
        let out = feed(&voter, [known(alice), known(alice), .ambiguous, known(alice), known(alice)])
        #expect(out.allSatisfy { $0 == .unknown })
        #expect(isKnown(voter.record(known(alice), for: track), as: alice))
    }

    @Test func differentPersonResetsStreak() {
        var voter = TrackVoter(policy: policy)
        let out = feed(&voter, [known(alice), known(alice), known(bob), known(alice), known(alice)])
        #expect(out.allSatisfy { $0 == .unknown })
        #expect(isKnown(voter.record(known(alice), for: track), as: alice))
    }

    @Test func switchingIdentityRequiresMinVotes() {
        var voter = TrackVoter(policy: policy)
        feed(&voter, [known(alice), known(alice), known(alice)])
        let out = feed(&voter, [known(bob), known(bob), known(bob)])
        #expect(isKnown(out[0], as: alice))
        #expect(isKnown(out[1], as: alice))
        #expect(isKnown(out[2], as: bob))
    }

    @Test func interruptedSwitchKeepsCurrentLabel() {
        var voter = TrackVoter(policy: policy)
        feed(&voter, [known(alice), known(alice), known(alice)])
        let out = feed(&voter, [known(bob), known(bob), known(alice)])
        #expect(out.allSatisfy { isKnown($0, as: alice) })
    }

    @Test func briefDropoutKeepsLabel() {
        var voter = TrackVoter(policy: policy)
        feed(&voter, [known(alice), known(alice), known(alice)])
        let out = feed(&voter, [.unknown, .ambiguous, known(alice)])
        #expect(out.allSatisfy { isKnown($0, as: alice) })
    }

    @Test func periodicSingleDropoutsKeepLabel() {
        var voter = TrackVoter(policy: policy)
        feed(&voter, [known(alice), known(alice), known(alice)])
        let pattern = [known(alice), known(alice), MatchResult.unknown]
        let out = feed(&voter, Array(repeating: pattern, count: 5).flatMap { $0 })
        #expect(out.allSatisfy { isKnown($0, as: alice) })
    }

    @Test func sustainedNonKnownDropsLabel() {
        var voter = TrackVoter(policy: policy)
        feed(&voter, [known(alice), known(alice), known(alice)])
        // Unknown and ambiguous both count against the held name.
        let out = feed(&voter, [.unknown, .ambiguous, .unknown])
        #expect(isKnown(out[0], as: alice))
        #expect(isKnown(out[1], as: alice))
        #expect(out[2] == .unknown)
    }

    @Test func otherPersonMixedWithUnknownDropsLabel() {
        var voter = TrackVoter(policy: policy)
        feed(&voter, [known(alice), known(alice), known(alice)])
        let out = feed(&voter, [known(bob), .unknown, known(bob)])
        #expect(isKnown(out[0], as: alice))
        #expect(isKnown(out[1], as: alice))
        #expect(out[2] == .unknown)
    }

    @Test func otherPersonThenAmbiguousDropsLabel() {
        var voter = TrackVoter(policy: policy)
        feed(&voter, [known(alice), known(alice), known(alice)])
        let out = feed(&voter, [known(bob), known(bob), .ambiguous])
        #expect(isKnown(out[0], as: alice))
        #expect(isKnown(out[1], as: alice))
        #expect(out[2] == .unknown)
    }

    @Test func heldPersonLosingMajorityDropsLabel() {
        var voter = TrackVoter(policy: policy)
        feed(&voter, [known(alice), known(alice), known(alice)])
        // Alice keeps resetting the off-streak, but is no longer a strict majority of the last 6.
        let out = feed(&voter, [known(bob), known(bob), known(alice), known(bob), known(bob), known(alice)])
        #expect(out[0...2].allSatisfy { isKnown($0, as: alice) })
        #expect(out[3] == .unknown)
        #expect(out[5] == .unknown)
        #expect(voter.identity(for: track) == .unknown)
    }

    @Test func alternatingNeverLabels() {
        var voter = TrackVoter(policy: policy)
        let out = feed(&voter, Array(repeating: [known(alice), known(bob)], count: 10).flatMap { $0 })
        #expect(out.allSatisfy { $0 == .unknown })
    }

    @Test func relabelAfterDropNeedsFreshVotes() {
        var voter = TrackVoter(policy: policy)
        feed(&voter, [known(alice), known(alice), known(alice), .unknown, .unknown, .unknown])
        let out = feed(&voter, [known(alice), known(alice), known(alice)])
        #expect(out[0] == .unknown)
        #expect(out[1] == .unknown)
        #expect(isKnown(out[2], as: alice))
    }

    @Test func labelRefreshesSimilarityWhileHeld() {
        var voter = TrackVoter(policy: policy)
        feed(&voter, [known(alice, 0.7), known(alice, 0.7), known(alice, 0.7)])
        #expect(voter.record(known(alice, 0.95), for: track) == known(alice, 0.95))
    }

    @Test func forgetClearsTrackState() {
        var voter = TrackVoter(policy: policy)
        feed(&voter, [known(alice), known(alice), known(alice)])
        voter.forget(trackID: track)
        #expect(voter.identity(for: track) == .unknown)
        #expect(voter.trackCount == 0)
        #expect(voter.record(known(alice), for: track) == .unknown)
    }

    @Test func tracksVoteIndependently() {
        var voter = TrackVoter(policy: policy)
        voter.record(known(alice), for: track)
        voter.record(known(bob), for: other)
        voter.record(known(alice), for: track)
        voter.record(known(bob), for: other)
        #expect(isKnown(voter.record(known(alice), for: track), as: alice))
        #expect(isKnown(voter.record(known(bob), for: other), as: bob))
    }

    @Test func retainOnlyDropsLostTracks() {
        var voter = TrackVoter(policy: policy)
        feed(&voter, [known(alice), known(alice), known(alice)], trackID: track)
        feed(&voter, [known(bob), known(bob), known(bob)], trackID: other)
        voter.retain(only: [other])
        #expect(voter.trackCount == 1)
        #expect(voter.identity(for: track) == .unknown)
        #expect(isKnown(voter.identity(for: other), as: bob))
        voter.removeAll()
        #expect(voter.trackCount == 0)
    }

    @Test(arguments: [0, 1, -5])
    func minVotesBelowTwoLabelsImmediately(minVotes: Int) {
        var voter = TrackVoter(policy: MatchPolicy(minSimilarity: 0.55, minMargin: 0.08, minVotes: minVotes))
        #expect(isKnown(voter.record(known(alice), for: track), as: alice))
        #expect(isKnown(voter.record(known(bob), for: track), as: bob))
        #expect(voter.record(.unknown, for: track) == .unknown)
    }

    @Test func unknownTrackReportsUnknown() {
        let voter = TrackVoter(policy: policy)
        #expect(voter.identity(for: TrackID(99)) == .unknown)
    }
}

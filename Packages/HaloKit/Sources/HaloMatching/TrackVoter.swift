import HaloCore

/// Per-track vote accumulator that turns noisy per-frame `MatchResult`s into a stable identity
/// (invariant 4: a wrong name is worse than no name).
///
/// Rules, with `n = max(1, policy.minVotes)`:
/// - A track gets a name only after `n` consecutive `.known` results for the same person.
/// - Any `.unknown`, `.ambiguous`, or `.known` for a different person resets the streak.
/// - Once named, switching to a different person also needs `n` consecutive agreeing results.
/// - Once named, `n` consecutive non-`.known` results (`.unknown`/`.ambiguous`) drop the name back
///   to `.unknown`, so a track that drifts onto a stranger does not keep a name forever.
/// - Until a track is named (or after its name is dropped) it reports `.unknown`.
///
/// Call `forget(trackID:)` when the tracker loses a track.
public struct TrackVoter: Sendable {
    private struct State: Sendable {
        /// The identity currently reported for the track (`.known` or `.unknown`).
        var stable: MatchResult = .unknown
        /// Person the current run of `.known` results agrees on; nil while the run is non-`.known`.
        var candidate: PersonID?
        /// Length of the current run (of `.known` for `candidate`, or of non-`.known` results).
        var streak = 0
    }

    /// Single source of the vote threshold (`minVotes`).
    public var policy: MatchPolicy
    private var states: [TrackID: State] = [:]

    public init(policy: MatchPolicy) {
        self.policy = policy
    }

    private var requiredVotes: Int { max(1, policy.minVotes) }

    /// Number of tracks currently holding vote state.
    public var trackCount: Int { states.count }

    /// Records one frame's match for `trackID` and returns the track's stable identity.
    @discardableResult
    public mutating func record(_ result: MatchResult, for trackID: TrackID) -> MatchResult {
        var state = states[trackID] ?? State()
        let required = requiredVotes

        switch result {
        case .known(let person, let similarity, let margin):
            if state.candidate == person {
                state.streak += 1
            } else {
                state.candidate = person
                state.streak = 1
            }
            if case .known(person, _, _) = state.stable {
                // Already named this person: keep the label and refresh its scores.
                state.stable = .known(person, similarity: similarity, margin: margin)
            } else if state.streak >= required {
                state.stable = .known(person, similarity: similarity, margin: margin)
            }
        case .unknown, .ambiguous:
            if state.candidate != nil {
                state.candidate = nil
                state.streak = 1
            } else {
                state.streak += 1
            }
            if state.streak >= required {
                state.stable = .unknown
            }
        }

        states[trackID] = state
        return state.stable
    }

    /// The stable identity currently reported for `trackID` (`.unknown` for an untracked id).
    public func identity(for trackID: TrackID) -> MatchResult {
        states[trackID]?.stable ?? .unknown
    }

    /// Drops all vote state for a lost track.
    public mutating func forget(trackID: TrackID) {
        states[trackID] = nil
    }

    /// Drops vote state for every track not in `liveTracks`.
    public mutating func retain(only liveTracks: Set<TrackID>) {
        states = states.filter { liveTracks.contains($0.key) }
    }

    /// Drops all vote state.
    public mutating func removeAll() {
        states.removeAll()
    }
}

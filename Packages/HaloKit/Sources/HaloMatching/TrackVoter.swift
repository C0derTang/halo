import HaloCore

/// Per-track vote accumulator that turns noisy per-frame `MatchResult`s into a stable identity
/// (invariant 4: a wrong name is worse than no name).
///
/// Rules, with `n = max(1, policy.minVotes)`:
/// - **Acquire.** A track gets a name only after `n` consecutive `.known` results for the same
///   person. Any `.unknown`, `.ambiguous`, or `.known` for a different person resets that streak.
/// - **Switch.** Once named, switching to a different person also needs `n` consecutive agreeing
///   `.known` results for that person.
/// - **Drop (streak).** Once named, `n` consecutive results that are anything other than
///   `.known(heldPerson)` (unknown, ambiguous, other people, in any mix) drop the name to
///   `.unknown`, unless that same result completes a switch.
/// - **Drop (majority).** Once named, if the held person is not a strict majority of the track's
///   last `2n` results, the name drops to `.unknown`. The window starts when the name is taken
///   (seeded with the `n` agreeing results), so a fresh switch is not judged on the previous
///   person's frames.
/// - Until a track is named, or after its name is dropped, it reports `.unknown`; a dropped track
///   needs a fresh acquire streak.
///
/// Call `forget(trackID:)` when the tracker loses a track.
public struct TrackVoter: Sendable {
    private struct State: Sendable {
        /// The identity currently reported for the track (`.known` or `.unknown`).
        var stable: MatchResult = .unknown
        /// Person the current run of `.known` results agrees on; nil after a non-`.known` result.
        var candidate: PersonID?
        /// Length of the current run of `.known(candidate)` results.
        var candidateStreak = 0
        /// While named: consecutive results other than `.known(heldPerson)`.
        var offStreak = 0
        /// While named: the person each recent result named (nil for unknown/ambiguous), oldest
        /// first, at most `2n` long, starting when the name was taken.
        var window: [PersonID?] = []

        var heldPerson: PersonID? {
            if case .known(let person, _, _) = stable { return person }
            return nil
        }
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

        // Acquire/switch streak.
        let person: PersonID?
        if case .known(let id, _, _) = result { person = id } else { person = nil }
        if let person, state.candidate == person {
            state.candidateStreak += 1
        } else {
            state.candidate = person
            state.candidateStreak = person == nil ? 0 : 1
        }

        if let held = state.heldPerson {
            state.window.append(person)
            while state.window.count > 2 * required { state.window.removeFirst() }
            state.offStreak = person == held ? 0 : state.offStreak + 1

            if person == held, case .known(_, let similarity, let margin) = result {
                // Still the held person: keep the name and refresh its scores.
                state.stable = .known(held, similarity: similarity, margin: margin)
            }
            if let candidate = state.candidate, candidate != held, state.candidateStreak >= required,
                case .known(_, let similarity, let margin) = result
            {
                take(candidate, similarity: similarity, margin: margin, required: required, in: &state)
            } else if state.offStreak >= required || !Self.isStrictMajority(held, in: state.window) {
                state.stable = .unknown
                state.offStreak = 0
                state.window = []
            }
        } else if let candidate = state.candidate, state.candidateStreak >= required,
            case .known(_, let similarity, let margin) = result
        {
            take(candidate, similarity: similarity, margin: margin, required: required, in: &state)
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

    private func take(
        _ person: PersonID, similarity: Float, margin: Float, required: Int, in state: inout State
    ) {
        state.stable = .known(person, similarity: similarity, margin: margin)
        state.offStreak = 0
        state.window = Array(repeating: person, count: required)
    }

    private static func isStrictMajority(_ person: PersonID, in window: [PersonID?]) -> Bool {
        let votes = window.reduce(0) { $0 + ($1 == person ? 1 : 0) }
        return votes * 2 > window.count
    }
}

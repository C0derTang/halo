import Foundation
import HaloCore

/// Per-track embedding throttle and re-verification bookkeeping (invariants 4 and 7).
///
/// Selection rules for one frame at time `now`:
/// - Only `eligible` candidates (seen this frame, quality and size gates passed) are considered.
/// - A track is due when it has never been attempted or its last attempt is `>= embedInterval` ago.
/// - Priority, highest first: labeled tracks overdue for re-verification (last attempt
///   `>= reverifyInterval` ago), then unlabeled tracks, then other labeled tracks. Ties go to the
///   longest-waiting track, then the lowest TrackID, so the order is deterministic.
/// - At most `maxEmbedsPerFrame` are selected; their attempt time is recorded on selection.
struct EmbedSchedule: Sendable {
    struct Candidate: Sendable {
        var id: TrackID
        var labeled: Bool
        var eligible: Bool
    }

    private var lastAttempt: [TrackID: TimeInterval] = [:]
    private var lastEvidence: [TrackID: TimeInterval] = [:]

    /// Selects which tracks to embed this frame and records the attempts.
    mutating func select(_ candidates: [Candidate], now: TimeInterval, config: LensConfig) -> [TrackID] {
        let budget = max(0, config.maxEmbedsPerFrame)
        guard budget > 0 else { return [] }

        var ranked: [(tier: Int, waited: TimeInterval, id: TrackID)] = []
        for c in candidates where c.eligible {
            let waited: TimeInterval
            if let last = lastAttempt[c.id], now >= last {
                waited = now - last
                guard waited >= config.embedInterval else { continue }
            } else {
                // Never attempted, or the clock went backwards: due now.
                waited = .infinity
            }
            let tier: Int
            if c.labeled {
                tier = waited >= config.reverifyInterval ? 0 : 2
            } else {
                tier = 1
            }
            ranked.append((tier, waited, c.id))
        }
        ranked.sort {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            if $0.waited != $1.waited { return $0.waited > $1.waited }
            return $0.id.rawValue < $1.id.rawValue
        }
        let chosen = ranked.prefix(budget).map(\.id)
        for id in chosen { lastAttempt[id] = now }
        return chosen
    }

    /// Makes the track due immediately, as if it had never been attempted. For a labeled track this
    /// puts it in the top (overdue re-verify) tier on the next selection.
    mutating func markOverdue(_ id: TrackID) {
        lastAttempt[id] = nil
    }

    /// A successful embedding produced evidence (a match result) for the track.
    mutating func recordEvidence(for id: TrackID, at now: TimeInterval) {
        lastEvidence[id] = now
    }

    /// True when the track has had no evidence for longer than `timeout`.
    func isStale(_ id: TrackID, now: TimeInterval, timeout: TimeInterval) -> Bool {
        guard let last = lastEvidence[id] else { return true }
        return now - last > timeout
    }

    /// Forget bookkeeping for tracks that are no longer live.
    mutating func retain(only live: Set<TrackID>) {
        lastAttempt = lastAttempt.filter { live.contains($0.key) }
        lastEvidence = lastEvidence.filter { live.contains($0.key) }
    }

    var trackedCount: Int { Set(lastAttempt.keys).union(lastEvidence.keys).count }
}

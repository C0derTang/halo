import HaloCore
import HaloMatching

/// A simulated face track: one identity seen over several frames.
public struct SimulatedTrack: Sendable {
    public var truth: String
    public var isEnrolled: Bool
    /// One probe score per frame.
    public var frames: [ProbeScore]

    public init(truth: String, isEnrolled: Bool, frames: [ProbeScore]) {
        self.truth = truth
        self.isEnrolled = isEnrolled
        self.frames = frames
    }
}

/// Track-level outcome counts for one `minVotes`, replayed through the app's `TrackVoter`.
public struct VotingStats: Hashable, Sendable {
    public var policy: MatchPolicy
    public var tracks = 0
    public var knownTracks = 0
    /// Tracks that showed a wrong name on at least one frame.
    public var tracksEverWrong = 0
    /// Enrolled-identity tracks that showed the right name on at least one frame.
    public var knownTracksEverCorrect = 0
    public var totalFrames = 0
    /// Frames on which the voter's stable identity was a wrong name.
    public var wrongLabelFrames = 0

    /// Share of tracks that ever showed a wrong name.
    public var trackFalseLabelRate: Double { tracks == 0 ? 0 : Double(tracksEverWrong) / Double(tracks) }
    /// Share of displayed frames carrying a wrong name.
    public var frameFalseLabelRate: Double {
        totalFrames == 0 ? 0 : Double(wrongLabelFrames) / Double(totalFrames)
    }
    /// Share of enrolled-identity tracks that got their name at some point.
    public var knownTrackRecall: Double {
        knownTracks == 0 ? 0 : Double(knownTracksEverCorrect) / Double(knownTracks)
    }
}

/// Per-track voting over sequences of a single identity's images.
public enum VotingSimulation {
    /// For each identity with at least one probe, `tracksPerIdentity` tracks of `framesPerTrack`
    /// frames, each frame drawn uniformly (with replacement) from that identity's probes.
    /// Identities with a single probe image yield constant tracks: the worst case for voting, since
    /// repeated frames are perfectly correlated.
    public static func makeTracks(
        _ scores: [ProbeScore], framesPerTrack: Int, tracksPerIdentity: Int, seed: UInt64
    ) -> [SimulatedTrack] {
        var byIdentity: [String: [ProbeScore]] = [:]
        for s in scores { byIdentity[s.truth, default: []].append(s) }
        var rng = SeededGenerator(seed: seed)
        var tracks: [SimulatedTrack] = []
        for identity in byIdentity.keys.sorted() {
            guard let pool = byIdentity[identity], let first = pool.first else { continue }
            for _ in 0..<max(0, tracksPerIdentity) {
                let frames = (0..<max(0, framesPerTrack)).map { _ in
                    pool[Int.random(in: 0..<pool.count, using: &rng)]
                }
                tracks.append(SimulatedTrack(truth: identity, isEnrolled: first.isEnrolled, frames: frames))
            }
        }
        return tracks
    }

    /// Replays every track through a fresh `TrackVoter(policy:)`, frame by frame, feeding the
    /// matcher decision of each frame (`ProbeScore.decision`), and counts wrong names shown.
    public static func simulate(_ tracks: [SimulatedTrack], policy: MatchPolicy) -> VotingStats {
        var ids: [String: PersonID] = [:]
        func id(_ name: String) -> PersonID {
            if let existing = ids[name] { return existing }
            let new = PersonID()
            ids[name] = new
            return new
        }

        var stats = VotingStats(policy: policy)
        for (index, track) in tracks.enumerated() {
            var voter = TrackVoter(policy: policy)
            let trackID = TrackID(UInt64(index))
            let truthID = id(track.truth)
            var everWrong = false
            var everCorrect = false
            for frame in track.frames {
                let result: MatchResult
                switch frame.decision(policy) {
                case .correct, .wrongLabel:
                    result = .known(id(frame.top1 ?? ""), similarity: frame.top1Score, margin: frame.margin)
                case .ambiguous: result = .ambiguous
                case .unknown: result = .unknown
                }
                let stable = voter.record(result, for: trackID)
                stats.totalFrames += 1
                if case .known(let shown, _, _) = stable {
                    if shown == truthID && track.isEnrolled {
                        everCorrect = true
                    } else {
                        everWrong = true
                        stats.wrongLabelFrames += 1
                    }
                }
            }
            stats.tracks += 1
            if track.isEnrolled { stats.knownTracks += 1 }
            if everWrong { stats.tracksEverWrong += 1 }
            if everCorrect { stats.knownTracksEverCorrect += 1 }
        }
        return stats
    }
}

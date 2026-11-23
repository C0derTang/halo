import CoreGraphics
import HaloCore

/// One face on screen, as the lens renders it.
public struct LensTrack: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        /// Newly seen; not yet `LensConfig.stableAfterFrames` old.
        case appearing
        /// Seen in the latest frame and established.
        case stable
        /// Not seen in the latest frame; the tracker is coasting it and will drop it soon.
        case lost
    }

    public let trackID: TrackID
    /// Smoothed, normalized (0...1, origin top-left, upright frame) box for rendering.
    public let smoothedBox: CGRect
    /// Stable identity from `TrackVoter`. `.known` only after `minVotes` agreeing matches.
    public let identity: MatchResult
    public let state: State
    /// The recognized person, when `identity` is `.known`.
    public let personID: PersonID?

    public init(trackID: TrackID, smoothedBox: CGRect, identity: MatchResult, state: State) {
        self.trackID = trackID
        self.smoothedBox = smoothedBox
        self.identity = identity
        self.state = state
        if case .known(let person, _, _) = identity {
            self.personID = person
        } else {
            self.personID = nil
        }
    }
}

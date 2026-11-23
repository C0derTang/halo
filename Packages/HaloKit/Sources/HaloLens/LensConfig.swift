import Foundation

/// Lens pipeline tuning. All times are in seconds of frame (media) time, so the schedule is
/// deterministic for a given frame sequence.
public struct LensConfig: Sendable, Equatable {
    /// Minimum time between two embeddings of the same track (per-track throttle, invariant 7).
    public var embedInterval: TimeInterval
    /// A labeled track is re-embedded at least this often. When it is overdue it jumps ahead of
    /// unlabeled tracks for the per-frame embed budget, so a label is always re-checked.
    public var reverifyInterval: TimeInterval
    /// A labeled track with no successful embedding for this long loses its label (evidence
    /// stopped, e.g. face turned away or too small).
    ///
    /// Always strictly greater than `reverifyInterval`, otherwise a label that is being re-verified
    /// on schedule would expire between checks: a requested value `<= reverifyInterval` reads back
    /// as `reverifyInterval + max(reverifyInterval, minimumStaleMargin)`.
    public var staleLabelTimeout: TimeInterval {
        get {
            requestedStaleLabelTimeout > reverifyInterval
                ? requestedStaleLabelTimeout
                : reverifyInterval + max(reverifyInterval, Self.minimumStaleMargin)
        }
        set { requestedStaleLabelTimeout = newValue }
    }
    private var requestedStaleLabelTimeout: TimeInterval
    /// Smallest gap kept between `reverifyInterval` and `staleLabelTimeout` when clamping.
    public static let minimumStaleMargin: TimeInterval = 0.1
    /// At most this many embeddings per processed frame.
    public var maxEmbedsPerFrame: Int
    /// Faces below this capture quality (0...1) are never embedded.
    public var minFaceQuality: Float
    /// Faces whose shorter box side is below this many pixels (upright frame) are never embedded.
    public var minFaceSide: Double
    /// A track is `.appearing` until it is this many frames old, then `.stable`.
    public var stableAfterFrames: Int

    public init(
        embedInterval: TimeInterval = 0.25, reverifyInterval: TimeInterval = 1.0,
        staleLabelTimeout: TimeInterval = 2.0, maxEmbedsPerFrame: Int = 2,
        minFaceQuality: Float = 0.3, minFaceSide: Double = 48, stableAfterFrames: Int = 3
    ) {
        self.embedInterval = embedInterval
        self.reverifyInterval = reverifyInterval
        self.requestedStaleLabelTimeout = staleLabelTimeout
        self.maxEmbedsPerFrame = maxEmbedsPerFrame
        self.minFaceQuality = minFaceQuality
        self.minFaceSide = minFaceSide
        self.stableAfterFrames = stableAfterFrames
    }
}

import CoreGraphics
import HaloCore
import ImageIO

/// One face the lens overlay draws.
///
/// Known-people-only (invariant 1): `label` is non-nil only for a track whose stable identity is
/// `.known` AND whose confirmed person's label has loaded. Everything else (unknown, ambiguous,
/// still loading) renders as a text-free `UnknownFaceRing`.
public struct LensOverlayItem: Identifiable, Hashable, Sendable {
    public let trackID: TrackID
    /// Normalized (0...1, origin top-left) box in the upright frame. Mapped to view points with
    /// `LensOverlayGeometry.viewRect`.
    public let rect: CGRect
    public let state: HologramState
    public let label: LabelData?

    public var id: TrackID { trackID }

    public init(trackID: TrackID, rect: CGRect, state: HologramState, label: LabelData?) {
        self.trackID = trackID
        self.rect = rect
        self.state = state
        self.label = label
    }
}

/// The camera frame the overlay's boxes are normalized against.
public struct LensOverlayFrame: Hashable, Sendable {
    /// Raw pixel-buffer size (before orientation).
    public let bufferSize: CGSize
    /// Orientation that makes the buffer upright (`VideoFrame.orientation`).
    public let orientation: CGImagePropertyOrientation

    public init(bufferSize: CGSize, orientation: CGImagePropertyOrientation) {
        self.bufferSize = bufferSize
        self.orientation = orientation
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bufferSize == rhs.bufferSize && lhs.orientation == rhs.orientation
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bufferSize.width)
        hasher.combine(bufferSize.height)
        hasher.combine(orientation)
    }
}

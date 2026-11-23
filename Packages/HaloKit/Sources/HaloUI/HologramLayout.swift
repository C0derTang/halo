import CoreGraphics
import HaloCore

/// Lifecycle of a hologram label as driven by the lens.
public enum HologramState: Sendable, Hashable {
    case appearing
    case stable
    case lost
}

/// Whether the label animates (scanlines, flicker) or renders a static frame.
public enum HologramMotion: Sendable, Hashable {
    case animated
    case reduced

    /// Maps the system Reduce Motion setting to a motion mode.
    public static func resolve(reduceMotion: Bool) -> HologramMotion {
        reduceMotion ? .reduced : .animated
    }
}

/// Pure layout math for the hologram label. No SwiftUI, fully unit-testable.
/// All geometry is in view points, origin top-left.
public enum HologramLayout {
    /// Label size at scale 1.
    public static let baseSize = CGSize(width: 200, height: 76)
    /// Face height (points) at which the label is drawn at scale 1.
    public static let referenceFaceHeight: CGFloat = 160
    public static let minScale: CGFloat = 0.6
    public static let maxScale: CGFloat = 1.4
    /// Gap between face top and label bottom, as a fraction of face height.
    public static let gapFraction: CGFloat = 0.18
    /// Minimum distance kept between the label and the view edges.
    public static let edgeInset: CGFloat = 8
    /// Chips shown on the lens label (the card shows all).
    public static let maxLabelChips = 2

    public struct Placement: Equatable, Sendable {
        public var frame: CGRect
        public var scale: CGFloat
        /// Top-center of the face, where the leader line ends (clamped into the view).
        public var anchor: CGPoint
    }

    public static func scale(forFaceHeight height: CGFloat) -> CGFloat {
        guard height.isFinite, height > 0 else { return minScale }
        return min(max(height / referenceFaceHeight, minScale), maxScale)
    }

    public static func placement(
        for size: CGSize = baseSize, faceRect: CGRect, viewSize: CGSize
    ) -> Placement {
        let s = scale(forFaceHeight: faceRect.height)
        // Never larger than the view (minus insets), so clamping can always fit.
        let maxW = max(viewSize.width - 2 * edgeInset, 0)
        let maxH = max(viewSize.height - 2 * edgeInset, 0)
        let w = min(size.width * s, maxW)
        let h = min(size.height * s, maxH)
        let gap = faceRect.height * gapFraction
        var x = faceRect.midX - w / 2
        var y = faceRect.minY - gap - h
        x = clamp(x, lower: edgeInset, upper: viewSize.width - edgeInset - w)
        y = clamp(y, lower: edgeInset, upper: viewSize.height - edgeInset - h)
        let anchor = CGPoint(
            x: clamp(faceRect.midX, lower: 0, upper: viewSize.width),
            y: clamp(faceRect.minY, lower: 0, upper: viewSize.height))
        return Placement(frame: CGRect(x: x, y: y, width: w, height: h), scale: s, anchor: anchor)
    }

    public static func frame(
        for size: CGSize = baseSize, faceRect: CGRect, viewSize: CGSize
    ) -> CGRect {
        placement(for: size, faceRect: faceRect, viewSize: viewSize).frame
    }

    public static func visibleChips(_ data: LabelData) -> [LabelChip] {
        Array(data.chips.prefix(maxLabelChips))
    }

    private static func clamp(_ v: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        // If the range is inverted (degenerate view), prefer the lower bound.
        min(max(v, lower), max(upper, lower))
    }
}

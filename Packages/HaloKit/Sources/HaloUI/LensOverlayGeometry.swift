import CoreGraphics
import ImageIO

/// Maps face boxes from the upright video frame into the camera preview's coordinate space.
///
/// The preview layer does not show the frame 1:1. With `.resizeAspectFill` it scales the
/// upright frame until it covers the view and crops the overflow evenly on both sides, so a
/// normalized box has to be scaled by the *upright buffer's* size and then shifted by the
/// (negative) crop offset. Mapping with `x * viewWidth` instead puts labels on the wrong face
/// whenever the frame and view aspect ratios differ, which they always do on an iPhone.
///
/// Pure math, no AVFoundation, so it is unit tested on the host. All view geometry is in points,
/// origin top-left.
public enum LensOverlayGeometry {
    /// How the preview layer fits the frame into the view. Mirrors `AVLayerVideoGravity`.
    public enum VideoGravity: Sendable, Hashable, CaseIterable {
        /// Preserve aspect ratio, fill the view, crop the overflow (the lens uses this).
        case resizeAspectFill
        /// Preserve aspect ratio, fit inside the view, letterbox the rest.
        case resizeAspect
        /// Stretch to the view's bounds.
        case resize
    }

    /// Size of the frame once `orientation` is applied: the space `FaceObservation` boxes and
    /// `LensTrack.smoothedBox` are normalized in. Quarter-turn orientations swap width and height.
    public static func uprightSize(bufferSize: CGSize, orientation: CGImagePropertyOrientation) -> CGSize {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            CGSize(width: bufferSize.height, height: bufferSize.width)
        default:
            bufferSize
        }
    }

    /// Where the upright frame is drawn inside the view (may extend past the view when cropped).
    /// Nil when any size is empty or not finite.
    public static func displayedFrameRect(
        bufferSize: CGSize, orientation: CGImagePropertyOrientation, viewSize: CGSize,
        videoGravity: VideoGravity
    ) -> CGRect? {
        let upright = uprightSize(bufferSize: bufferSize, orientation: orientation)
        guard isUsable(upright), isUsable(viewSize) else { return nil }
        let width: CGFloat
        let height: CGFloat
        switch videoGravity {
        case .resizeAspectFill:
            let scale = max(viewSize.width / upright.width, viewSize.height / upright.height)
            width = upright.width * scale
            height = upright.height * scale
        case .resizeAspect:
            let scale = min(viewSize.width / upright.width, viewSize.height / upright.height)
            width = upright.width * scale
            height = upright.height * scale
        case .resize:
            width = viewSize.width
            height = viewSize.height
        }
        return CGRect(
            x: (viewSize.width - width) / 2, y: (viewSize.height - height) / 2, width: width,
            height: height)
    }

    /// Converts a normalized (0...1, origin top-left) box in the UPRIGHT frame into view points.
    ///
    /// - Parameters:
    ///   - normalized: box in upright frame space, e.g. `LensTrack.smoothedBox`.
    ///   - bufferSize: the pixel buffer's raw width and height (before orientation).
    ///   - orientation: the `VideoFrame.orientation` that makes the buffer upright.
    ///   - viewSize: the preview view's bounds size (the overlay must have the same bounds).
    ///   - videoGravity: the preview layer's video gravity.
    /// - Returns: the rect in view points (may lie partly or wholly outside the view when the face
    ///   is in the cropped margin), or nil when any input is degenerate.
    public static func viewRect(
        forUpright normalized: CGRect, bufferSize: CGSize, orientation: CGImagePropertyOrientation,
        viewSize: CGSize, videoGravity: VideoGravity = .resizeAspectFill
    ) -> CGRect? {
        guard !normalized.isNull, !normalized.isInfinite,
            [normalized.minX, normalized.minY, normalized.width, normalized.height].allSatisfy(\.isFinite),
            let displayed = displayedFrameRect(
                bufferSize: bufferSize, orientation: orientation, viewSize: viewSize,
                videoGravity: videoGravity)
        else { return nil }
        let box = normalized.standardized
        return CGRect(
            x: displayed.minX + box.minX * displayed.width,
            y: displayed.minY + box.minY * displayed.height,
            width: box.width * displayed.width,
            height: box.height * displayed.height)
    }

    private static func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}

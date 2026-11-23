import CoreGraphics
import Foundation

/// Coordinate conventions.
///
/// Vision reports normalized geometry with the origin at the **bottom-left**. Everything HaloVision
/// emits (`FaceObservation.boundingBox`, `.landmarks`) is normalized with the origin at the
/// **top-left** (UIKit/SwiftUI convention), in the upright image orientation.
public enum VisionGeometry {
    /// Converts a normalized bottom-left-origin rect (Vision) to a normalized top-left-origin rect.
    /// Exact: x and size are unchanged, `y' = 1 - (y + height)`. The conversion is its own inverse.
    public static func topLeftRect(fromVisionRect rect: CGRect) -> CGRect {
        let r = rect.standardized
        return CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    /// Converts a normalized bottom-left-origin point (Vision) to a normalized top-left-origin point.
    public static func topLeftPoint(fromVisionPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    /// Normalized top-left rect -> pixel rect (top-left origin) in an image of `size`.
    public static func pixelRect(_ normalized: CGRect, imageSize size: CGSize) -> CGRect {
        CGRect(
            x: normalized.minX * size.width, y: normalized.minY * size.height,
            width: normalized.width * size.width, height: normalized.height * size.height)
    }

    /// Normalized top-left point -> pixel point (top-left origin) in an image of `size`.
    public static func pixelPoint(_ normalized: CGPoint, imageSize size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }

    /// Intersection-over-union of two rects (0 when either is empty).
    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let inter = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }
}

/// The five alignment landmarks, in the order of the ArcFace template:
/// image-left eye, image-right eye, nose tip, image-left mouth corner, image-right mouth corner.
public enum FivePointLandmarks {
    public static let count = 5

    /// Puts raw eye / mouth-corner pairs into template order regardless of face roll.
    ///
    /// "Image-left" is defined relative to the face's own down axis (eye midpoint -> mouth
    /// midpoint), not the image x-axis, so a face rolled past 90° still orders correctly. Points use
    /// top-left-origin coordinates (y grows downward), matching the template.
    public static func canonicalOrder(
        eyes: (CGPoint, CGPoint), nose: CGPoint, mouthCorners: (CGPoint, CGPoint)
    ) -> [CGPoint] {
        let eyeMid = midpoint(eyes.0, eyes.1)
        let mouthMid = midpoint(mouthCorners.0, mouthCorners.1)
        let down = CGPoint(x: mouthMid.x - eyeMid.x, y: mouthMid.y - eyeMid.y)
        let (leftEye, rightEye) = ordered(eyes, down: down)
        let (leftMouth, rightMouth) = ordered(mouthCorners, down: down)
        return [leftEye, rightEye, nose, leftMouth, rightMouth]
    }

    /// In the template (y down) the image-left -> image-right vector crossed with the down vector is
    /// positive: (35, 0) x (0, 1) = 35. Swap the pair when the sign is negative.
    private static func ordered(_ pair: (CGPoint, CGPoint), down: CGPoint) -> (CGPoint, CGPoint) {
        let across = CGPoint(x: pair.1.x - pair.0.x, y: pair.1.y - pair.0.y)
        let cross = across.x * down.y - across.y * down.x
        return cross >= 0 ? pair : (pair.1, pair.0)
    }

    static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    static func centroid(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let n = CGFloat(points.count)
        return CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
    }

    /// The two points farthest apart (mouth corners from the outer-lip contour).
    static func farthestPair(_ points: [CGPoint]) -> (CGPoint, CGPoint)? {
        guard points.count >= 2 else { return nil }
        var best: (CGPoint, CGPoint) = (points[0], points[1])
        var bestDistance: CGFloat = -1
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let dx = points[i].x - points[j].x
                let dy = points[i].y - points[j].y
                let d = dx * dx + dy * dy
                if d > bestDistance {
                    bestDistance = d
                    best = (points[i], points[j])
                }
            }
        }
        return best
    }
}

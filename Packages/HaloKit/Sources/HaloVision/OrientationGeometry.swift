import CoreGraphics
import Foundation
import HaloCore
import ImageIO

/// Geometry between a stored ("raw") image or pixel buffer and its UPRIGHT presentation, for all
/// eight `CGImagePropertyOrientation`s (EXIF / TIFF orientation semantics: the orientation says
/// how the stored pixels must be transformed to display upright).
///
/// Every function works in top-left-origin coordinates. Normalized maps work on 0...1 coordinates;
/// pixel maps on continuous pixel coordinates (pixel `i` covers `[i, i + 1)`, its centre is
/// `i + 0.5`). For the eight orientations the maps are exact isometries, so rectangles map to
/// rectangles and round trips are lossless.
///
/// `FaceObservation`s are always expressed in the upright space (see `VideoFrame`). Vision does
/// the raw -> upright step itself when given the orientation; the embedder uses
/// `rawPixelTransform(fromUprightIn:)` to sample an upright-space face from the raw buffer.
public enum OrientationGeometry {
    /// True for the four orientations whose upright image swaps width and height.
    public static func swapsAxes(_ orientation: CGImagePropertyOrientation) -> Bool {
        switch orientation {
        case .up, .upMirrored, .down, .downMirrored: false
        case .left, .leftMirrored, .right, .rightMirrored: true
        }
    }

    /// True for the four orientations that include a reflection.
    public static func isMirrored(_ orientation: CGImagePropertyOrientation) -> Bool {
        switch orientation {
        case .upMirrored, .downMirrored, .leftMirrored, .rightMirrored: true
        case .up, .down, .left, .right: false
        }
    }

    /// Size of the upright image for a raw image of `rawSize`.
    public static func uprightSize(rawSize: CGSize, orientation: CGImagePropertyOrientation) -> CGSize {
        swapsAxes(orientation) ? CGSize(width: rawSize.height, height: rawSize.width) : rawSize
    }

    /// Normalized raw (u, v) -> normalized upright (x, y), both top-left origin.
    ///
    /// | orientation    | raw row 0 is upright | raw column 0 is upright | (x, y)         |
    /// |----------------|----------------------|-------------------------|----------------|
    /// | up             | top                  | left                    | (u, v)         |
    /// | upMirrored     | top                  | right                   | (1-u, v)       |
    /// | down           | bottom               | right                   | (1-u, 1-v)     |
    /// | downMirrored   | bottom               | left                    | (u, 1-v)       |
    /// | leftMirrored   | left                 | top                     | (v, u)         |
    /// | right          | right                | top                     | (1-v, u)       |
    /// | rightMirrored  | right                | bottom                  | (1-v, 1-u)     |
    /// | left           | left                 | bottom                  | (v, 1-u)       |
    public static func normalizedUprightTransform(_ orientation: CGImagePropertyOrientation)
        -> CGAffineTransform
    {
        // CGAffineTransform: x' = a·x + c·y + tx, y' = b·x + d·y + ty.
        switch orientation {
        case .up: .identity
        case .upMirrored: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0)
        case .down: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
        case .downMirrored: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
        case .leftMirrored: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .right: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        case .rightMirrored: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 1, ty: 1)
        case .left: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)
        }
    }

    /// Raw pixel -> upright pixel (continuous, top-left origin) for a raw image of `rawSize`.
    public static func uprightPixelTransform(rawSize: CGSize, orientation: CGImagePropertyOrientation)
        -> CGAffineTransform
    {
        let upright = uprightSize(rawSize: rawSize, orientation: orientation)
        guard rawSize.width > 0, rawSize.height > 0 else { return .identity }
        return CGAffineTransform(scaleX: 1 / rawSize.width, y: 1 / rawSize.height)
            .concatenating(normalizedUprightTransform(orientation))
            .concatenating(CGAffineTransform(scaleX: upright.width, y: upright.height))
    }

    /// Upright pixel -> raw pixel (continuous, top-left origin): the inverse of
    /// `uprightPixelTransform`.
    public static func rawPixelTransform(
        fromUprightIn rawSize: CGSize, orientation: CGImagePropertyOrientation
    )
        -> CGAffineTransform
    {
        uprightPixelTransform(rawSize: rawSize, orientation: orientation).inverted()
    }

    /// Normalized raw point -> normalized upright point.
    public static func uprightPoint(fromRaw point: CGPoint, orientation: CGImagePropertyOrientation)
        -> CGPoint
    {
        point.applying(normalizedUprightTransform(orientation))
    }

    /// Normalized upright point -> normalized raw point.
    public static func rawPoint(fromUpright point: CGPoint, orientation: CGImagePropertyOrientation)
        -> CGPoint
    {
        point.applying(normalizedUprightTransform(orientation).inverted())
    }

    /// Normalized raw rect -> normalized upright rect (exact: the maps are axis-aligned).
    public static func uprightRect(fromRaw rect: CGRect, orientation: CGImagePropertyOrientation) -> CGRect {
        rect.applying(normalizedUprightTransform(orientation))
    }

    /// Normalized upright rect -> normalized raw rect.
    public static func rawRect(fromUpright rect: CGRect, orientation: CGImagePropertyOrientation) -> CGRect {
        rect.applying(normalizedUprightTransform(orientation).inverted())
    }

    /// Re-expresses a face observed in the raw image (normalized, top-left) in the upright image.
    ///
    /// Box and landmarks are mapped point-wise; five-point landmarks are put back into template
    /// order (a reflection swaps image-left and image-right). `roll` follows the module convention
    /// (see `VisionGeometry.roll(fromLandmarks:imageSize:)`): recomputed from the landmarks when
    /// there are five, otherwise rotated with the image. `yaw` changes sign under a reflection only.
    public static func uprightObservation(
        _ face: FaceObservation, rawSize: CGSize, orientation: CGImagePropertyOrientation
    ) -> FaceObservation {
        let upright = uprightSize(rawSize: rawSize, orientation: orientation)
        var points = face.landmarks.map { uprightPoint(fromRaw: $0, orientation: orientation) }
        if points.count == FivePointLandmarks.count {
            points = FivePointLandmarks.canonicalOrder(
                eyes: (points[0], points[1]), nose: points[2], mouthCorners: (points[3], points[4]))
        }
        let mirrored = isMirrored(orientation)
        let roll =
            VisionGeometry.roll(fromLandmarks: points, imageSize: upright)
            ?? face.roll.map { rawRoll in
                // Eye-line direction in raw pixels, carried through the (orthogonal) pixel map. A
                // reflection swaps which eye is image-left, so the eye line reverses direction.
                let linear = uprightPixelTransform(rawSize: rawSize, orientation: orientation)
                let d = CGPoint(x: cos(rawRoll), y: sin(rawRoll))
                let mapped = CGPoint(
                    x: linear.a * d.x + linear.c * d.y, y: linear.b * d.x + linear.d * d.y)
                let sign: CGFloat = mirrored ? -1 : 1
                return VisionGeometry.normalizedAngle(atan2(Double(sign * mapped.y), Double(sign * mapped.x)))
            }
        return FaceObservation(
            boundingBox: uprightRect(fromRaw: face.boundingBox, orientation: orientation),
            roll: roll,
            yaw: face.yaw.map { mirrored ? -$0 : $0 },
            quality: face.quality,
            landmarks: points,
            timestamp: face.timestamp)
    }
}

import CoreGraphics
import CoreImage
import Foundation
import HaloCore
import ImageIO

/// A 2-D similarity transform (uniform scale, rotation, translation; no reflection or shear):
///
///     x' = a·x − b·y + tx
///     y' = b·x + a·y + ty
///
/// where `a = s·cosθ`, `b = s·sinθ`.
public struct SimilarityTransform: Hashable, Sendable {
    public var a: Double
    public var b: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.tx = tx
        self.ty = ty
    }

    public static let identity = SimilarityTransform(a: 1, b: 0, tx: 0, ty: 0)

    /// Builds `x' = scale·R(rotation)·x + translation`.
    public init(scale: Double, rotation: Double, translation: CGPoint) {
        self.init(
            a: scale * cos(rotation), b: scale * sin(rotation), tx: Double(translation.x),
            ty: Double(translation.y))
    }

    public var scale: Double { (a * a + b * b).squareRoot() }
    public var rotation: Double { atan2(b, a) }

    public func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x)
        let y = Double(p.y)
        return CGPoint(x: a * x - b * y + tx, y: b * x + a * y + ty)
    }

    /// The same mapping as a `CGAffineTransform` (`x' = a·x + c·y + tx`, `y' = b·x + d·y + ty`).
    public var affine: CGAffineTransform {
        CGAffineTransform(
            a: CGFloat(a), b: CGFloat(b), c: CGFloat(-b), d: CGFloat(a), tx: CGFloat(tx), ty: CGFloat(ty))
    }

    /// Least-squares similarity mapping `source[i]` onto `destination[i]` (Umeyama 1991, 2-D
    /// closed form, reflection excluded). Returns nil when the counts differ, there are fewer than
    /// two points, or the source points are all coincident.
    public static func estimate(from source: [CGPoint], to destination: [CGPoint])
        -> SimilarityTransform?
    {
        guard source.count == destination.count, source.count >= 2 else { return nil }
        let n = Double(source.count)
        let srcMean = (
            x: source.reduce(0.0) { $0 + Double($1.x) } / n, y: source.reduce(0.0) { $0 + Double($1.y) } / n
        )
        let dstMean = (
            x: destination.reduce(0.0) { $0 + Double($1.x) } / n,
            y: destination.reduce(0.0) { $0 + Double($1.y) } / n
        )
        var dot = 0.0  // Σ p·q
        var crs = 0.0  // Σ p×q
        var variance = 0.0  // Σ |p|²
        for (s, d) in zip(source, destination) {
            let px = Double(s.x) - srcMean.x
            let py = Double(s.y) - srcMean.y
            let qx = Double(d.x) - dstMean.x
            let qy = Double(d.y) - dstMean.y
            dot += px * qx + py * qy
            crs += px * qy - py * qx
            variance += px * px + py * py
        }
        guard variance > 1e-12 else { return nil }
        let a = dot / variance
        let b = crs / variance
        let tx = dstMean.x - (a * srcMean.x - b * srcMean.y)
        let ty = dstMean.y - (b * srcMean.x + a * srcMean.y)
        return SimilarityTransform(a: a, b: b, tx: tx, ty: ty)
    }
}

/// A face crop aligned to the ArcFace template. Pixels are 8-bit RGBX (alpha byte ignored), rows
/// top to bottom. BIOMETRIC: never persisted, logged or sent anywhere (invariant 2).
public struct AlignedFace: Sendable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes: R, G, B, unused.
    public let rgbx: [UInt8]

    public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let i = (y * width + x) * 4
        return (rgbx[i], rgbx[i + 1], rgbx[i + 2])
    }
}

/// Maps a detected face to the canonical 112x112 ArcFace crop.
///
/// With five landmarks (see `FivePointLandmarks`) it uses the least-squares similarity transform
/// onto `arcFaceTemplate`. Without them it falls back to a padded square crop around the box.
///
/// All coordinates are continuous pixels with a top-left origin: pixel `i` covers `[i, i + 1)` and
/// its centre is `i + 0.5`. Rendering goes through Core Image, from a `CGImage` or straight from a
/// camera `CVPixelBuffer` (any pixel format Core Image reads, e.g. BGRA or 420f), honouring a
/// `CGImagePropertyOrientation`: only the 112x112 output is ever rendered, never an upright copy of
/// the whole frame. The shared context does not cache intermediates.
public struct FaceAligner: Sendable {
    public static let outputSize = 112

    /// InsightFace `arcface_dst` for 112x112 crops, verbatim (OpenCV pixel-index coordinates, where
    /// pixel `i`'s centre is at `i`): image-left eye, image-right eye, nose tip, image-left mouth
    /// corner, image-right mouth corner.
    public static let arcFaceTemplate: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// OpenCV pixel-index coordinates are this module's continuous coordinates minus 0.5 px.
    public static let openCVPixelCentreOffset: CGFloat = 0.5

    /// The alignment target in this module's continuous crop coordinates: `arcFaceTemplate` + 0.5.
    ///
    /// InsightFace estimates `M` from landmarks in OpenCV index space (ours − 0.5 px) onto
    /// `arcface_dst` and samples crop pixel `j` at `M⁻¹(j)`. We sample crop pixel `j` at its centre
    /// `j + 0.5`, so the equivalent continuous transform is `T(p) = M(p − 0.5) + 0.5`, which is
    /// exactly the similarity from our landmarks onto the template shifted by +0.5. That gives
    /// sample-for-sample InsightFace parity (pinned by `FaceAlignerTests`).
    public static let alignmentTarget: [CGPoint] = arcFaceTemplate.map {
        CGPoint(x: $0.x + openCVPixelCentreOffset, y: $0.y + openCVPixelCentreOffset)
    }

    /// Extra margin around the detector box for the no-landmark fallback, as a fraction of the
    /// box's longer side.
    public var boxPadding: Double

    public init(boxPadding: Double = 0.1) {
        self.boxPadding = boxPadding
    }

    /// Shared renderer. `CIContext` is thread-safe (`NS_SWIFT_SENDABLE`); creating one is costly,
    /// so every aligner reuses this one.
    static let renderContext = CIContext(options: [.cacheIntermediates: false])

    /// Transform from upright image pixels (top-left origin) to crop pixels (top-left origin).
    public func transform(for face: FaceObservation, imageSize: CGSize) -> SimilarityTransform {
        if face.landmarks.count == FivePointLandmarks.count {
            let source = face.landmarks.map { VisionGeometry.pixelPoint($0, imageSize: imageSize) }
            if let t = SimilarityTransform.estimate(from: source, to: Self.alignmentTarget) {
                return t
            }
        }
        return boxTransform(for: VisionGeometry.pixelRect(face.boundingBox, imageSize: imageSize))
    }

    /// Fallback: a square of side `max(w, h) · (1 + boxPadding)` centred on the box, scaled to fill
    /// the crop. No rotation.
    public func boxTransform(for pixelBox: CGRect) -> SimilarityTransform {
        let side = max(Double(max(pixelBox.width, pixelBox.height)) * (1 + boxPadding), 1e-6)
        let scale = Double(Self.outputSize) / side
        let half = Double(Self.outputSize) / 2
        return SimilarityTransform(
            a: scale, b: 0, tx: half - scale * Double(pixelBox.midX), ty: half - scale * Double(pixelBox.midY)
        )
    }

    /// Renders the aligned 112x112 crop from an upright image. Pixels outside the image are black.
    public func alignedFace(_ face: FaceObservation, in image: CGImage) throws -> AlignedFace {
        try alignedFace(face, in: CIImage(cgImage: image), orientation: .up)
    }

    /// Renders the aligned crop from a stored image (or `CIImage(cvPixelBuffer:)` of a camera
    /// frame) whose display orientation is `orientation`. `face` is in the upright image.
    public func alignedFace(
        _ face: FaceObservation, in source: CIImage, orientation: CGImagePropertyOrientation
    )
        throws -> AlignedFace
    {
        let upright = OrientationGeometry.uprightSize(rawSize: source.extent.size, orientation: orientation)
        return try render(
            source, orientation: orientation, transform: transform(for: face, imageSize: upright))
    }

    /// Warps an upright `image` by `transform` (image pixels -> crop pixels, both top-left origin).
    public func render(_ image: CGImage, transform: SimilarityTransform) throws -> AlignedFace {
        try render(CIImage(cgImage: image), orientation: .up, transform: transform)
    }

    /// Warps `source` (stored pixels, display orientation `orientation`) by `transform`, which maps
    /// UPRIGHT image pixels to crop pixels (both top-left origin).
    public func render(
        _ source: CIImage, orientation: CGImagePropertyOrientation, transform: SimilarityTransform
    )
        throws -> AlignedFace
    {
        let extent = source.extent
        guard !extent.isInfinite, !extent.isNull, extent.width >= 1, extent.height >= 1 else {
            throw HaloVisionError.preprocessingFailed
        }
        let side = Self.outputSize
        // Core Image space is bottom-left origin for both the source and the output, so the chain is
        // CI(raw) -> top-left(raw) -> top-left(upright) -> top-left(crop) -> CI(crop).
        let rawFromCI = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -extent.minX, ty: extent.maxY)
        let uprightFromRaw = OrientationGeometry.uprightPixelTransform(
            rawSize: extent.size, orientation: orientation)
        let ciFromCrop = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(side))
        let matrix =
            rawFromCI
            .concatenating(uprightFromRaw)
            .concatenating(transform.affine)
            .concatenating(ciFromCrop)
        let warped = source.transformed(by: matrix, highQualityDownsample: true)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw HaloVisionError.preprocessingFailed
        }
        let bytesPerRow = side * 4
        // Premultiplied RGBA8 over a transparent background: area outside the source is black.
        var pixels = [UInt8](repeating: 0, count: side * bytesPerRow)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            Self.renderContext.render(
                warped, toBitmap: base, rowBytes: bytesPerRow,
                bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBA8, colorSpace: space)
        }
        return AlignedFace(width: side, height: side, rgbx: pixels)
    }
}

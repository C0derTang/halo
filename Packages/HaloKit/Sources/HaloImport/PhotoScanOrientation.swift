import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Makes a photo upright before detection and embedding, so `FaceObservation` geometry and the
/// embedder's crop are in the same upright space.
///
/// This is the swap point for orientation handling: once HaloVision takes an orientation directly,
/// a conformance that forwards it can replace `CoreImageUprighter` without touching `PhotoScanJob`.
public protocol PhotoScanUprighting: Sendable {
    func upright(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> CGImage
}

public enum PhotoScanOrientationError: Error, Equatable, Sendable {
    case renderFailed
}

/// `PhotoScanUprighting` with Core Image (`CIImage.oriented(_:)`), on device, CPU or GPU.
/// Pixels are copied without color management, so values are preserved exactly.
public struct CoreImageUprighter: PhotoScanUprighting {
    private let context: CIContext

    public init() {
        context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    }

    public func upright(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> CGImage {
        if orientation == .up { return image }
        let oriented = CIImage(cgImage: image).oriented(orientation)
        let colorSpace =
            image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard
            let rendered = context.createCGImage(
                oriented, from: oriented.extent, format: .RGBA8, colorSpace: colorSpace)
        else { throw PhotoScanOrientationError.renderFailed }
        return rendered
    }
}

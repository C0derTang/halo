import CoreGraphics
import Foundation
import Testing

@testable import HaloVision

/// Pins the pixel-centre convention end to end through Core Image: crop pixel `j` must sample the
/// source at OpenCV's `M⁻¹(j)` (index space, where pixel `i`'s centre is `i`), bilinearly.
///
/// The source is a gentle ramp (R = 64 + x, G = 64 + y), so a bilinear sample at index position
/// `u` has value `64 + u`. With `T(p) = s·p + t` in continuous coordinates, crop pixel `j` has
/// centre `j + 0.5`, hence the continuous source position `(j + 0.5 − t) / s` and index position
/// that minus 0.5. A half-pixel convention error would show as ~0.5·(1/s) LSB or more; the
/// tolerance is about 1 LSB.
@Suite struct PixelCentreRampTests {
    private static let side = 64

    private static func rampImage() throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                bytes[i] = UInt8(64 + x)
                bytes[i + 1] = UInt8(64 + y)
                bytes[i + 2] = 128
            }
        }
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: Data(bytes) as CFData),
            let image = CGImage(
                width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw SyntheticImage.Failure() }
        return image
    }

    @Test(arguments: [
        (2.0, -20.0, -10.0),
        (2.0, -7.5, -33.25),
        (1.5, -12.0, -5.0),
    ])
    func upscaledRampMatchesOpenCVSampling(scale: Double, tx: Double, ty: Double) throws {
        let crop = try FaceAligner().render(
            Self.rampImage(), transform: SimilarityTransform(a: scale, b: 0, tx: tx, ty: ty))
        var checked = 0
        for j in 0..<FaceAligner.outputSize {
            for k in stride(from: 0, to: FaceAligner.outputSize, by: 5) {
                // Expected source index positions (OpenCV: M⁻¹(j) in index space).
                let u = (Double(j) + 0.5 - tx) / scale - 0.5
                let v = (Double(k) + 0.5 - ty) / scale - 0.5
                // Stay clear of the image border, where edge handling is not bilinear.
                guard (1.0...Double(Self.side - 2)).contains(u), (1.0...Double(Self.side - 2)).contains(v)
                else { continue }
                let pixel = crop.pixel(x: j, y: k)
                #expect(abs(Double(pixel.r) - (64 + u)) <= 1.5, "x=\(j) y=\(k)")
                #expect(abs(Double(pixel.g) - (64 + v)) <= 1.5, "x=\(j) y=\(k)")
                checked += 1
            }
        }
        #expect(checked > 100)
    }
}

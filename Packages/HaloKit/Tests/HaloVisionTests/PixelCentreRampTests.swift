import CoreGraphics
import Foundation
import Testing

@testable import HaloVision

/// Pins the pixel-centre convention end to end through Core Image: crop pixel `j` must sample the
/// source at OpenCV's `M⁻¹(j)` (index space, where pixel `i`'s centre is `i`), bilinearly.
///
/// The source is a steep ramp (R = 8·x, G = 8·y, 32 px, max 248: no clipping), so a bilinear
/// sample at index position `u` has value `8·u`. With `T(p) = s·p + t` in continuous coordinates,
/// crop pixel `j` has centre `j + 0.5`, hence the continuous source position `(j + 0.5 − t) / s`
/// and index position that minus 0.5. A half-pixel convention error moves the expectation by
/// `8 · 0.5 / s` >= 2 LSB, well above the 1 LSB tolerance; the negative control proves it.
@Suite struct PixelCentreRampTests {
    private static let side = 32
    private static let slope = 8.0
    private static let tolerance = 1.0

    private static func rampImage() throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                bytes[i] = UInt8(slope * Double(x))
                bytes[i + 1] = UInt8(slope * Double(y))
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
        let interior = 1.0...Double(Self.side - 2)  // clear of the border, where edges are not bilinear
        var checked = 0
        for j in 0..<FaceAligner.outputSize {
            for k in stride(from: 0, to: FaceAligner.outputSize, by: 5) {
                // Expected source index positions (OpenCV: M⁻¹(j) in index space).
                let u = (Double(j) + 0.5 - tx) / scale - 0.5
                let v = (Double(k) + 0.5 - ty) / scale - 0.5
                guard interior.contains(u), interior.contains(v) else { continue }
                let pixel = crop.pixel(x: j, y: k)
                let r = Double(pixel.r)
                let g = Double(pixel.g)
                #expect(abs(r - Self.slope * u) <= Self.tolerance, "x=\(j) y=\(k)")
                #expect(abs(g - Self.slope * v) <= Self.tolerance, "x=\(j) y=\(k)")

                // Negative control: the shifted convention ((j − t)/s − 0.5, no +0.5 pixel centre)
                // must be distinguishable from what was rendered, so a half-pixel error would fail.
                let shiftedU = (Double(j) - tx) / scale - 0.5
                let shiftedV = (Double(k) - ty) / scale - 0.5
                #expect(abs(r - Self.slope * shiftedU) > Self.tolerance, "control x=\(j) y=\(k)")
                #expect(abs(g - Self.slope * shiftedV) > Self.tolerance, "control x=\(j) y=\(k)")
                checked += 1
            }
        }
        #expect(checked > 100)
    }
}

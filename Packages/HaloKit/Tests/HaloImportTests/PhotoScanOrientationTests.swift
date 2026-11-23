import CoreGraphics
import ImageIO
import Testing

@testable import HaloImport

private typealias F = PhotoScanFixture

private let red: [UInt8] = [255, 0, 0, 255]
private let blue: [UInt8] = [0, 0, 255, 255]

/// 2x1 image: red on the left, blue on the right.
private func redBlue() -> CGImage { F.image(width: 2, height: 1, rgba: red + blue) }

@Suite struct PhotoScanOrientationTests {
    @Test func upIsReturnedUnchanged() throws {
        let image = redBlue()
        #expect(try CoreImageUprighter().upright(image, orientation: .up) === image)
    }

    @Test(arguments: [
        (CGImagePropertyOrientation.upMirrored, false), (.down, false), (.downMirrored, false),
        (.leftMirrored, true), (.right, true), (.rightMirrored, true), (.left, true),
    ])
    func quarterTurnsSwapDimensions(orientation: CGImagePropertyOrientation, swaps: Bool) throws {
        let out = try CoreImageUprighter().upright(F.image(width: 40, height: 20), orientation: orientation)
        #expect(out.width == (swaps ? 20 : 40))
        #expect(out.height == (swaps ? 40 : 20))
    }

    /// EXIF 6 (`.right`): displayed after a 90° clockwise turn, so the left pixel ends up on top.
    @Test func rightRotatesClockwise() throws {
        let out = try CoreImageUprighter().upright(redBlue(), orientation: .right)
        #expect(out.width == 1 && out.height == 2)
        #expect(F.pixels(of: out) == red + blue)
    }

    /// EXIF 8 (`.left`): displayed after a 90° counter-clockwise turn, so the left pixel ends up below.
    @Test func leftRotatesCounterClockwise() throws {
        let out = try CoreImageUprighter().upright(redBlue(), orientation: .left)
        #expect(out.width == 1 && out.height == 2)
        #expect(F.pixels(of: out) == blue + red)
    }

    @Test func downAndMirroredFlipHorizontally() throws {
        #expect(F.pixels(of: try CoreImageUprighter().upright(redBlue(), orientation: .down)) == blue + red)
        #expect(
            F.pixels(of: try CoreImageUprighter().upright(redBlue(), orientation: .upMirrored)) == blue + red)
    }
}

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import HaloAppCore

/// `FaceThumbnailCrop` on synthetic images (solid fills and single marker pixels, no faces).
@Suite struct ThumbnailCropTests {
    /// RGBA image, black except one red pixel at (x, y) (top-left origin).
    static func image(width: Int, height: Int, marker: (x: Int, y: Int)? = nil) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        if let marker {
            pixels[(marker.y * width + marker.x) * 4] = 255
        }
        let context = try #require(
            CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        return try #require(context.makeImage())
    }

    /// The (x, y) of the first red pixel, top-left origin.
    static func redPixel(in image: CGImage) throws -> (x: Int, y: Int)? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(
            CGContext(
                data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for y in 0..<image.height {
            for x in 0..<image.width where pixels[(y * image.width + x) * 4] > 128 {
                return (x, y)
            }
        }
        return nil
    }

    @Test func centredFaceGetsAPaddedSquare() throws {
        // A 100x100 px face in the middle of a 1000x800 photo.
        let box = CGRect(x: 0.45, y: 0.4375, width: 0.1, height: 0.125)
        let rect = try #require(FaceThumbnailCrop.cropRect(faceBox: box, width: 1000, height: 800))
        let side = 100 * (1 + 2 * FaceThumbnailCrop.padding)
        #expect(rect.width == side)
        #expect(rect.height == side)
        #expect(rect.midX == 500)
        #expect(rect.midY == 400)
    }

    @Test func faceAtTheEdgeShiftsInsteadOfLeavingTheImage() throws {
        let box = CGRect(x: 0, y: 0.9, width: 0.1, height: 0.1)
        let rect = try #require(FaceThumbnailCrop.cropRect(faceBox: box, width: 1000, height: 1000))
        #expect(rect.minX == 0)
        #expect(rect.maxY == 1000)
        #expect(rect.width == rect.height)
        #expect(rect.contains(CGPoint(x: 50, y: 950)))
    }

    @Test func faceLargerThanThePhotoIsClampedToIt() throws {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let rect = try #require(FaceThumbnailCrop.cropRect(faceBox: box, width: 400, height: 300))
        #expect(rect == CGRect(x: 50, y: 0, width: 300, height: 300))
    }

    @Test func unusableBoxesShowTheWholePhoto() throws {
        let photo = try Self.image(width: 40, height: 30)
        for box in [
            CGRect(x: 2, y: 2, width: 0.1, height: 0.1),  // outside the image
            CGRect(x: 0.1, y: 0.1, width: 0, height: 0.1),  // empty
            CGRect(x: CGFloat.nan, y: 0.1, width: 0.1, height: 0.1),
        ] {
            #expect(FaceThumbnailCrop.cropRect(faceBox: box, width: 40, height: 30) == nil)
            let out = FaceThumbnailCrop.crop(photo, to: box)
            #expect(out.width == 40 && out.height == 30)
        }
        let whole = FaceThumbnailCrop.crop(photo, to: nil)
        #expect(whole.width == 40 && whole.height == 30)
    }

    @Test func cropKeepsTheFaceAndUsesTopLeftCoordinates() throws {
        // Marker at the face centre, near the TOP of the photo.
        let photo = try Self.image(width: 200, height: 100, marker: (150, 20))
        let box = CGRect(x: 0.7, y: 0.1, width: 0.1, height: 0.2)  // centre (150, 20) px
        let crop = FaceThumbnailCrop.crop(photo, to: box)
        #expect(crop.width == 40 && crop.height == 40)
        let red = try #require(try Self.redPixel(in: crop))
        // Square of side 40 centred on (150, 20), shifted down to y = 0: marker at (20, 20).
        #expect(red.x == 20 && red.y == 20)
    }

    @Test func uprightTurnsARotatedPhotoBeforeCropping() throws {
        // Stored landscape 4x2 with orientation .right (displayed rotated 90 degrees clockwise).
        let raw = try Self.image(width: 4, height: 2, marker: (0, 0))
        let upright = try #require(FaceThumbnailCrop.upright(raw, orientation: .right))
        #expect(upright.width == 2 && upright.height == 4)
        // Raw top-left ends up at the upright top-right.
        let red = try #require(try Self.redPixel(in: upright))
        #expect(red.x == 1 && red.y == 0)
        #expect(FaceThumbnailCrop.upright(raw, orientation: .up) === raw)
    }

    @Test func sourceSizeIsJustLargeEnoughForTheCrop() {
        let box = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        // Crop is 0.2 of the photo, so a 320 px thumbnail needs a 1600 px photo.
        #expect(FaceThumbnailCrop.sourcePixelSize(faceBox: box, target: 320, cap: 2048) == 1600)
        #expect(FaceThumbnailCrop.sourcePixelSize(faceBox: box, target: 320, cap: 1000) == 1000)
        let huge = CGRect(x: 0, y: 0, width: 0.9, height: 0.9)
        #expect(FaceThumbnailCrop.sourcePixelSize(faceBox: huge, target: 320, cap: 2048) == 320)
    }
}

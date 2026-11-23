import CoreGraphics
import ImageIO
import Testing

@testable import HaloUI

// Pure geometry: synthetic boxes only.

private let tolerance: CGFloat = 1e-6

private func close(_ a: CGRect?, _ b: CGRect, _ eps: CGFloat = tolerance) -> Bool {
    guard let a else { return false }
    return abs(a.minX - b.minX) < eps && abs(a.minY - b.minY) < eps && abs(a.width - b.width) < eps
        && abs(a.height - b.height) < eps
}

/// Portrait iPhone/iPad view sizes (points).
private let portraitViews: [CGSize] = [
    CGSize(width: 375, height: 667),  // 16:9-ish (SE)
    CGSize(width: 390, height: 844),  // ~19.5:9
    CGSize(width: 430, height: 932),
    CGSize(width: 768, height: 1024),  // 4:3
]

/// Raw sensor-orientation buffers (landscape), tagged `.right` like `CameraSource`.
private let buffers: [(name: String, size: CGSize)] = [
    ("16:9", CGSize(width: 1280, height: 720)),
    ("4:3", CGSize(width: 640, height: 480)),
    ("4:3 hi", CGSize(width: 1920, height: 1440)),
]

@Suite struct LensOverlayGeometryTests {
    @Test func uprightSizeSwapsOnlyForQuarterTurns() {
        let size = CGSize(width: 1280, height: 720)
        for o in [CGImagePropertyOrientation.left, .leftMirrored, .right, .rightMirrored] {
            #expect(
                LensOverlayGeometry.uprightSize(bufferSize: size, orientation: o)
                    == CGSize(width: 720, height: 1280))
        }
        for o in [CGImagePropertyOrientation.up, .upMirrored, .down, .downMirrored] {
            #expect(LensOverlayGeometry.uprightSize(bufferSize: size, orientation: o) == size)
        }
    }

    /// Hand-computed: 1280x720 `.right` -> upright 720x1280 into 390x844.
    /// scale = max(390/720, 844/1280) = 0.659375 -> drawn 474.75 x 844, x offset -42.375.
    @Test func sixteenByNineInIPhonePortraitHandComputed() {
        let rect = LensOverlayGeometry.viewRect(
            forUpright: CGRect(x: 0.5, y: 0.25, width: 0.2, height: 0.1),
            bufferSize: CGSize(width: 1280, height: 720), orientation: .right,
            viewSize: CGSize(width: 390, height: 844), videoGravity: .resizeAspectFill)
        #expect(close(rect, CGRect(x: 237.375 - 42.375, y: 211, width: 94.95, height: 84.4)))
    }

    /// Hand-computed: 640x480 `.right` -> upright 480x640 into 390x844.
    /// scale = max(390/480, 844/640) = 1.31875 -> drawn 633 x 844, x offset -121.5.
    @Test func fourByThreeInIPhonePortraitHandComputed() {
        let rect = LensOverlayGeometry.viewRect(
            forUpright: CGRect(x: 0.1, y: 0.5, width: 0.25, height: 0.2),
            bufferSize: CGSize(width: 640, height: 480), orientation: .right,
            viewSize: CGSize(width: 390, height: 844), videoGravity: .resizeAspectFill)
        #expect(close(rect, CGRect(x: 63.3 - 121.5, y: 422, width: 158.25, height: 168.8)))
    }

    /// Hand-computed: 16:9 upright 720x1280 into a 4:3 iPad portrait view 768x1024.
    /// scale = max(768/720, 1024/1280) = 1.0666.. -> drawn 768 x 1365.33, y offset -170.67 (crops
    /// top and bottom instead of the sides).
    @Test func sixteenByNineInIPadPortraitCropsVertically() {
        let rect = LensOverlayGeometry.viewRect(
            forUpright: CGRect(x: 0, y: 0, width: 1, height: 1), bufferSize: CGSize(width: 1280, height: 720),
            orientation: .right, viewSize: CGSize(width: 768, height: 1024))
        let drawnHeight = 1280 * (768.0 / 720.0)
        #expect(close(rect, CGRect(x: 0, y: (1024 - drawnHeight) / 2, width: 768, height: drawnHeight), 1e-4))
    }

    @Test(arguments: buffers.map(\.size), portraitViews)
    func aspectFillCoversViewCentredAndPreservesAspect(buffer: CGSize, view: CGSize) throws {
        let full = try #require(
            LensOverlayGeometry.viewRect(
                forUpright: CGRect(x: 0, y: 0, width: 1, height: 1), bufferSize: buffer, orientation: .right,
                viewSize: view, videoGravity: .resizeAspectFill))
        // Covers the view, cropping only one axis, centred.
        #expect(full.minX <= tolerance && full.minY <= tolerance)
        #expect(full.maxX >= view.width - tolerance && full.maxY >= view.height - tolerance)
        #expect(abs(full.midX - view.width / 2) < 1e-6 && abs(full.midY - view.height / 2) < 1e-6)
        #expect(abs(full.width - view.width) < 1e-6 || abs(full.height - view.height) < 1e-6)
        // Upright aspect ratio preserved (buffer is landscape, upright is portrait).
        #expect(abs(full.width / full.height - buffer.height / buffer.width) < 1e-9)

        // A face at the frame centre lands at the view centre, at the right scale.
        let face = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
        let mapped = try #require(
            LensOverlayGeometry.viewRect(
                forUpright: face, bufferSize: buffer, orientation: .right, viewSize: view))
        #expect(abs(mapped.midX - view.width / 2) < 1e-6 && abs(mapped.midY - view.height / 2) < 1e-6)
        #expect(abs(mapped.width - 0.1 * full.width) < 1e-6 && abs(mapped.height - 0.1 * full.height) < 1e-6)
    }

    /// The bug the geometry exists to prevent: naive `x * viewWidth` mapping puts a face near the
    /// frame edge on a different face's position. Two faces side by side must map to the
    /// cropped-preview positions, and their order and spacing must survive.
    @Test(arguments: portraitViews)
    func edgeFacesAreNotNaivelyScaled(view: CGSize) throws {
        let buffer = CGSize(width: 1280, height: 720)
        let left = CGRect(x: 0.15, y: 0.4, width: 0.2, height: 0.12)
        let right = CGRect(x: 0.65, y: 0.4, width: 0.2, height: 0.12)
        let l = try #require(
            LensOverlayGeometry.viewRect(
                forUpright: left, bufferSize: buffer, orientation: .right, viewSize: view))
        let r = try #require(
            LensOverlayGeometry.viewRect(
                forUpright: right, bufferSize: buffer, orientation: .right, viewSize: view))
        let drawn = try #require(
            LensOverlayGeometry.displayedFrameRect(
                bufferSize: buffer, orientation: .right, viewSize: view, videoGravity: .resizeAspectFill))
        #expect(abs(l.minX - (drawn.minX + 0.15 * drawn.width)) < 1e-6)
        #expect(abs(r.minX - (drawn.minX + 0.65 * drawn.width)) < 1e-6)
        #expect(l.maxX < r.minX)
        if drawn.width > view.width + 1 {
            // Cropped horizontally: the naive mapping is measurably wrong.
            #expect(abs(l.minX - 0.15 * view.width) > 1)
        }
    }

    @Test func faceInCroppedMarginMapsOffScreen() throws {
        // 16:9 upright portrait in a 390x844 view crops 42.375 pt per side.
        let rect = try #require(
            LensOverlayGeometry.viewRect(
                forUpright: CGRect(x: 0.0, y: 0.5, width: 0.05, height: 0.05),
                bufferSize: CGSize(width: 1280, height: 720), orientation: .right,
                viewSize: CGSize(width: 390, height: 844)))
        #expect(rect.maxX < 0)
    }

    @Test func uprightBufferWithoutRotation() {
        // Already-upright 4:3 landscape buffer (`.up`) in a portrait view: heavy side crop.
        let rect = LensOverlayGeometry.viewRect(
            forUpright: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
            bufferSize: CGSize(width: 640, height: 480),
            orientation: .up, viewSize: CGSize(width: 390, height: 844))
        // scale = 844/480; drawn width = 1125.333, x offset = -367.667
        let drawnWidth = 640 * (844.0 / 480.0)
        #expect(
            close(
                rect,
                CGRect(x: (390 - drawnWidth) / 2 + drawnWidth / 2, y: 0, width: drawnWidth / 2, height: 844),
                1e-4))
    }

    @Test func aspectFitLetterboxesAndResizeStretches() {
        let buffer = CGSize(width: 1280, height: 720)
        let view = CGSize(width: 390, height: 844)
        // Fit: scale = min(390/720, 844/1280) = 0.541666 -> 390 x 693.33, y offset 75.33.
        let fit = LensOverlayGeometry.viewRect(
            forUpright: CGRect(x: 0, y: 0, width: 1, height: 1), bufferSize: buffer, orientation: .right,
            viewSize: view, videoGravity: .resizeAspect)
        let h = 1280 * (390.0 / 720.0)
        #expect(close(fit, CGRect(x: 0, y: (844 - h) / 2, width: 390, height: h), 1e-4))
        let stretched = LensOverlayGeometry.viewRect(
            forUpright: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), bufferSize: buffer,
            orientation: .right,
            viewSize: view, videoGravity: .resize)
        #expect(close(stretched, CGRect(x: 195, y: 422, width: 195, height: 422)))
    }

    @Test func degenerateInputsReturnNil() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let buffer = CGSize(width: 1280, height: 720)
        let view = CGSize(width: 390, height: 844)
        #expect(
            LensOverlayGeometry.viewRect(
                forUpright: box, bufferSize: .zero, orientation: .right, viewSize: view) == nil)
        #expect(
            LensOverlayGeometry.viewRect(
                forUpright: box, bufferSize: buffer, orientation: .right, viewSize: .zero) == nil)
        #expect(
            LensOverlayGeometry.viewRect(
                forUpright: box, bufferSize: CGSize(width: CGFloat.nan, height: 720), orientation: .right,
                viewSize: view) == nil)
        #expect(
            LensOverlayGeometry.viewRect(
                forUpright: .null, bufferSize: buffer, orientation: .right, viewSize: view) == nil)
        #expect(
            LensOverlayGeometry.viewRect(
                forUpright: CGRect(x: CGFloat.infinity, y: 0, width: 0.1, height: 0.1), bufferSize: buffer,
                orientation: .right, viewSize: view) == nil)
    }
}

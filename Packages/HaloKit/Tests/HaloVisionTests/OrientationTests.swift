import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import HaloCore
import ImageIO
import Testing
import Vision

@testable import HaloVision

let allOrientations: [CGImagePropertyOrientation] = [
    .up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left,
]

private let tolerance: CGFloat = 1e-3

private func close(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = tolerance) -> Bool {
    abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
}

private func close(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = tolerance) -> Bool {
    abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol && abs(a.width - b.width) < tol
        && abs(a.height - b.height) < tol
}

/// Independent reference: Core Image's own orientation transform (bottom-left CI space), wrapped
/// to map a normalized top-left RAW point to a normalized top-left UPRIGHT point.
private func coreImageReference(rawSize: CGSize, orientation: CGImagePropertyOrientation) -> (CGPoint) ->
    CGPoint
{
    let raw = CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: rawSize))
    let transform = raw.orientationTransform(for: orientation)
    let upright = raw.oriented(orientation).extent
    return { p in
        let q = CGPoint(x: p.x * rawSize.width, y: (1 - p.y) * rawSize.height).applying(transform)
        return CGPoint(x: (q.x - upright.minX) / upright.width, y: (upright.maxY - q.y) / upright.height)
    }
}

/// A synthetic upright face: box, five landmarks rolled 15° clockwise, in a 160x120 image.
enum SyntheticFace {
    static let uprightSize = CGSize(width: 160, height: 120)
    static let rollDegrees = 15.0

    /// Landmarks in upright pixels: the template, scaled, rolled clockwise, and placed off-centre.
    static let pixelLandmarks: [CGPoint] = {
        let place = SimilarityTransform(
            scale: 0.6, rotation: rollDegrees * .pi / 180, translation: CGPoint(x: 70, y: 20))
        return FaceAligner.alignmentTarget.map(place.apply)
    }()

    static let observation = FaceObservation(
        boundingBox: CGRect(x: 0.43, y: 0.15, width: 0.45, height: 0.6),
        roll: rollDegrees * .pi / 180, yaw: 0.2, quality: 0.8,
        landmarks: pixelLandmarks.map { CGPoint(x: $0.x / uprightSize.width, y: $0.y / uprightSize.height) },
        timestamp: 3)

    /// Marker colours drawn at each landmark (RGB, 0...1).
    static let markerColors: [(CGFloat, CGFloat, CGFloat)] = [
        (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (1, 0, 1),
    ]

    /// Upright image: dark grey background, a coloured dot at each landmark.
    static func uprightImage() throws -> CGImage {
        try FrameFixtures.draw(width: Int(uprightSize.width), height: Int(uprightSize.height)) { context in
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
            context.fill(CGRect(origin: .zero, size: uprightSize))
            for (point, color) in zip(pixelLandmarks, markerColors) {
                context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
                // CG user space is bottom-left origin.
                let y = uprightSize.height - point.y
                context.fillEllipse(in: CGRect(x: point.x - 4, y: y - 4, width: 8, height: 8))
            }
        }
    }
}

enum FrameFixtures {
    struct Failure: Error {}

    static let context = CIContext(options: [.cacheIntermediates: false])

    static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) throws -> CGImage {
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure() }
        body(context)
        guard let image = context.makeImage() else { throw Failure() }
        return image
    }

    /// The orientation that undoes `orientation` (only `.left` and `.right` are not involutions).
    static func inverse(_ orientation: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .left: .right
        case .right: .left
        default: orientation
        }
    }

    /// The stored image that displays as `upright` under `orientation`, built with Core Image.
    static func rawImage(from upright: CGImage, orientation: CGImagePropertyOrientation) throws -> CGImage {
        let rotated = CIImage(cgImage: upright).oriented(inverse(orientation))
        let extent = rotated.extent
        guard let raw = context.createCGImage(rotated, from: extent) else { throw Failure() }
        return raw
    }

    /// A 32BGRA camera-style pixel buffer holding `image`'s pixels.
    static func bgraBuffer(from image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw Failure() }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw Failure() }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    /// A bi-planar 420 full-range buffer (the camera's native format), uniformly `luma`.
    static func yuvBuffer(width: Int, height: Int, luma: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw Failure() }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for (plane, value) in [(0, luma), (1, UInt8(128))] {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { throw Failure() }
            memset(
                base, Int32(value),
                CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                    * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        return buffer
    }
}

@Suite struct OrientationGeometryTests {
    @Test(arguments: allOrientations)
    func normalizedMapMatchesCoreImage(orientation: CGImagePropertyOrientation) {
        let rawSize = CGSize(width: 160, height: 90)
        let reference = coreImageReference(rawSize: rawSize, orientation: orientation)
        let probes = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 0.13, y: 0.71),
            CGPoint(x: 0.9, y: 0.25),
        ]
        for p in probes {
            let ours = OrientationGeometry.uprightPoint(fromRaw: p, orientation: orientation)
            #expect(close(ours, reference(p)), "\(orientation.rawValue) \(p): \(ours) vs \(reference(p))")
            #expect(close(OrientationGeometry.rawPoint(fromUpright: ours, orientation: orientation), p))
        }
    }

    @Test(arguments: allOrientations)
    func pixelMapMatchesCoreImageAndSwapsSize(orientation: CGImagePropertyOrientation) {
        let rawSize = CGSize(width: 160, height: 90)
        let upright = OrientationGeometry.uprightSize(rawSize: rawSize, orientation: orientation)
        let ciUpright = CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: rawSize))
            .oriented(orientation).extent.size
        #expect(upright == ciUpright)
        #expect(OrientationGeometry.swapsAxes(orientation) == (upright.width == 90))

        let reference = coreImageReference(rawSize: rawSize, orientation: orientation)
        let toUpright = OrientationGeometry.uprightPixelTransform(rawSize: rawSize, orientation: orientation)
        let toRaw = OrientationGeometry.rawPixelTransform(fromUprightIn: rawSize, orientation: orientation)
        let rawPixel = CGPoint(x: 37.5, y: 12.25)
        let expected = reference(CGPoint(x: rawPixel.x / rawSize.width, y: rawPixel.y / rawSize.height))
        let got = rawPixel.applying(toUpright)
        #expect(close(CGPoint(x: got.x / upright.width, y: got.y / upright.height), expected))
        #expect(close(got.applying(toRaw), rawPixel))
        // Orientation maps are isometries in pixel space.
        #expect(abs(abs(toUpright.a * toUpright.d - toUpright.b * toUpright.c) - 1) < 1e-9)
    }

    @Test func mirroredOrientationsAreExactlyTheReflections() {
        let mirrored = allOrientations.filter(OrientationGeometry.isMirrored)
        #expect(Set(mirrored.map(\.rawValue)) == [2, 4, 5, 7])
        for o in allOrientations {
            let t = OrientationGeometry.normalizedUprightTransform(o)
            #expect((t.a * t.d - t.b * t.c < 0) == OrientationGeometry.isMirrored(o))
        }
    }

    /// The load-bearing invariant: a face supplied as a rotated raw image + orientation has the same
    /// upright geometry as the same face supplied upright.
    @Test(arguments: allOrientations)
    func rawFaceGeometryMapsBackToUpright(orientation: CGImagePropertyOrientation) throws {
        let face = SyntheticFace.observation
        let rawSize = OrientationGeometry.uprightSize(
            rawSize: SyntheticFace.uprightSize, orientation: orientation)
        // Express the face in the raw image with the Core Image reference (inverse direction).
        let reference = coreImageReference(rawSize: rawSize, orientation: orientation)
        func rawPoint(_ upright: CGPoint) -> CGPoint {
            // Invert the reference by exhaustive structure: it is affine, so solve from 3 probes.
            let o = reference(.zero)
            let ex = reference(CGPoint(x: 1, y: 0))
            let ey = reference(CGPoint(x: 0, y: 1))
            let forward = CGAffineTransform(
                a: ex.x - o.x, b: ex.y - o.y, c: ey.x - o.x, d: ey.y - o.y, tx: o.x, ty: o.y)
            return upright.applying(forward.inverted())
        }
        let rawCorners = [
            CGPoint(x: face.boundingBox.minX, y: face.boundingBox.minY),
            CGPoint(x: face.boundingBox.maxX, y: face.boundingBox.maxY),
        ].map(rawPoint)
        let rawBox = CGRect(
            x: min(rawCorners[0].x, rawCorners[1].x), y: min(rawCorners[0].y, rawCorners[1].y),
            width: abs(rawCorners[0].x - rawCorners[1].x), height: abs(rawCorners[0].y - rawCorners[1].y))
        let rawFace = FaceObservation(
            boundingBox: rawBox, roll: nil, yaw: face.yaw, quality: face.quality,
            landmarks: face.landmarks.map(rawPoint), timestamp: face.timestamp)

        let back = OrientationGeometry.uprightObservation(rawFace, rawSize: rawSize, orientation: orientation)
        #expect(close(back.boundingBox, face.boundingBox), "\(back.boundingBox) vs \(face.boundingBox)")
        #expect(back.landmarks.count == FivePointLandmarks.count)
        for (got, want) in zip(back.landmarks, face.landmarks) {
            #expect(close(got, want), "\(orientation.rawValue): \(got) vs \(want)")
        }
        let roll = try #require(back.roll)
        #expect(abs(roll - (SyntheticFace.rollDegrees * .pi / 180 + templateEyeLineAngle)) < 1e-3)
        #expect(back.timestamp == face.timestamp && back.quality == face.quality)
        // Also via the rect helpers.
        #expect(
            close(
                OrientationGeometry.uprightRect(fromRaw: rawBox, orientation: orientation), face.boundingBox))
        #expect(
            close(
                OrientationGeometry.rawRect(fromUpright: face.boundingBox, orientation: orientation), rawBox))
    }

    @Test(arguments: allOrientations)
    func rollWithoutLandmarksRotatesWithTheImage(orientation: CGImagePropertyOrientation) throws {
        // Round trip: upright -> raw (via the inverse orientation's geometry) -> upright.
        let upright = FaceObservation(
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), roll: 0.3, yaw: 0.4, quality: 1,
            timestamp: 0)
        let size = CGSize(width: 100, height: 100)
        // A raw face whose upright roll should be 0.3: derive raw roll by mapping the eye-line.
        let toRaw = OrientationGeometry.rawPixelTransform(fromUprightIn: size, orientation: orientation)
        let d = CGPoint(x: cos(0.3), y: sin(0.3))
        var rawD = CGPoint(x: toRaw.a * d.x + toRaw.c * d.y, y: toRaw.b * d.x + toRaw.d * d.y)
        let mirrored = OrientationGeometry.isMirrored(orientation)
        if mirrored { rawD = CGPoint(x: -rawD.x, y: -rawD.y) }
        let raw = FaceObservation(
            boundingBox: OrientationGeometry.rawRect(
                fromUpright: upright.boundingBox, orientation: orientation),
            roll: atan2(Double(rawD.y), Double(rawD.x)), yaw: mirrored ? -0.4 : 0.4, quality: 1, timestamp: 0)
        let back = OrientationGeometry.uprightObservation(raw, rawSize: size, orientation: orientation)
        #expect(abs(try #require(back.roll) - 0.3) < 1e-9)
        #expect(abs(try #require(back.yaw) - 0.4) < 1e-12)
        #expect(close(back.boundingBox, upright.boundingBox))
    }
}

@Suite struct OrientedRenderingTests {
    /// Every orientation of the same stored pixels must produce the same aligned crop as the
    /// upright image, and the landmark markers must land on the ArcFace template.
    @Test(arguments: allOrientations)
    func pixelBufferCropMatchesUprightCrop(orientation: CGImagePropertyOrientation) throws {
        let upright = try SyntheticFace.uprightImage()
        let raw = try FrameFixtures.rawImage(from: upright, orientation: orientation)
        #expect(
            CGSize(width: raw.width, height: raw.height)
                == OrientationGeometry.uprightSize(
                    rawSize: SyntheticFace.uprightSize, orientation: orientation))
        let buffer = try FrameFixtures.bgraBuffer(from: raw)
        let aligner = FaceAligner()
        let face = SyntheticFace.observation

        let reference = try aligner.alignedFace(face, in: upright)
        let fromBuffer = try aligner.alignedFace(
            face, in: CIImage(cvPixelBuffer: buffer), orientation: orientation)
        let fromStoredImage = try aligner.alignedFace(
            face, in: CIImage(cgImage: raw), orientation: orientation)

        for crop in [fromBuffer, fromStoredImage] {
            var total = 0
            var worst = 0
            for i in stride(from: 0, to: crop.rgbx.count, by: 4) {
                for c in 0..<3 {
                    let diff = abs(Int(crop.rgbx[i + c]) - Int(reference.rgbx[i + c]))
                    total += diff
                    worst = max(worst, diff)
                }
            }
            let mean = Double(total) / Double(crop.width * crop.height * 3)
            #expect(mean < 1.5, "orientation \(orientation.rawValue): mean diff \(mean)")
            #expect(worst < 48, "orientation \(orientation.rawValue): worst diff \(worst)")

            // Each marker sits on its template point in the crop.
            for (target, color) in zip(FaceAligner.alignmentTarget, SyntheticFace.markerColors) {
                let px = crop.pixel(x: Int(target.x), y: Int(target.y))
                let got = [px.r, px.g, px.b].map { $0 > 160 }
                let want = [color.0, color.1, color.2].map { $0 > 0.5 }
                #expect(got == want, "orientation \(orientation.rawValue) marker \(color): \(px)")
            }
        }
    }

    @Test func yuvCameraBufferRendersThroughCoreImage() throws {
        let buffer = try FrameFixtures.yuvBuffer(width: 64, height: 48, luma: 200)
        let crop = try FaceAligner().render(
            CIImage(cvPixelBuffer: buffer), orientation: .right, transform: .identity)
        // Inside the 48x64 upright frame: light grey. Outside it: black.
        let inside = crop.pixel(x: 20, y: 30)
        #expect(inside.r > 150 && abs(Int(inside.r) - Int(inside.b)) < 12)
        let outside = crop.pixel(x: 100, y: 100)
        #expect(outside.r == 0 && outside.g == 0 && outside.b == 0)
    }

    @Test func emptyOrInfiniteSourceThrows() {
        #expect(throws: HaloVisionError.preprocessingFailed) {
            try FaceAligner().render(CIImage(color: .red), orientation: .up, transform: .identity)
        }
        #expect(throws: HaloVisionError.preprocessingFailed) {
            try FaceAligner().render(CIImage.empty(), orientation: .up, transform: .identity)
        }
    }
}

@Suite struct VisionOrientationContractTests {
    /// Vision's own geometry for a stored buffer + orientation equals its geometry for the upright
    /// image. The detector relies on exactly this (it hands `frame.orientation` to Vision and
    /// converts nothing itself). Rectangles stand in for faces, which Vision won't find in
    /// synthetic images.
    @Test(arguments: allOrientations)
    func rectangleGeometryIsUpright(orientation: CGImagePropertyOrientation) async throws {
        let width = 256
        let height = 192
        let target = CGRect(x: 40, y: 30, width: 120, height: 80)  // top-left pixels
        let upright = try FrameFixtures.draw(width: width, height: height) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(
                CGRect(
                    x: target.minX, y: CGFloat(height) - target.maxY, width: target.width,
                    height: target.height))
        }
        let raw = try FrameFixtures.rawImage(from: upright, orientation: orientation)
        let buffer = try FrameFixtures.bgraBuffer(from: raw)

        let fromUpright = try #require(try await DetectRectanglesRequest().perform(on: upright).first)
        let fromBuffer = try #require(
            try await DetectRectanglesRequest().perform(on: buffer, orientation: orientation).first)
        let a = VisionGeometry.topLeftRect(fromVisionRect: fromUpright.boundingBox.cgRect)
        let b = VisionGeometry.topLeftRect(fromVisionRect: fromBuffer.boundingBox.cgRect)
        let expected = CGRect(
            x: target.minX / CGFloat(width), y: target.minY / CGFloat(height),
            width: target.width / CGFloat(width), height: target.height / CGFloat(height))
        #expect(close(a, expected, 0.01), "upright \(a) vs \(expected)")
        #expect(close(b, a), "orientation \(orientation.rawValue): \(b) vs \(a)")
    }
}

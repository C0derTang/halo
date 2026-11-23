import CoreGraphics
import Foundation
import HaloCore
import Testing

@testable import HaloVision

private let tolerance = 1e-4

private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < tolerance }

private func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
    close(Double(a.x), Double(b.x)) && close(Double(a.y), Double(b.y))
}

@Suite struct SimilarityEstimationTests {
    private let template = FaceAligner.arcFaceTemplate

    @Test func templateLandmarksGiveIdentity() throws {
        let t = try #require(SimilarityTransform.estimate(from: template, to: template))
        #expect(close(t.a, 1))
        #expect(close(t.b, 0))
        #expect(close(t.tx, 0))
        #expect(close(t.ty, 0))
    }

    @Test(arguments: [
        (2.0, Double.pi / 6, CGPoint(x: 40, y: -12)),
        (0.37, -1.2, CGPoint(x: 300.5, y: 812.25)),
        (5.5, 3.0, CGPoint(x: -20, y: 7)),
    ])
    func rotatedScaledLandmarksGiveExactInverse(scale: Double, rotation: Double, translation: CGPoint)
        throws
    {
        // Source face = T(template). Aligning it must apply T⁻¹ = (1/s)·R(−θ)·(x − t).
        let forward = SimilarityTransform(scale: scale, rotation: rotation, translation: translation)
        let source = template.map(forward.apply)
        let t = try #require(SimilarityTransform.estimate(from: source, to: template))

        let inverseA = cos(-rotation) / scale
        let inverseB = sin(-rotation) / scale
        let tx = Double(translation.x)
        let ty = Double(translation.y)
        #expect(close(t.a, inverseA))
        #expect(close(t.b, inverseB))
        #expect(close(t.tx, -(inverseA * tx - inverseB * ty)))
        #expect(close(t.ty, -(inverseB * tx + inverseA * ty)))
        #expect(close(t.scale, 1 / scale))
        for (p, q) in zip(source, template) {
            #expect(close(t.apply(p), q))
        }
    }

    @Test func affineMatchesApply() {
        let t = SimilarityTransform(scale: 1.7, rotation: 0.4, translation: CGPoint(x: 3, y: -9))
        let p = CGPoint(x: 12.5, y: -4)
        let viaAffine = p.applying(t.affine)
        #expect(close(viaAffine, t.apply(p)))
    }

    @Test func degenerateInputsReturnNil() {
        let same = Array(repeating: CGPoint(x: 5, y: 5), count: 5)
        #expect(SimilarityTransform.estimate(from: same, to: template) == nil)
        #expect(SimilarityTransform.estimate(from: Array(template.prefix(4)), to: template) == nil)
        #expect(SimilarityTransform.estimate(from: [], to: []) == nil)
    }
}

@Suite struct FaceAlignerTests {
    @Test func landmarksDriveTheTransform() throws {
        // Landmarks are normalized; in a 224x224 image the template points scaled by 2 map onto the
        // template with scale 1/2, plus the +0.5 px OpenCV pixel-centre shift.
        let size = CGSize(width: 224, height: 224)
        let landmarks = FaceAligner.arcFaceTemplate.map { CGPoint(x: $0.x * 2 / 224, y: $0.y * 2 / 224) }
        let face = FaceObservation(
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), quality: 1, landmarks: landmarks,
            timestamp: 0)
        let t = FaceAligner().transform(for: face, imageSize: size)
        #expect(close(t.scale, 0.5))
        #expect(close(t.rotation, 0))
        #expect(close(t.tx, 0.5))
        #expect(close(t.ty, 0.5))
    }

    @Test func alignmentTargetIsTemplateShiftedHalfAPixel() {
        #expect(FaceAligner.openCVPixelCentreOffset == 0.5)
        for (target, template) in zip(FaceAligner.alignmentTarget, FaceAligner.arcFaceTemplate) {
            #expect(close(target, CGPoint(x: template.x + 0.5, y: template.y + 0.5)))
        }
    }

    /// InsightFace parity, sample for sample: `cv2.warpAffine(img, M, (112, 112))` with
    /// `M = estimate(landmarks_cv, arcface_dst)` fills crop pixel j from source index `M⁻¹(j)`
    /// (OpenCV pixel i's centre is at i). We fill crop pixel j from continuous point `T⁻¹(j + 0.5)`,
    /// which is OpenCV index `T⁻¹(j + 0.5) − 0.5`. They must coincide.
    @Test(arguments: [
        (1.8, 0.35, CGPoint(x: 140, y: 95)),
        (0.7, -0.2, CGPoint(x: 31.25, y: 12.5)),
        (3.1, 2.6, CGPoint(x: 400, y: 380)),
    ])
    func samplingMatchesOpenCVWarpAffine(scale: Double, rotation: Double, translation: CGPoint) throws {
        let size = CGSize(width: 640, height: 480)
        let place = SimilarityTransform(scale: scale, rotation: rotation, translation: translation)
        // A slightly asymmetric face so the fit is least-squares, not exact.
        let continuous = FaceAligner.arcFaceTemplate.enumerated().map { i, p in
            place.apply(CGPoint(x: p.x + CGFloat(i % 2) * 0.7, y: p.y - CGFloat(i % 3) * 0.4))
        }
        let face = FaceObservation(
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), quality: 1,
            landmarks: continuous.map { CGPoint(x: $0.x / size.width, y: $0.y / size.height) }, timestamp: 0)
        let ours = FaceAligner().transform(for: face, imageSize: size)

        let openCVLandmarks = continuous.map { CGPoint(x: $0.x - 0.5, y: $0.y - 0.5) }
        let m = try #require(
            SimilarityTransform.estimate(from: openCVLandmarks, to: FaceAligner.arcFaceTemplate))

        for j in [CGPoint(x: 0, y: 0), CGPoint(x: 55, y: 71), CGPoint(x: 111, y: 111), CGPoint(x: 7, y: 100)]
        {
            let viaOpenCV = inverse(m).apply(j)
            let viaOurs = inverse(ours).apply(CGPoint(x: j.x + 0.5, y: j.y + 0.5))
            #expect(close(CGPoint(x: viaOurs.x - 0.5, y: viaOurs.y - 0.5), viaOpenCV), "crop pixel \(j)")
        }
    }

    private func inverse(_ t: SimilarityTransform) -> SimilarityTransform {
        let n = t.a * t.a + t.b * t.b
        let a = t.a / n
        let b = -t.b / n
        return SimilarityTransform(a: a, b: b, tx: -(a * t.tx - b * t.ty), ty: -(b * t.tx + a * t.ty))
    }

    @Test func missingLandmarksFallBackToPaddedBox() {
        let aligner = FaceAligner(boxPadding: 0.25)
        let face = FaceObservation(
            boundingBox: CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.2), quality: 0.5, timestamp: 0)
        let size = CGSize(width: 400, height: 400)
        let t = aligner.transform(for: face, imageSize: size)
        // Box is 100x80 px centred at (150, 240); square side 100 * 1.25 = 125.
        #expect(close(t.scale, 112.0 / 125.0))
        #expect(close(t.rotation, 0))
        #expect(close(t.apply(CGPoint(x: 150, y: 240)), CGPoint(x: 56, y: 56)))
        // The whole box lands inside the crop.
        #expect(t.apply(CGPoint(x: 100, y: 200)).x > 0)
        #expect(t.apply(CGPoint(x: 200, y: 280)).x < 112)
    }

    @Test func wrongLandmarkCountFallsBackToBox() {
        let face = FaceObservation(
            boundingBox: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), quality: 1,
            landmarks: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.3, y: 0.1)], timestamp: 0)
        let size = CGSize(width: 100, height: 100)
        let aligner = FaceAligner()
        #expect(
            aligner.transform(for: face, imageSize: size)
                == aligner.boxTransform(for: CGRect(x: 0, y: 0, width: 50, height: 50)))
    }

    @Test func renderPreservesTopLeftOrientation() throws {
        // 112x112 synthetic image: red top-left quadrant, blue bottom-right, black elsewhere.
        let image = try SyntheticImage.quadrants(side: 112)
        let crop = try FaceAligner().render(image, transform: .identity)
        #expect(crop.width == 112 && crop.height == 112)
        #expect(crop.rgbx.count == 112 * 112 * 4)
        let topLeft = crop.pixel(x: 20, y: 20)
        #expect(topLeft.r > 200 && topLeft.g < 30 && topLeft.b < 30)
        let bottomRight = crop.pixel(x: 90, y: 90)
        #expect(bottomRight.b > 200 && bottomRight.r < 30)
        let topRight = crop.pixel(x: 90, y: 20)
        #expect(topRight.r < 30 && topRight.b < 30)
    }

    @Test func renderAppliesTransformInTopLeftSpace() throws {
        // Translating by (+56, 0) moves the red top-left quadrant to the top-right quadrant.
        let image = try SyntheticImage.quadrants(side: 112)
        let shifted = try FaceAligner().render(
            image, transform: SimilarityTransform(a: 1, b: 0, tx: 56, ty: 0))
        let topRight = shifted.pixel(x: 90, y: 20)
        #expect(topRight.r > 200 && topRight.b < 30)
        // Area mapped from outside the source is black.
        let topLeft = shifted.pixel(x: 20, y: 20)
        #expect(topLeft.r < 30 && topLeft.g < 30 && topLeft.b < 30)
    }
}

enum SyntheticImage {
    struct Failure: Error {}

    /// Solid colour image (no faces).
    static func solid(width: Int, height: Int, gray: CGFloat = 0.5) throws -> CGImage {
        try draw(width: width, height: height) { context in
            context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Red top-left quadrant and blue bottom-right quadrant (as displayed, top-left origin).
    static func quadrants(side: Int) throws -> CGImage {
        let half = CGFloat(side) / 2
        return try draw(width: side, height: side) { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            // Core Graphics user space is bottom-left origin: top-left quadrant is y in [half, side].
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: half, width: half, height: half))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: half, y: 0, width: half, height: half))
        }
    }

    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) throws -> CGImage {
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
}

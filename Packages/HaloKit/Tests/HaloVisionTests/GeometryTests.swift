import CoreGraphics
import Foundation
import Testing
import Vision

@testable import HaloVision

@Suite struct VisionCoordinateConversionTests {
    @Test func bottomLeftRectFlipsToTopLeft() {
        // A box hugging the bottom-left corner in Vision space sits at the bottom of a top-left image.
        let vision = CGRect(x: 0.1, y: 0.05, width: 0.3, height: 0.2)
        let topLeft = VisionGeometry.topLeftRect(fromVisionRect: vision)
        #expect(topLeft.minX == 0.1)
        #expect(abs(topLeft.minY - 0.75) < 1e-12)
        #expect(topLeft.width == 0.3)
        #expect(topLeft.height == 0.2)
    }

    @Test func conversionIsAnInvolution() {
        let rect = CGRect(x: 0.2, y: 0.4, width: 0.25, height: 0.35)
        let roundTrip = VisionGeometry.topLeftRect(
            fromVisionRect: VisionGeometry.topLeftRect(fromVisionRect: rect))
        #expect(abs(roundTrip.minY - rect.minY) < 1e-12)
        #expect(roundTrip.size == rect.size)
    }

    @Test func fullImageAndCentredBoxesAreFixedPoints() {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        #expect(VisionGeometry.topLeftRect(fromVisionRect: full) == full)
        let centred = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        #expect(VisionGeometry.topLeftRect(fromVisionRect: centred) == centred)
    }

    @Test func pointFlipsY() {
        let p = VisionGeometry.topLeftPoint(fromVisionPoint: CGPoint(x: 0.3, y: 0.9))
        #expect(p.x == 0.3)
        #expect(abs(p.y - 0.1) < 1e-12)
    }

    @Test(arguments: [
        CGRect(x: 0.1, y: 0.05, width: 0.3, height: 0.2),
        CGRect(x: 0.6, y: 0.7, width: 0.2, height: 0.25),
        CGRect(x: 0, y: 0.9, width: 1, height: 0.1),
    ])
    func agreesWithVisionsOwnUpperLeftConversion(rect: CGRect) {
        let ours = VisionGeometry.topLeftRect(fromVisionRect: rect)
        let vision = NormalizedRect(normalizedRect: rect)
            .toImageCoordinates(CGSize(width: 1, height: 1), origin: .upperLeft)
        #expect(abs(ours.minX - vision.minX) < 1e-9)
        #expect(abs(ours.minY - vision.minY) < 1e-9)
        #expect(abs(ours.width - vision.width) < 1e-9)
        #expect(abs(ours.height - vision.height) < 1e-9)
    }

    @Test func iouOfDisjointAndIdenticalBoxes() {
        let a = CGRect(x: 0, y: 0, width: 0.2, height: 0.2)
        #expect(VisionGeometry.iou(a, a) == 1)
        #expect(VisionGeometry.iou(a, CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)) == 0)
    }
}

/// The ArcFace template's own eye line is not quite level (-0.32°): an unrolled template has this roll.
let templateEyeLineAngle: Double = {
    let t = FaceAligner.arcFaceTemplate
    return atan2(Double(t[1].y - t[0].y), Double(t[1].x - t[0].x))
}()

@Suite struct RollConventionTests {
    @Test func templateEyeLineIsNearlyLevel() {
        #expect(templateEyeLineAngle < 0 && templateEyeLineAngle > -0.006)
    }

    /// Template landmarks (in a square image) rolled by `degrees` clockwise as displayed: in
    /// top-left (y-down) pixels a clockwise turn is a positive rotation.
    private func rolledLandmarks(degrees: Double, imageSize: CGSize) -> [CGPoint] {
        let centre = CGPoint(x: 56, y: 72)
        let rotate = SimilarityTransform(scale: 1, rotation: degrees * .pi / 180, translation: .zero)
        let shift = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        let pixels = FaceAligner.alignmentTarget.map { p -> CGPoint in
            let r = rotate.apply(CGPoint(x: p.x - centre.x, y: p.y - centre.y))
            return CGPoint(x: r.x + shift.x, y: r.y + shift.y)
        }
        // Re-derive template order the way the detector does (image-left eye first).
        let ordered = FivePointLandmarks.canonicalOrder(
            eyes: (pixels[1], pixels[0]), nose: pixels[2], mouthCorners: (pixels[4], pixels[3]))
        return ordered.map { CGPoint(x: $0.x / imageSize.width, y: $0.y / imageSize.height) }
    }

    @Test(arguments: [0.0, 10, 35, 90, -25, -90, 150, -170, 180])
    func clockwiseRollIsPositive(degrees: Double) throws {
        // Non-square image: the roll must be measured in pixels, not normalized units.
        let size = CGSize(width: 400, height: 250)
        let roll = try #require(
            VisionGeometry.roll(
                fromLandmarks: rolledLandmarks(degrees: degrees, imageSize: size), imageSize: size))
        let want = VisionGeometry.normalizedAngle(degrees * .pi / 180 + templateEyeLineAngle)
        // ±π are the same angle.
        let diff = VisionGeometry.normalizedAngle(roll - want)
        #expect(abs(diff) < 1e-9, "rolled \(degrees)°: got \(roll * 180 / .pi)°")
    }

    @Test func rightEyeLowerMeansClockwise() throws {
        // Image-right eye lower on screen (larger y in top-left space) = head tilted clockwise.
        let landmarks = [
            CGPoint(x: 0.3, y: 0.40), CGPoint(x: 0.6, y: 0.50), CGPoint(x: 0.45, y: 0.6),
            CGPoint(x: 0.33, y: 0.75), CGPoint(x: 0.55, y: 0.82),
        ]
        let roll = try #require(
            VisionGeometry.roll(fromLandmarks: landmarks, imageSize: CGSize(width: 1, height: 1)))
        #expect(roll > 0)
    }

    @Test func visionCounterclockwiseRollIsNegated() {
        #expect(VisionGeometry.topLeftRoll(fromVisionRoll: 0.4) == -0.4)
        #expect(VisionGeometry.topLeftRoll(fromVisionRoll: -1.2) == 1.2)
        // Vision's range is [-π, π); ours is (-π, π].
        #expect(VisionGeometry.topLeftRoll(fromVisionRoll: -.pi) == .pi)
    }

    @Test func noRollWithoutFiveDistinctLandmarks() {
        let size = CGSize(width: 10, height: 10)
        #expect(VisionGeometry.roll(fromLandmarks: [], imageSize: size) == nil)
        #expect(VisionGeometry.roll(fromLandmarks: [CGPoint(x: 0.1, y: 0.1)], imageSize: size) == nil)
        #expect(
            VisionGeometry.roll(
                fromLandmarks: Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 5), imageSize: size) == nil)
    }

    @Test func normalizedAngleWrapsIntoHalfOpenRange() {
        #expect(abs(VisionGeometry.normalizedAngle(3 * .pi) - .pi) < 1e-12)
        #expect(abs(VisionGeometry.normalizedAngle(-3 * .pi) - .pi) < 1e-12)
        #expect(abs(VisionGeometry.normalizedAngle(2 * .pi + 0.5) - 0.5) < 1e-12)
        #expect(VisionGeometry.normalizedAngle(-0.5) == -0.5)
    }
}

@Suite struct OneToOneMatchingTests {
    private let a = UUID()
    private let b = UUID()

    @Test func overlappingFacesNeverShareOneLandmarksResult() {
        // Two overlapping faces. L1 overlaps A strongly and B moderately; B's own result L2 overlaps
        // B less than L1 does. Best-match-per-face would give L1 to both.
        let faceA = CGRect(x: 0.20, y: 0.20, width: 0.30, height: 0.30)
        let faceB = CGRect(x: 0.26, y: 0.22, width: 0.30, height: 0.30)
        let l1 = CGRect(x: 0.21, y: 0.20, width: 0.30, height: 0.30)
        let l2 = CGRect(x: 0.32, y: 0.24, width: 0.30, height: 0.30)
        #expect(VisionGeometry.iou(faceB, l1) > VisionGeometry.iou(faceB, l2))
        #expect(VisionGeometry.iou(faceB, l2) >= 0.5)

        let result = VisionGeometry.matchOneToOne(
            faces: [(a, faceA), (b, faceB)], candidates: [(UUID(), l1), (UUID(), l2)])
        #expect(result == [0, 1])
    }

    @Test func assignmentIsGreedyByIoUNotByFaceOrder() {
        // Face 0 overlaps L (IoU ≈ 0.71) but face 1 matches it exactly: L goes to face 1.
        let face0 = CGRect(x: 0.10, y: 0.10, width: 0.40, height: 0.40)
        let face1 = CGRect(x: 0.15, y: 0.12, width: 0.40, height: 0.40)
        let l = CGRect(x: 0.15, y: 0.12, width: 0.40, height: 0.40)
        let result = VisionGeometry.matchOneToOne(faces: [(a, face0), (b, face1)], candidates: [(UUID(), l)])
        #expect(result == [nil, 0])
    }

    @Test func sameUUIDWinsAndIsNotReused() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        let result = VisionGeometry.matchOneToOne(
            faces: [(a, box), (b, box)],
            candidates: [(b, CGRect(x: 0.6, y: 0.6, width: 0.1, height: 0.1)), (UUID(), box)])
        // b matches by identity even with no overlap; a takes the remaining overlapping result.
        #expect(result == [1, 0])
    }

    @Test func lowOverlapStaysUnmatched() {
        let result = VisionGeometry.matchOneToOne(
            faces: [(a, CGRect(x: 0, y: 0, width: 0.2, height: 0.2))],
            candidates: [(UUID(), CGRect(x: 0.15, y: 0.15, width: 0.2, height: 0.2))])
        #expect(result == [nil])
        #expect(VisionGeometry.matchOneToOne(faces: [], candidates: [(UUID(), .zero)]).isEmpty)
    }
}

@Suite struct FivePointLandmarkTests {
    private let template = FaceAligner.arcFaceTemplate

    @Test func uprightFaceKeepsTemplateOrder() {
        let ordered = FivePointLandmarks.canonicalOrder(
            eyes: (template[0], template[1]), nose: template[2], mouthCorners: (template[3], template[4]))
        #expect(ordered == template)
    }

    @Test func swappedLabelsAreReordered() {
        let ordered = FivePointLandmarks.canonicalOrder(
            eyes: (template[1], template[0]), nose: template[2], mouthCorners: (template[4], template[3]))
        #expect(ordered == template)
    }

    @Test func faceRolledPast90DegreesStillOrdersByFaceAxis() {
        // Upside-down face (roll 180°): the template's image-left eye now has the larger x.
        let rotate = SimilarityTransform(scale: 1, rotation: .pi, translation: CGPoint(x: 112, y: 112))
        let rolled = template.map(rotate.apply)
        let ordered = FivePointLandmarks.canonicalOrder(
            eyes: (rolled[1], rolled[0]), nose: rolled[2], mouthCorners: (rolled[3], rolled[4]))
        for (got, want) in zip(ordered, rolled) {
            #expect(abs(got.x - want.x) < 1e-9 && abs(got.y - want.y) < 1e-9)
        }
    }

    @Test func farthestPairFindsMouthCorners() {
        let lips = [
            CGPoint(x: 0.4, y: 0.8), CGPoint(x: 0.5, y: 0.78), CGPoint(x: 0.6, y: 0.8),
            CGPoint(x: 0.5, y: 0.84),
        ]
        let pair = FivePointLandmarks.farthestPair(lips)
        #expect(pair?.0 == lips[0])
        #expect(pair?.1 == lips[2])
        #expect(FivePointLandmarks.farthestPair([CGPoint(x: 0, y: 0)]) == nil)
    }
}

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

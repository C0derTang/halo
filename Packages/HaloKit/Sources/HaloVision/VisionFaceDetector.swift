import CoreGraphics
import Foundation
import HaloCore
import Vision

/// `FaceDetecting` on the Vision Swift API (`DetectFaceRectanglesRequest`,
/// `DetectFaceLandmarksRequest`, `DetectFaceCaptureQualityRequest`).
///
/// Input `CGImage`s are treated as upright. Output geometry is normalized with a top-left origin;
/// `roll` / `yaw` are radians; `landmarks` holds the five ArcFace alignment points in
/// `FivePointLandmarks` order, or is empty when Vision returned no usable landmarks.
/// `quality` is Vision's capture-quality score (0...1), or 0 when it is unavailable.
///
/// Work runs on the concurrent executor, never the main actor, and stays on device.
public struct VisionFaceDetector: FaceDetecting {
    /// Run the landmarks request (needed for alignment).
    public var detectsLandmarks: Bool
    /// Run the capture-quality request.
    public var measuresQuality: Bool

    public init(detectsLandmarks: Bool = true, measuresQuality: Bool = true) {
        self.detectsLandmarks = detectsLandmarks
        self.measuresQuality = measuresQuality
    }

    @concurrent
    public func detectFaces(in image: CGImage, timestamp: TimeInterval) async throws -> [HaloCore
        .FaceObservation]
    {
        let faces = try await DetectFaceRectanglesRequest().perform(on: image)
        guard !faces.isEmpty else { return [] }

        async let landmarked: [Vision.FaceObservation] = {
            guard detectsLandmarks else { return [] }
            var request = DetectFaceLandmarksRequest()
            request.inputFaceObservations = faces
            return try await request.perform(on: image)
        }()
        async let qualified: [Vision.FaceObservation] = {
            guard measuresQuality else { return [] }
            var request = DetectFaceCaptureQualityRequest()
            request.inputFaceObservations = faces
            return try await request.perform(on: image)
        }()
        let withLandmarks = try await landmarked
        let withQuality = try await qualified

        let imageSize = CGSize(width: image.width, height: image.height)
        return faces.map { face in
            let landmarks = Self.counterpart(of: face, in: withLandmarks)?.landmarks
            let quality = Self.counterpart(of: face, in: withQuality)?.captureQuality?.score
            return HaloCore.FaceObservation(
                boundingBox: VisionGeometry.topLeftRect(fromVisionRect: face.boundingBox.cgRect),
                roll: face.roll.converted(to: .radians).value,
                yaw: face.yaw.converted(to: .radians).value,
                quality: quality.map { min(max($0, 0), 1) } ?? 0,
                landmarks: landmarks.map { Self.fivePoints(from: $0, imageSize: imageSize) } ?? [],
                timestamp: timestamp)
        }
    }

    /// The observation for the same face in a follow-up request's results: same UUID when Vision
    /// preserved it, otherwise the best-overlapping box (IoU ≥ 0.5).
    static func counterpart(of face: Vision.FaceObservation, in candidates: [Vision.FaceObservation])
        -> Vision.FaceObservation?
    {
        if let same = candidates.first(where: { $0.uuid == face.uuid }) { return same }
        let box = face.boundingBox.cgRect
        let best = candidates.max {
            VisionGeometry.iou(box, $0.boundingBox.cgRect) < VisionGeometry.iou(box, $1.boundingBox.cgRect)
        }
        guard let best, VisionGeometry.iou(box, best.boundingBox.cgRect) >= 0.5 else { return nil }
        return best
    }

    /// Reduces Vision's 2-D landmark regions to the five alignment points, normalized top-left.
    static func fivePoints(from landmarks: Vision.FaceObservation.Landmarks2D, imageSize: CGSize)
        -> [CGPoint]
    {
        guard imageSize.width > 0, imageSize.height > 0 else { return [] }
        func points(_ region: Vision.FaceObservation.Landmarks2D.Region) -> [CGPoint] {
            region.pointsInImageCoordinates(imageSize, origin: .upperLeft).map {
                CGPoint(x: $0.x / imageSize.width, y: $0.y / imageSize.height)
            }
        }
        func eye(
            pupil: Vision.FaceObservation.Landmarks2D.Region,
            contour: Vision.FaceObservation.Landmarks2D.Region
        )
            -> CGPoint?
        {
            FivePointLandmarks.centroid(points(pupil)) ?? FivePointLandmarks.centroid(points(contour))
        }
        guard
            let eyeA = eye(pupil: landmarks.leftPupil, contour: landmarks.leftEye),
            let eyeB = eye(pupil: landmarks.rightPupil, contour: landmarks.rightEye),
            let mouth = FivePointLandmarks.farthestPair(points(landmarks.outerLips))
        else { return [] }
        let eyeMid = FivePointLandmarks.midpoint(eyeA, eyeB)
        // Nose tip: the end of the nose crest farthest from the eyes; else the nose centroid.
        let crest = points(landmarks.noseCrest)
        let tip =
            crest.max {
                hypot($0.x - eyeMid.x, $0.y - eyeMid.y) < hypot($1.x - eyeMid.x, $1.y - eyeMid.y)
            } ?? FivePointLandmarks.centroid(points(landmarks.nose))
        guard let tip else { return [] }
        return FivePointLandmarks.canonicalOrder(eyes: (eyeA, eyeB), nose: tip, mouthCorners: mouth)
    }
}

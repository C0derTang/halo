import CoreGraphics
import CoreVideo
import Foundation
import HaloCore
import ImageIO
import Vision

/// `FaceDetecting` / `FrameFaceDetecting` on the Vision Swift API (`DetectFaceRectanglesRequest`,
/// `DetectFaceLandmarksRequest`, `DetectFaceCaptureQualityRequest`).
///
/// Output geometry is always in the UPRIGHT image, normalized, top-left origin:
/// - `detectFaces(in: CGImage, timestamp:)` treats the image as upright.
/// - `detectFaces(in: CGImage, orientation:timestamp:)` takes an EXIF-oriented image (PhotoKit),
///   so callers never rotate pixels themselves.
/// - `detectFaces(in: VideoFrame)` runs Vision directly on the camera pixel buffer with
///   `frame.orientation`; no per-frame `CGImage` conversion or rotation copy.
///
/// Vision applies the orientation itself, so its results already live in the upright image.
///
/// Fields:
/// - `landmarks`: the five ArcFace alignment points in `FivePointLandmarks` order, or empty when
///   Vision returned no usable landmarks.
/// - `roll`: radians, `(-π, π]`, upright top-left image, **positive = clockwise as displayed**
///   (`VisionGeometry.roll(fromLandmarks:imageSize:)`). Derived from the landmarks when present,
///   otherwise Vision's counterclockwise-positive roll negated.
/// - `yaw`: Vision's yaw in radians, unchanged (positive = counterclockwise per Vision's docs).
///   Yaw is a rotation about the image's vertical axis, which the bottom-left -> top-left flip
///   does not affect.
/// - `quality`: Vision's capture-quality score (0...1), or 0 when it is unavailable.
///
/// Work runs on the concurrent executor, never the main actor, and stays on device.
public struct VisionFaceDetector: FaceDetecting, FrameFaceDetecting {
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
        try await detectFaces(in: image, orientation: .up, timestamp: timestamp)
    }

    /// Detects faces in a stored image whose display orientation is `orientation` (e.g. the EXIF
    /// orientation of a PhotoKit asset). Geometry is returned in the upright image.
    @concurrent
    public func detectFaces(
        in image: CGImage, orientation: CGImagePropertyOrientation, timestamp: TimeInterval
    ) async throws -> [HaloCore.FaceObservation] {
        let rawSize = CGSize(width: image.width, height: image.height)
        return try await detect(
            with: ImageRequestHandler(image, orientation: orientation),
            uprightSize: OrientationGeometry.uprightSize(rawSize: rawSize, orientation: orientation),
            timestamp: timestamp)
    }

    @concurrent
    public func detectFaces(in frame: VideoFrame) async throws -> [HaloCore.FaceObservation] {
        let buffer = frame.pixelBuffer
        let rawSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        return try await detect(
            with: ImageRequestHandler(buffer, orientation: frame.orientation),
            uprightSize: OrientationGeometry.uprightSize(rawSize: rawSize, orientation: frame.orientation),
            timestamp: frame.timestamp)
    }

    /// Shared body: one request handler per image, so Vision prepares the (oriented) image once for
    /// the rectangles, landmarks and quality requests.
    @concurrent
    private func detect(with handler: ImageRequestHandler, uprightSize: CGSize, timestamp: TimeInterval)
        async throws -> [HaloCore.FaceObservation]
    {
        let faces = try await handler.perform(DetectFaceRectanglesRequest())
        guard !faces.isEmpty else { return [] }

        var landmarksRequest = DetectFaceLandmarksRequest()
        landmarksRequest.inputFaceObservations = faces
        var qualityRequest = DetectFaceCaptureQualityRequest()
        qualityRequest.inputFaceObservations = faces
        let withLandmarks: [Vision.FaceObservation]
        let withQuality: [Vision.FaceObservation]
        switch (detectsLandmarks, measuresQuality) {
        case (true, true):
            (withLandmarks, withQuality) = try await handler.perform(landmarksRequest, qualityRequest)
        case (true, false):
            (withLandmarks, withQuality) = (try await handler.perform(landmarksRequest), [])
        case (false, true):
            (withLandmarks, withQuality) = ([], try await handler.perform(qualityRequest))
        case (false, false):
            (withLandmarks, withQuality) = ([], [])
        }

        let landmarkIndex = Self.counterparts(of: faces, in: withLandmarks)
        let qualityIndex = Self.counterparts(of: faces, in: withQuality)
        return faces.enumerated().map { i, face in
            let landmarks = landmarkIndex[i].flatMap { withLandmarks[$0].landmarks }
            let quality = qualityIndex[i].flatMap { withQuality[$0].captureQuality?.score }
            let points = landmarks.map { Self.fivePoints(from: $0, imageSize: uprightSize) } ?? []
            let roll =
                VisionGeometry.roll(fromLandmarks: points, imageSize: uprightSize)
                ?? VisionGeometry.topLeftRoll(fromVisionRoll: face.roll.converted(to: .radians).value)
            return HaloCore.FaceObservation(
                boundingBox: VisionGeometry.topLeftRect(fromVisionRect: face.boundingBox.cgRect),
                roll: roll,
                yaw: face.yaw.converted(to: .radians).value,
                quality: quality.map { min(max($0, 0), 1) } ?? 0,
                landmarks: points,
                timestamp: timestamp)
        }
    }

    /// For each face, the index of its observation in a follow-up request's results, matched
    /// one-to-one (`VisionGeometry.matchOneToOne`).
    static func counterparts(of faces: [Vision.FaceObservation], in candidates: [Vision.FaceObservation])
        -> [Int?]
    {
        VisionGeometry.matchOneToOne(
            faces: faces.map { ($0.uuid, $0.boundingBox.cgRect) },
            candidates: candidates.map { ($0.uuid, $0.boundingBox.cgRect) })
    }

    /// Reduces Vision's 2-D landmark regions to the five alignment points, normalized top-left in
    /// the upright image of `imageSize`.
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

import CoreGraphics
import Foundation
import HaloCore
import ImageIO
import Testing

@testable import HaloVision

@Suite struct VisionFaceDetectorTests {
    @Test func syntheticImageWithoutFacesReturnsEmpty() async throws {
        let image = try SyntheticImage.solid(width: 320, height: 240)
        let faces = try await VisionFaceDetector().detectFaces(in: image, timestamp: 1.5)
        #expect(faces.isEmpty)
    }

    @Test func patternImageDoesNotCrashAndOutputsNormalizedTopLeftGeometry() async throws {
        let image = try SyntheticImage.quadrants(side: 256)
        let faces = try await VisionFaceDetector(detectsLandmarks: true, measuresQuality: true)
            .detectFaces(in: image, timestamp: 2)
        // Zero faces is the expected outcome; any spurious detection must still be well-formed.
        for face in faces {
            #expect(face.timestamp == 2)
            #expect((0...1).contains(face.quality))
            #expect(face.landmarks.isEmpty || face.landmarks.count == FivePointLandmarks.count)
            #expect(face.boundingBox.width > 0 && face.boundingBox.height > 0)
        }
    }

    @Test func detectorIsUsableThroughTheSeam() async throws {
        let detector: any FaceDetecting = VisionFaceDetector(detectsLandmarks: false, measuresQuality: false)
        let image = try SyntheticImage.solid(width: 64, height: 64, gray: 0.1)
        #expect(try await detector.detectFaces(in: image, timestamp: 0).isEmpty)
    }
}

@Suite struct FrameDetectionTests {
    @Test(arguments: allOrientations)
    func pixelBufferFramesInEveryOrientationRunThroughTheSeam(orientation: CGImagePropertyOrientation)
        async throws
    {
        let raw = try SyntheticImage.quadrants(side: 96)
        let frame = VideoFrame(
            pixelBuffer: try FrameFixtures.bgraBuffer(from: raw), orientation: orientation, timestamp: 4.25)
        let detector: any FrameFaceDetecting = VisionFaceDetector()
        let faces = try await detector.detectFaces(in: frame)
        for face in faces {
            #expect(face.timestamp == 4.25)
            #expect(face.landmarks.isEmpty || face.landmarks.count == FivePointLandmarks.count)
        }
    }

    @Test func cameraNativeYUVBufferIsAccepted() async throws {
        let buffer = try FrameFixtures.yuvBuffer(width: 128, height: 96, luma: 90)
        let faces = try await VisionFaceDetector().detectFaces(
            in: VideoFrame(pixelBuffer: buffer, orientation: .right, timestamp: 0))
        #expect(faces.isEmpty)
    }

    @Test(arguments: allOrientations)
    func orientedStillImageOverload(orientation: CGImagePropertyOrientation) async throws {
        let image = try SyntheticImage.solid(width: 120, height: 80)
        let faces = try await VisionFaceDetector(detectsLandmarks: true, measuresQuality: false)
            .detectFaces(in: image, orientation: orientation, timestamp: 1)
        #expect(faces.isEmpty)
    }
}

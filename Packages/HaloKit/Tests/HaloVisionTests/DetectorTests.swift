import CoreGraphics
import Foundation
import HaloCore
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

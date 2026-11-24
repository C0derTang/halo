import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import HaloCore
import ImageIO
import Synchronization
import Testing

@testable import HaloAppCore

// Synthetic media only: solid-color frames written at test time into a temp directory and deleted
// afterwards. No faces, nothing committed.

/// Writes a tiny solid-color video (`frames` frames at `fps`) and returns its URL.
func makeSyntheticVideo(
    frames: Int = 6, fps: Int32 = 30, width: Int = 64, height: Int = 48,
    transform: CGAffineTransform = .identity
) async throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("halo-video-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("clip.mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
    input.expectsMediaDataInRealTime = false
    input.transform = transform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for index in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        let buffer = try solidBuffer(width: width, height: height, shade: UInt8(40 + index * 30 % 200))
        #expect(
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
    return url
}

private func solidBuffer(width: Int, height: Int, shade: UInt8) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        nil, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw VideoFixtureError() }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, Int32(shade), CVPixelBufferGetBytesPerRow(buffer) * height)
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

private struct VideoFixtureError: Error {}

private func removeVideo(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

/// Records what the camera delivers, from the camera queue.
private final class FrameLog: Sendable {
    struct Entry {
        let width: Int
        let height: Int
        let orientation: CGImagePropertyOrientation
        let timestamp: TimeInterval
        let onMain: Bool
    }
    private let entries = Mutex<[Entry]>([])

    var all: [Entry] { entries.withLock { $0 } }
    var count: Int { entries.withLock { $0.count } }

    var handler: @Sendable (VideoFrame) -> Void {
        { [self] frame in
            let entry = Entry(
                width: CVPixelBufferGetWidth(frame.pixelBuffer),
                height: CVPixelBufferGetHeight(frame.pixelBuffer),
                orientation: frame.orientation, timestamp: frame.timestamp, onMain: Thread.isMainThread)
            entries.withLock { $0.append(entry) }
        }
    }
}

/// Polls `condition` for up to `timeout`; records an issue and throws when it never holds.
private func waitUntil(
    timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline {
            Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
            throw VideoFixtureError()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Suite(.serialized)
struct VideoFileCameraTests {
    @Test func deliversBGRAFramesOffTheMainActor() async throws {
        let url = try await makeSyntheticVideo()
        defer { removeVideo(url) }
        let camera = VideoFileCamera(url: url)
        let log = FrameLog()
        camera.setFrameHandler(log.handler)
        try await camera.start()
        try await waitUntil { log.count >= 3 }
        camera.stop()
        await camera.drainQueue()
        let entries = log.all
        #expect(entries.allSatisfy { !$0.onMain })
        #expect(entries.allSatisfy { $0.width == 64 && $0.height == 48 && $0.orientation == .up })
    }

    @Test @MainActor func startFromTheMainActorStillDeliversOffMain() async throws {
        let url = try await makeSyntheticVideo()
        defer { removeVideo(url) }
        let camera = VideoFileCamera(url: url)
        let log = FrameLog()
        camera.setFrameHandler(log.handler)
        try await camera.start()
        try await waitUntil { log.count >= 2 }
        camera.stop()
        await camera.drainQueue()
        #expect(log.all.allSatisfy { !$0.onMain })
    }

    // Real-clock tests assert only order and counts; pacing and the frame-rate cap are covered
    // with fake clocks in `VideoPlaybackPacerTests`.

    @Test func loopsPastTheEndOfTheFile() async throws {
        // 4 frames at 20 fps: one pass is 0.2 s.
        let url = try await makeSyntheticVideo(frames: 4, fps: 20)
        defer { removeVideo(url) }
        let camera = VideoFileCamera(url: url)
        let log = FrameLog()
        camera.setFrameHandler(log.handler)
        try await camera.start()
        try await waitUntil { log.count >= 10 }  // more frames than the file has: it looped
        camera.stop()
        await camera.drainQueue()
        let times = log.all.map(\.timestamp)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func stopHaltsDeliveryAndRestartPlaysAgain() async throws {
        let url = try await makeSyntheticVideo()
        defer { removeVideo(url) }
        let camera = VideoFileCamera(url: url)
        let log = FrameLog()
        camera.setFrameHandler(log.handler)
        try await camera.start()
        #expect(camera.isRunning)
        try await waitUntil { log.count >= 2 }
        camera.stop()
        #expect(!camera.isRunning)
        await camera.drainQueue()
        let stopped = log.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(log.count == stopped)

        try await camera.start()
        #expect(camera.isRunning)
        try await waitUntil { log.count >= stopped + 3 }
        camera.stop()
    }

    @Test func startWhileRunningIsANoOp() async throws {
        let url = try await makeSyntheticVideo()
        defer { removeVideo(url) }
        let camera = VideoFileCamera(url: url)
        let log = FrameLog()
        camera.setFrameHandler(log.handler)
        try await camera.start()
        try await camera.start()
        // One playback session, not two interleaved ones.
        #expect(camera.generation == 1)
        try await waitUntil { log.count >= 2 }
        camera.stop()
        #expect(camera.generation == 2)
    }

    @Test func removingTheHandlerStopsFramesButNotPlayback() async throws {
        let url = try await makeSyntheticVideo()
        defer { removeVideo(url) }
        let camera = VideoFileCamera(url: url)
        let log = FrameLog()
        camera.setFrameHandler(log.handler)
        try await camera.start()
        try await waitUntil { log.count >= 1 }
        camera.setFrameHandler(nil)
        await camera.drainQueue()
        let count = log.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.count == count)
        #expect(camera.isRunning)
        camera.stop()
    }

    @Test func missingFileThrowsAClearError() async {
        let url = URL(fileURLWithPath: "/nonexistent/halo-demo-\(UUID().uuidString).mov")
        let camera = VideoFileCamera(url: url)
        await #expect(throws: VideoFileCameraError.fileNotFound(url)) { try await camera.start() }
        #expect(!camera.isRunning)
        #expect(VideoFileCameraError.fileNotFound(url).userMessage.contains(url.lastPathComponent))
    }

    @Test func unreadableFileThrowsAClearError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-video-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("garbage.mov")
        try Data(repeating: 0x5A, count: 4096).write(to: url)
        let camera = VideoFileCamera(url: url)
        await #expect {
            try await camera.start()
        } throws: { error in
            guard let error = error as? VideoFileCameraError else { return false }
            return error == .unreadable(url) || error == .noVideoTrack(url)
        }
        #expect(!camera.isRunning)
    }

    @Test func portraitTrackIsTaggedRight() async throws {
        // An iPhone portrait clip: stored landscape, preferredTransform rotates +90 degrees.
        let url = try await makeSyntheticVideo(transform: CGAffineTransform(rotationAngle: .pi / 2))
        defer { removeVideo(url) }
        let camera = VideoFileCamera(url: url)
        let log = FrameLog()
        camera.setFrameHandler(log.handler)
        try await camera.start()
        try await waitUntil { log.count >= 1 }
        camera.stop()
        await camera.drainQueue()
        // Buffer stays as stored; the orientation makes it upright (like the back camera's .right).
        #expect(log.all.allSatisfy { $0.orientation == .right && $0.width == 64 && $0.height == 48 })
    }

    @Test(arguments: [
        (CGAffineTransform.identity, CGImagePropertyOrientation.up),
        (CGAffineTransform(rotationAngle: .pi / 2), .right),
        (CGAffineTransform(rotationAngle: -.pi / 2), .left),
        (CGAffineTransform(rotationAngle: .pi), .down),
        (CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 64, ty: 0), .upMirrored),
        (CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 48), .downMirrored),
        (CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0), .leftMirrored),
        (CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 48, ty: 64), .rightMirrored),
        (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0), .right),
        (CGAffineTransform(scaleX: 2, y: 2), .up),
    ])
    func orientationFromPreferredTransform(transform: CGAffineTransform, expected: CGImagePropertyOrientation)
    {
        #expect(VideoFileCamera.orientation(for: transform) == expected)
    }

    @Test @MainActor func previewGetsDecodedFramesOnMainAndClearsOnStop() async throws {
        let url = try await makeSyntheticVideo(transform: CGAffineTransform(rotationAngle: .pi / 2))
        defer { removeVideo(url) }
        let camera = VideoFileCamera(url: url)
        let seen = Mutex<[LensPreviewImage?]>([])
        camera.preview.observe { image in
            MainActor.assertIsolated()
            seen.withLock { $0.append(image) }
        }
        try await camera.start()
        try await waitUntil { seen.withLock { $0.contains { $0 != nil } } }
        let image = try #require(camera.preview.latest)
        #expect(image.image.width == 64 && image.image.height == 48)
        #expect(image.orientation == .right)
        #expect(image.uprightSize == CGSize(width: 48, height: 64))

        camera.stop()
        await camera.drainQueue()
        try await waitUntil { seen.withLock { $0.last.map { $0 == nil } ?? false } }
        #expect(camera.preview.latest == nil)
        camera.preview.stopObserving()
    }

    @Test func previewIsNotConvertedWithoutAnObserver() async throws {
        let url = try await makeSyntheticVideo()
        defer { removeVideo(url) }
        let camera = VideoFileCamera(url: url)
        let log = FrameLog()
        camera.setFrameHandler(log.handler)
        try await camera.start()
        try await waitUntil { log.count >= 2 }
        #expect(camera.preview.latest == nil)
        camera.stop()
    }
}

@MainActor
struct SimulatorCameraTests {
    @Test func noVariableExplainsHowToPlayADemoVideo() async {
        let camera = SimulatorCamera.make(environment: [:])
        let none = try? #require(camera as? NoCameraSource)
        #expect(none?.message == SimulatorCamera.noCameraMessage)
        await #expect(throws: CameraUnavailableError(userMessage: SimulatorCamera.noCameraMessage)) {
            try await camera.start()
        }
        #expect(SimulatorCamera.make(environment: ["HALO_DEMO_VIDEO": "  "]) is NoCameraSource)
    }

    @Test func variableSelectsTheVideoFileCamera() {
        let camera = SimulatorCamera.make(environment: ["HALO_DEMO_VIDEO": "/tmp/demo clip.mov"])
        let video = camera as? VideoFileCamera
        #expect(video?.url == URL(fileURLWithPath: "/tmp/demo clip.mov"))
    }

    @Test func lensShowsTheSimulatorBannerWithoutAVideo() async {
        let model = LensScreenModel(
            source: LensFakeTrackSource(), camera: NoCameraSource(message: SimulatorCamera.noCameraMessage),
            store: LensFakeStore())
        await model.start()
        #expect(!model.isRunning)
        #expect(model.cameraError == SimulatorCamera.noCameraMessage)
        #expect(
            model.cameraError
                == "Simulator has no camera. Run scripts/sim-run.sh <video> to play a demo video.")
    }

    @Test func lensShowsTheDemoVideoError() async {
        let url = URL(fileURLWithPath: "/nonexistent/halo-demo.mov")
        let model = LensScreenModel(
            source: LensFakeTrackSource(), camera: VideoFileCamera(url: url), store: LensFakeStore())
        await model.start()
        #expect(model.cameraError == "Demo video not found: halo-demo.mov.")
    }
}

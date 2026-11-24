import Foundation
import HaloCore
import Synchronization
import Testing

@testable import HaloAppCore

/// A camera that starts, then fails on demand (like a demo video becoming unreadable).
private final class FailingFakeCamera: CameraFailureReporting {
    private let handler = Mutex<(@Sendable (any Error) -> Void)?>(nil)
    private let stopCount = Mutex(0)

    var stops: Int { stopCount.withLock { $0 } }
    var currentHandler: (@Sendable (any Error) -> Void)? { handler.withLock { $0 } }

    func start() async throws {}
    func stop() { stopCount.withLock { $0 += 1 } }
    func setFrameHandler(_ handler: (@Sendable (VideoFrame) -> Void)?) {}
    func setFailureHandler(_ newValue: (@Sendable (any Error) -> Void)?) {
        handler.withLock { $0 = newValue }
    }
}

/// Calls a failure handler from a background thread, like the camera queue.
private func fail(_ handler: (@Sendable (any Error) -> Void)?, _ error: any Error) async {
    await Task.detached { handler?(error) }.value
}

@MainActor
struct CameraFailureTests {
    @Test func aCameraThatStopsOnItsOwnEndsTheLensSession() async {
        let camera = FailingFakeCamera()
        let model = LensScreenModel(source: LensFakeTrackSource(), camera: camera, store: LensFakeStore())
        await model.start()
        #expect(model.isCapturing)
        await fail(
            camera.currentHandler, VideoFileCameraError.unreadable(URL(fileURLWithPath: "/tmp/clip.mov")))
        for _ in 0..<100 where model.isRunning { await Task.yield() }
        #expect(!model.isRunning)
        #expect(!model.isCapturing)
        #expect(model.cameraError == "The demo video clip.mov could not be read.")
        #expect(camera.stops == 1)
    }

    @Test func aFailureFromAnEarlierSessionIsIgnored() async {
        let camera = FailingFakeCamera()
        let model = LensScreenModel(source: LensFakeTrackSource(), camera: camera, store: LensFakeStore())
        await model.start()
        let stale = camera.currentHandler
        model.stop()
        await model.start()
        await fail(stale, VideoFileCameraError.unreadable(URL(fileURLWithPath: "/tmp/a.mov")))
        for _ in 0..<100 { await Task.yield() }
        #expect(model.isRunning)
        #expect(model.isCapturing)
        #expect(model.cameraError == nil)
    }
}

@Suite(.serialized)
struct VideoFileCameraFailureTests {
    @Test func videoThatBecomesUnreadableMidPlayStopsClearsThePreviewAndReports() async throws {
        // 2 frames at 20 fps, re-opened every pass. The file "becomes unreadable" once the first
        // pass has played: every later open fails.
        let url = try await makeSyntheticVideo(frames: 2, fps: 20)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let broken = Mutex(false)
        let camera = VideoFileCamera(url: url) { source in
            if broken.withLock({ $0 }) { throw VideoFileCamera.ReaderError.cannotRead }
            return try VideoFileCamera.Reader(source: source)
        }
        let failures = Mutex<[VideoFileCameraError]>([])
        camera.setFailureHandler { error in
            if let error = error as? VideoFileCameraError { failures.withLock { $0.append(error) } }
        }
        let seen = Mutex<[Bool]>([])  // true: a frame, false: cleared
        await MainActor.run {
            camera.preview.observe { image in seen.withLock { $0.append(image != nil) } }
        }
        try await camera.start()
        try await poll { seen.withLock { $0.contains(true) } }
        broken.withLock { $0 = true }
        try await poll { !camera.isRunning }
        await camera.drainQueue()
        #expect(failures.withLock { $0 } == [.unreadable(url)])
        try await poll { seen.withLock { $0.last == false } }
        #expect(camera.preview.latest == nil)
        await MainActor.run { camera.preview.stopObserving() }
    }

    /// Polls `condition` for up to 5 s.
    private func poll(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within 5 s")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

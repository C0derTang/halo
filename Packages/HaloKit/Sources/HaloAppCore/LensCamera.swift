import HaloCore
import HaloLens
import Synchronization

/// Camera the Live Lens drives: start, stop, and a frame sink.
///
/// Frame budget (invariant 7): the handler is called on the camera's own capture queue, never the
/// main actor, and must return quickly (the lens hands the frame straight to
/// `LensPipeline.submit`, which drops it when a frame is already in flight).
public protocol CameraControlling: AnyObject, Sendable {
    /// Starts (or resumes) capture. Throws when access is denied or the camera can't be set up.
    func start() async throws
    func stop()
    /// Installs (or with nil removes) the frame sink. Frames arrive on a background queue.
    func setFrameHandler(_ handler: (@Sendable (VideoFrame) -> Void)?)
}

/// What the lens screen consumes from the pipeline. `LensPipeline` in the app, fakes in tests.
public protocol LensTrackSource: Sendable {
    /// Latest tracks after each processed frame. Single consumer.
    var tracks: AsyncStream<[LensTrack]> { get }
    /// Non-blocking frame entry point; returns false when the frame was dropped.
    @discardableResult func submit(_ frame: VideoFrame) -> Bool
    var metrics: LensMetrics { get async }
}

extension LensPipeline: LensTrackSource {}

/// Thread-safe holder for the current frame sink.
final class LensFrameHandlerBox: Sendable {
    private let handler = Mutex<(@Sendable (VideoFrame) -> Void)?>(nil)

    func set(_ newValue: (@Sendable (VideoFrame) -> Void)?) {
        handler.withLock { $0 = newValue }
    }

    func deliver(_ frame: VideoFrame) {
        let current = handler.withLock { $0 }
        current?(frame)
    }
}

#if os(iOS)
    import AVFoundation

    /// `CameraControlling` backed by HaloLens' `CameraSource` (back wide camera, BGRA, frames on a
    /// dedicated serial queue, tagged `.right` for a portrait UI).
    ///
    /// `CameraSource` fixes its frame callback at init, so this wrapper owns one and forwards its
    /// frames to whichever handler is currently installed.
    public final class LensCameraSource: CameraControlling {
        public let source: CameraSource
        private let box: LensFrameHandlerBox

        public init() {
            let box = LensFrameHandlerBox()
            self.box = box
            self.source = CameraSource { frame in box.deliver(frame) }
        }

        /// The capture session, for attaching an `AVCaptureVideoPreviewLayer`.
        public var session: AVCaptureSession { source.session }

        public func start() async throws { try await source.start() }
        public func stop() { source.stop() }
        public func setFrameHandler(_ handler: (@Sendable (VideoFrame) -> Void)?) { box.set(handler) }
    }
#endif

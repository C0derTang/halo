#if os(iOS)
    import AVFoundation
    import CoreMedia
    import HaloCore
    import ImageIO

    public enum CameraSourceError: Error, Sendable, Equatable {
        case notAuthorized
        case noCamera
        case cannotAddInput
        case cannotAddOutput
    }

    /// Back wide camera -> `VideoFrame`s. Thin on purpose (not unit tested).
    ///
    /// - 1280x720 (or the session's `.high` preset if 720p is unavailable), BGRA.
    /// - `alwaysDiscardsLateVideoFrames`, so AVFoundation drops frames rather than queueing them.
    /// - Frames are delivered on a dedicated serial queue, never the main thread. The buffer is left
    ///   in sensor orientation and tagged `.right`, which makes it upright for a portrait UI with the
    ///   back camera (no per-frame rotation cost).
    /// - Frames never leave the device; the handler typically calls `LensPipeline.submit(_:)`.
    ///
    /// `@unchecked Sendable`: all session configuration and start/stop run on `sessionQueue`; the
    /// delegate callback runs on `videoQueue` and touches only immutable state.
    public final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
        @unchecked Sendable
    {
        public typealias FrameHandler = @Sendable (VideoFrame) -> Void

        /// Orientation that makes back-camera buffers upright in a portrait UI.
        public static let portraitOrientation: CGImagePropertyOrientation = .right

        /// For attaching an `AVCaptureVideoPreviewLayer`. Do not reconfigure it directly.
        public let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "halo.camera.session")
        private let videoQueue = DispatchQueue(label: "halo.camera.video", qos: .userInteractive)
        private let output = AVCaptureVideoDataOutput()
        private let onFrame: FrameHandler
        private var configured = false

        public init(onFrame: @escaping FrameHandler) {
            self.onFrame = onFrame
            super.init()
        }

        public static var authorizationStatus: AVAuthorizationStatus {
            AVCaptureDevice.authorizationStatus(for: .video)
        }

        /// Asks for camera access if undetermined. Returns whether access is granted.
        public static func requestAccess() async -> Bool {
            switch authorizationStatus {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
            default: return false
            }
        }

        /// Configures the session on first use and starts it.
        public func start() async throws {
            guard await Self.requestAccess() else { throw CameraSourceError.notAuthorized }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                sessionQueue.async {
                    do {
                        try self.configureIfNeeded()
                        if !self.session.isRunning { self.session.startRunning() }
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }

        public func stop() {
            sessionQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
            }
        }

        /// Runs on `sessionQueue`.
        private func configureIfNeeded() throws {
            guard !configured else { return }
            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            else { throw CameraSourceError.noCamera }
            let input = try AVCaptureDeviceInput(device: device)

            session.beginConfiguration()
            defer { session.commitConfiguration() }
            session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
            guard session.canAddInput(input) else { throw CameraSourceError.cannotAddInput }
            session.addInput(input)

            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(output) else { throw CameraSourceError.cannotAddOutput }
            session.addOutput(output)
            configured = true
        }

        public func captureOutput(
            _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            onFrame(
                VideoFrame(
                    pixelBuffer: pixelBuffer, orientation: Self.portraitOrientation,
                    timestamp: CMTimeGetSeconds(time)))
        }
    }
#endif

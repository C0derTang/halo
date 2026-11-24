import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import HaloCore
import ImageIO
import Synchronization

/// Why the demo video can't play. Shown as the lens's camera error.
public enum VideoFileCameraError: Error, Equatable, Sendable, LensCameraUserMessage {
    /// No file at the path, or the app may not read it.
    case fileNotFound(URL)
    /// The file exists but is not a video AVFoundation can decode.
    case unreadable(URL)
    /// The file has no video track (e.g. audio only).
    case noVideoTrack(URL)

    public var userMessage: String {
        switch self {
        case .fileNotFound(let url): "Demo video not found: \(url.lastPathComponent)."
        case .unreadable(let url): "The demo video \(url.lastPathComponent) could not be read."
        case .noVideoTrack(let url): "The demo video \(url.lastPathComponent) has no video track."
        }
    }
}

/// `CameraControlling` that plays a local video file as if it were the camera: the Simulator demo
/// camera (it has no real one). Selected only in Simulator builds (`AppDependencies.liveCamera`).
///
/// - Decodes with `AVAssetReader` to BGRA, loops forever, and paces frames to their presentation
///   timestamps in real time, at most `maxFrameRate` per second (extra frames are skipped).
/// - Every read, decode and delivery runs on the camera's own serial queue, never the main actor
///   (invariant 7). Scheduling uses `asyncAfter`, so no thread sleeps while waiting for a frame.
/// - Frames carry the orientation of the track's `preferredTransform`, so a portrait iPhone clip
///   (stored landscape, transform +90 degrees) is tagged `.right`, like the real back camera.
/// - The file is only read, on-device; nothing is copied or stored (invariants 2 + 6).
/// - `start()` / `stop()` / `setFrameHandler` behave like `LensCameraSource`: `start()` on a
///   running camera is a no-op, restarting after `stop()` plays again from the beginning, and the
///   frame sink can be swapped at any time. `start()` throws `VideoFileCameraError` for a missing
///   or unreadable file.
/// - `preview` exposes the latest frame as an already-decoded image for the lens preview.
public final class VideoFileCamera: CameraControlling {
    public let url: URL
    /// The latest frame for the preview, converted on the camera queue (only while observed).
    public let preview = LensPreviewFeed()
    public let maxFrameRate: Double

    private let queue = DispatchQueue(label: "halo.camera.video-file", qos: .userInteractive)
    private let box = LensFrameHandlerBox()
    /// Bumped by every start and stop; a playback step from an older generation does nothing.
    private let state = Mutex(PlaybackState())

    private struct PlaybackState {
        var generation = 0
        var isRunning = false
    }

    public init(url: URL, maxFrameRate: Double = 30) {
        self.url = url
        self.maxFrameRate = max(1, maxFrameRate)
    }

    /// Whether the camera is between `start()` and `stop()`.
    public var isRunning: Bool { state.withLock { $0.isRunning } }

    public func start() async throws {
        if isRunning { return }
        let source = try await load()
        let generation = state.withLock { state -> Int? in
            guard !state.isRunning else { return nil }  // a concurrent start() won
            state.isRunning = true
            state.generation += 1
            return state.generation
        }
        guard let generation else { return }
        let playback = Playback(source: source, minimumInterval: 1 / maxFrameRate)
        queue.async { [self] in step(playback, generation: generation) }
    }

    public func stop() {
        state.withLock { state in
            guard state.isRunning else { return }
            state.isRunning = false
            state.generation += 1
        }
        // After any step already on the queue, so a late frame can't repaint the preview.
        let preview = self.preview
        queue.async { preview.clear() }
    }

    public func setFrameHandler(_ handler: (@Sendable (VideoFrame) -> Void)?) { box.set(handler) }

    /// Runs `body` after everything queued on the camera queue so far (tests).
    func drainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    // MARK: - Playback (camera queue only)

    private func isCurrent(_ generation: Int) -> Bool {
        state.withLock { $0.isRunning && $0.generation == generation }
    }

    /// Reads the next frame to show and schedules its delivery at its presentation time.
    private func step(_ playback: Playback, generation: Int) {
        guard isCurrent(generation) else { return }
        guard let mediaTime = playback.readNext() else {
            // The file became unreadable mid-play (or holds no frames): stop quietly.
            state.withLock { state in
                guard state.isRunning, state.generation == generation else { return }
                state.isRunning = false
                state.generation += 1
            }
            return
        }
        let delay = playback.delay(for: mediaTime, now: Self.hostTime())
        let deliver: @Sendable () -> Void = { [self] in
            guard isCurrent(generation), let pixelBuffer = playback.takePending() else { return }
            let frame = VideoFrame(
                pixelBuffer: pixelBuffer, orientation: playback.source.orientation, timestamp: Self.hostTime()
            )
            box.deliver(frame)
            preview.publish(frame)
            step(playback, generation: generation)
        }
        if delay > 0.001 {
            queue.asyncAfter(deadline: .now() + delay, execute: deliver)
        } else {
            queue.async(execute: deliver)
        }
    }

    /// Host clock seconds, the clock camera sample buffers are stamped with.
    private static func hostTime() -> TimeInterval {
        CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }

    // MARK: - Loading

    /// The validated asset: exists, is readable and has a decodable video track.
    struct Source: @unchecked Sendable {
        // AVAsset / AVAssetTrack are immutable once loaded; used on the camera queue only.
        let asset: AVAsset
        let track: AVAssetTrack
        let orientation: CGImagePropertyOrientation
    }

    /// Opens the file and decodes its first frame (on the camera queue) to prove it plays.
    private func load() async throws -> Source {
        let url = self.url
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            throw VideoFileCameraError.fileNotFound(url)
        }
        let asset = AVURLAsset(url: url)
        let source: Source
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoFileCameraError.noVideoTrack(url)
            }
            let transform = try await track.load(.preferredTransform)
            source = Source(asset: asset, track: track, orientation: Self.orientation(for: transform))
        } catch let error as VideoFileCameraError {
            throw error
        } catch {
            throw VideoFileCameraError.unreadable(url)
        }
        let decodes = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async {
                let reader = try? Reader(source: source)
                continuation.resume(returning: reader?.next() != nil)
            }
        }
        guard decodes else { throw VideoFileCameraError.unreadable(url) }
        return source
    }

    /// The EXIF orientation equivalent to a track's `preferredTransform` (rotation/mirroring only;
    /// translation is ignored). Anything else, e.g. a scaling transform, is treated as `.up`.
    public static func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let a = transform.a.rounded()
        let b = transform.b.rounded()
        let c = transform.c.rounded()
        let d = transform.d.rounded()
        switch (a, b, c, d) {
        case (1, 0, 0, 1): return .up
        case (-1, 0, 0, -1): return .down
        // Stored landscape, shown rotated 90 degrees clockwise (iPhone portrait recording).
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, 1): return .upMirrored
        case (1, 0, 0, -1): return .downMirrored
        case (0, 1, 1, 0): return .leftMirrored  // transpose
        case (0, -1, -1, 0): return .rightMirrored  // transverse
        default: return .up
        }
    }
}

// MARK: - Reader

extension VideoFileCamera {
    enum ReaderError: Error { case cannotRead }

    /// One pass over the file. Camera queue only.
    final class Reader {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput

        init(source: Source) throws {
            reader = try AVAssetReader(asset: source.asset)
            output = AVAssetReaderTrackOutput(
                track: source.track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ReaderError.cannotRead }
            reader.add(output)
            guard reader.startReading() else { throw ReaderError.cannotRead }
        }

        deinit { reader.cancelReading() }

        /// The next decoded frame, or nil at the end of the file (or on a read error).
        func next() -> (pixelBuffer: CVPixelBuffer, mediaTime: TimeInterval)? {
            while let sample = output.copyNextSampleBuffer() {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                return (pixelBuffer, time.isFinite ? time : 0)
            }
            return nil
        }
    }

    /// Looping, pacing and frame-rate capping for one `start()` ... `stop()`. Camera queue only;
    /// `@unchecked Sendable` because it is handed between blocks on that one serial queue.
    final class Playback: @unchecked Sendable {
        let source: Source
        private let minimumInterval: TimeInterval
        private var reader: Reader?
        /// The frame read by `readNext()`, waiting for its presentation time.
        private var pending: CVPixelBuffer?
        /// Host time and media time of the frame the clock is anchored to (per loop).
        private var anchor: (host: TimeInterval, media: TimeInterval)?
        /// Host time the previous frame was scheduled for.
        private var lastTarget: TimeInterval?
        private var lastMediaTime: TimeInterval?

        /// Falling further behind than this re-anchors the clock instead of bursting frames.
        static let maxLag: TimeInterval = 0.25

        init(source: Source, minimumInterval: TimeInterval) {
            self.source = source
            self.minimumInterval = minimumInterval
        }

        /// Reads the next frame to show into `pending` and returns its media time: skips frames
        /// closer than the frame-rate cap and loops at the end of the file. nil when the file
        /// yields no frame even from the start.
        func readNext() -> TimeInterval? {
            var reopened = false
            while true {
                if reader == nil {
                    reader = try? Reader(source: source)
                    anchor = nil
                    lastMediaTime = nil
                }
                if let frame = reader?.next() {
                    // Small tolerance so a 30 fps file isn't thinned by timestamp rounding.
                    if let last = lastMediaTime, frame.mediaTime >= last,
                        frame.mediaTime - last < minimumInterval * 0.9
                    {
                        continue
                    }
                    lastMediaTime = frame.mediaTime
                    pending = frame.pixelBuffer
                    return frame.mediaTime
                }
                // End of file: loop from the start; an empty pass means nothing to play.
                reader = nil
                if reopened { return nil }
                reopened = true
            }
        }

        func takePending() -> CVPixelBuffer? {
            defer { pending = nil }
            return pending
        }

        /// Seconds to wait before showing the frame at `mediaTime`. A loop's first frame follows
        /// the previous loop's last one by one frame interval.
        func delay(for mediaTime: TimeInterval, now: TimeInterval) -> TimeInterval {
            let target: TimeInterval
            if let anchor, mediaTime >= anchor.media,
                anchor.host + (mediaTime - anchor.media) >= now - Self.maxLag
            {
                target = anchor.host + (mediaTime - anchor.media)
            } else {
                let start = lastTarget.map { max(now, $0 + minimumInterval) } ?? now
                // Behind by more than `maxLag`: restart the clock here rather than burst.
                target = anchor == nil ? start : now
                anchor = (target, mediaTime)
            }
            lastTarget = target
            return max(0, target - now)
        }
    }
}

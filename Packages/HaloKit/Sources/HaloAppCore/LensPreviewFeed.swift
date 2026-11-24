import CoreGraphics
import CoreVideo
import Foundation
import HaloCore
import ImageIO
import Synchronization
import VideoToolbox

/// One decoded preview frame: the buffer as stored plus the orientation that makes it upright
/// (the same orientation the overlay maps face boxes with).
public struct LensPreviewImage: @unchecked Sendable {
    // CGImage is immutable.
    public let image: CGImage
    public let orientation: CGImagePropertyOrientation

    public init(image: CGImage, orientation: CGImagePropertyOrientation) {
        self.image = image
        self.orientation = orientation
    }

    /// Size once `orientation` is applied (what the preview fills the view with).
    public var uprightSize: CGSize {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            CGSize(width: image.height, height: image.width)
        default:
            CGSize(width: image.width, height: image.height)
        }
    }
}

/// The latest camera frame for a preview that is not an `AVCaptureVideoPreviewLayer` (the
/// Simulator demo camera).
///
/// Frame budget (invariant 7): `publish` runs on the camera queue, converts the buffer to a
/// `CGImage` there (only while someone observes) and never waits for the main actor. The main
/// actor only receives the already-decoded image, coalesced: at most one hop is in flight, and it
/// delivers whatever frame is newest when it runs. Frames are never stored beyond the latest one.
public final class LensPreviewFeed: Sendable {
    public typealias Observer = @MainActor @Sendable (LensPreviewImage?) -> Void

    private struct State {
        var latest: LensPreviewImage?
        var observer: Observer?
        var hopPending = false
    }
    private let state = Mutex(State())

    public init() {}

    /// The newest converted frame (nil before the first one, after `clear()`, or when nobody
    /// observes).
    public var latest: LensPreviewImage? { state.withLock { $0.latest } }

    /// Installs the one observer (replacing any other) and calls it with the newest frame.
    @MainActor
    public func observe(_ observer: @escaping Observer) {
        let latest = state.withLock { state -> LensPreviewImage? in
            state.observer = observer
            return state.latest
        }
        observer(latest)
    }

    /// Removes the observer; frames are no longer converted.
    @MainActor
    public func stopObserving() {
        state.withLock {
            $0.observer = nil
            $0.latest = nil
        }
    }

    /// Camera queue: converts the frame for the preview when observed and schedules a main-actor
    /// update unless one is already pending.
    func publish(_ frame: VideoFrame) {
        guard state.withLock({ $0.observer != nil }) else { return }
        guard let image = Self.makeImage(frame.pixelBuffer) else { return }
        update(LensPreviewImage(image: image, orientation: frame.orientation))
    }

    /// Camera queue: the camera stopped; the preview goes black.
    func clear() {
        update(nil)
    }

    private func update(_ image: LensPreviewImage?) {
        let shouldHop = state.withLock { state -> Bool in
            state.latest = image
            guard state.observer != nil, !state.hopPending else { return false }
            state.hopPending = true
            return true
        }
        guard shouldHop else { return }
        Task { @MainActor [self] in
            let (observer, latest) = state.withLock { state in
                state.hopPending = false
                return (state.observer, state.latest)
            }
            observer?(latest)
        }
    }

    static func makeImage(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        return status == noErr ? image : nil
    }
}

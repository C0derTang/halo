import Foundation
import HaloCore
import HaloLens
import Synchronization

/// The camera as the composition root sees it: start and stop. `CameraSource` conforms on iOS;
/// tests use a fake.
public protocol AppCamera: AnyObject, Sendable {
    func start() async throws
    func stop()
}

#if os(iOS)
    extension CameraSource: AppCamera {}
#endif

/// Routes camera frames to the lens pipeline without touching the main actor (invariant 7).
///
/// The camera is created before the embedding model has loaded, so the pipeline is attached later.
/// Until then (or when recognition is unavailable) frames are dropped here.
final class LensFrameRouter: Sendable {
    private let pipeline = Mutex<LensPipeline?>(nil)

    func attach(_ pipeline: LensPipeline?) {
        self.pipeline.withLock { $0 = pipeline }
    }

    /// Called on the camera's video queue for every frame. Never blocks: `submit` drops the frame
    /// when one is already in flight.
    func route(_ frame: VideoFrame) {
        pipeline.withLock { $0 }?.submit(frame)
    }
}

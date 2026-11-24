import Foundation
import HaloCore
import Synchronization

/// A camera error that carries its own text for the lens banner.
public protocol LensCameraUserMessage: Error {
    var userMessage: String { get }
}

/// A camera that can stop on its own after a successful `start()` (the demo video became
/// unreadable). The lens installs a handler that ends its session and shows the error, so it
/// never claims to capture when nothing plays.
public protocol CameraFailureReporting: CameraControlling {
    /// Installs (or with nil removes) the handler. Called at most once per `start()`, on the
    /// camera's queue, after the camera has stopped itself.
    func setFailureHandler(_ handler: (@Sendable (any Error) -> Void)?)
}

/// Thread-safe holder for a camera's failure handler.
final class CameraFailureHandlerBox: Sendable {
    private let handler = Mutex<(@Sendable (any Error) -> Void)?>(nil)

    func set(_ newValue: (@Sendable (any Error) -> Void)?) {
        handler.withLock { $0 = newValue }
    }

    func deliver(_ error: any Error) {
        let current = handler.withLock { $0 }
        current?(error)
    }
}

/// A camera that never starts; `start()` throws `CameraUnavailableError` with `message`.
/// The Simulator without a demo video uses it, so the lens explains how to get one instead of
/// asking for a camera that does not exist.
public final class NoCameraSource: CameraControlling {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public func start() async throws { throw CameraUnavailableError(userMessage: message) }
    public func stop() {}
    public func setFrameHandler(_ handler: (@Sendable (VideoFrame) -> Void)?) {}
}

public struct CameraUnavailableError: LensCameraUserMessage, Equatable, Sendable {
    public let userMessage: String
}

#if !os(iOS) || targetEnvironment(simulator)
    /// Which camera a Simulator build uses. Compiled only for the Simulator and the macOS host (unit
    /// tests): it does not exist in device builds, so no device code path can read `HALO_DEMO_VIDEO`
    /// or play a file instead of the camera. Its one app caller is `AppDependencies.liveCamera`.
    public enum SimulatorCamera {
        /// Absolute path of the demo video. `scripts/sim-run.sh` sets it through
        /// `SIMCTL_CHILD_HALO_DEMO_VIDEO`.
        public static let environmentKey = "HALO_DEMO_VIDEO"

        public static let noCameraMessage =
            "Simulator has no camera. Run scripts/sim-run.sh <video> to play a demo video."

        /// The demo video named by the environment, else a camera that explains how to set one.
        /// A path that is set but missing or unreadable still selects the video camera, whose
        /// `start()` then reports exactly what is wrong with the file.
        public static func make(environment: [String: String]) -> any CameraControlling {
            guard let path = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            else {
                return NoCameraSource(message: noCameraMessage)
            }
            return VideoFileCamera(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
    }
#endif

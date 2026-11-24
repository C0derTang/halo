import Foundation
import HaloCore

/// A camera error that carries its own text for the lens banner.
public protocol LensCameraUserMessage: Error {
    var userMessage: String { get }
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

/// Which camera a Simulator build uses. The caller (`AppDependencies.liveCamera`) only exists
/// under `#if targetEnvironment(simulator)`, so device builds never read `HALO_DEMO_VIDEO` and can
/// never play a file instead of the camera. Compiled everywhere so it is unit-tested on the host.
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

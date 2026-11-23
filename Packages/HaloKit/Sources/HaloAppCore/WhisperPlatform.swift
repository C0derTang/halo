import AVFoundation
import Foundation

#if canImport(UIKit) && os(iOS)
    import UIKit
#endif

/// Real route check. Only headphone-class outputs count: wired headphones, Bluetooth A2DP / HFP / LE.
/// Built-in speaker, receiver, AirPlay, HDMI, car and USB outputs are not private.
public struct SystemAudioRouteChecker: AudioRouteChecking {
    public init() {}

    public var isPrivateRoute: Bool {
        #if os(iOS)
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            return !outputs.isEmpty && outputs.allSatisfy { Self.isPrivate($0.portType) }
        #else
            return false
        #endif
    }

    #if os(iOS)
        static func isPrivate(_ port: AVAudioSession.Port) -> Bool {
            switch port {
            case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return true
            default: return false
            }
        }
    #endif
}

@MainActor
public final class SystemWhisperSpeech: WhisperSpeaking {
    private let synthesizer = AVSpeechSynthesizer()

    public init() {}

    public func speak(_ text: String) {
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

@MainActor
public final class SystemWhisperHaptics: WhisperHaptics {
    public init() {}

    public func tap() {
        #if canImport(UIKit) && os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

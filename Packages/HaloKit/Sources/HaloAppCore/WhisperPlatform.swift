import AVFoundation
import Foundation

#if canImport(UIKit) && os(iOS)
    import UIKit
#endif

// Wiring note: configure the app audio session as `.playback` with `.mixWithOthers` (or use
// `.ambient`), never `.defaultToSpeaker`, and keep a `WhisperRouteObserver` alive that forwards to
// `WhisperAnnouncer.routeDidChange()`.

/// Real route reader. Wired headphones are private; Bluetooth A2DP / HFP / LE outputs are reported
/// as `.bluetooth` (the announcer requires user confirmation per device, since car kits look the
/// same). Everything else (speaker, receiver, AirPlay, HDMI, USB, car) is `.other`.
public struct SystemAudioRouteChecker: AudioRouteChecking {
    public init() {}

    public var outputs: [AudioOutput] {
        #if os(iOS)
            return AVAudioSession.sharedInstance().currentRoute.outputs.map {
                AudioOutput(portUID: $0.uid, name: $0.portName, kind: Self.kind($0.portType))
            }
        #else
            return []
        #endif
    }

    #if os(iOS)
        static func kind(_ port: AVAudioSession.Port) -> AudioOutput.Kind {
            switch port {
            case .headphones: return .wiredHeadphones
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return .bluetooth
            default: return .other
            }
        }
    #endif
}

/// Persists confirmed Bluetooth device UIDs in UserDefaults (device identifiers, not personal data).
public final class UserDefaultsTrustedAudioDeviceStore: TrustedAudioDeviceStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "halo.whisper.trustedAudioDevices") {
        self.defaults = defaults
        self.key = key
    }

    public func isTrusted(_ portUID: String) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(portUID)
    }

    public func trust(_ portUID: String) {
        var uids = Set(defaults.stringArray(forKey: key) ?? [])
        uids.insert(portUID)
        defaults.set(Array(uids), forKey: key)
    }
}

/// Speaks one utterance at a time; `stop()` halts immediately and drops the completion.
@MainActor
public final class SystemWhisperSpeech: NSObject, WhisperSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (@MainActor () -> Void)?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String, completion: @escaping @MainActor () -> Void) {
        self.completion = completion
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    public func stop() {
        completion = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            let done = self.completion
            self.completion = nil
            done?()
        }
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

/// Forwards `AVAudioSession.routeChangeNotification` (iOS) to a handler on the main actor.
@MainActor
public final class WhisperRouteObserver {
    nonisolated(unsafe) private var token: (any NSObjectProtocol)?

    public init(handler: @escaping @MainActor @Sendable () -> Void) {
        #if os(iOS)
            token = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { handler() }
            }
        #endif
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

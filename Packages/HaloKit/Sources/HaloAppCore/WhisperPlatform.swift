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
    public init() {
        #if os(iOS)
            // Guards the raw-value constants in `AudioOutput.Kind(portType:)` against SDK changes.
            assert(AVAudioSession.Port.headphones.rawValue == AudioOutput.Kind.headphonesPort)
            assert(AVAudioSession.Port.bluetoothA2DP.rawValue == AudioOutput.Kind.bluetoothA2DPPort)
            assert(AVAudioSession.Port.bluetoothHFP.rawValue == AudioOutput.Kind.bluetoothHFPPort)
            assert(AVAudioSession.Port.bluetoothLE.rawValue == AudioOutput.Kind.bluetoothLEPort)
        #endif
    }

    public var outputs: [AudioOutput] {
        #if os(iOS)
            return AVAudioSession.sharedInstance().currentRoute.outputs.map {
                AudioOutput(
                    portUID: $0.uid, name: $0.portName, kind: AudioOutput.Kind(portType: $0.portType.rawValue)
                )
            }
        #else
            return []
        #endif
    }
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
/// Delegate events are matched to their own utterance, so a late event for an old utterance can
/// never complete the current one (the announcer re-checks the route before each utterance).
@MainActor
public final class SystemWhisperSpeech: NSObject, WhisperSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let gate: WhisperUtteranceGate
    private var ids: [ObjectIdentifier: Int] = [:]

    public init(timeout: Duration = .seconds(10)) {
        gate = WhisperUtteranceGate(timeout: timeout)
        super.init()
        synthesizer.delegate = self
        gate.onTimeout = { [weak self] in
            // The utterance is abandoned: drop its bookkeeping so `ids` cannot grow.
            self?.ids.removeAll()
            self?.synthesizer.stopSpeaking(at: .immediate)
        }
    }

    public func speak(_ text: String, completion: @escaping @MainActor (WhisperSpeechResult) -> Void) {
        let utterance = AVSpeechUtterance(string: text)
        ids[ObjectIdentifier(utterance)] = gate.begin(completion)
        synthesizer.speak(utterance)
    }

    public func stop() {
        gate.cancel()
        ids.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }

    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.end(key, .finished) }
    }

    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.end(key, .interrupted) }
    }

    private func end(_ key: ObjectIdentifier, _ result: WhisperSpeechResult) {
        guard let id = ids.removeValue(forKey: key) else { return }
        gate.end(id, result)
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
    // Only written in init and read in deinit, never concurrently; NSObjectProtocol is not Sendable.
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

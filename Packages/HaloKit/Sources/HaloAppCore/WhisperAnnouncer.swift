import Foundation
import HaloCore
import HaloUI
import Observation

/// Whisper-mode settings. Off by default.
public struct WhisperSettings: Equatable, Sendable {
    public var isEnabled: Bool
    /// Also speak the person's top chip ("Name — chip").
    public var speaksChip: Bool

    public init(isEnabled: Bool = false, speaksChip: Bool = true) {
        self.isEnabled = isEnabled
        self.speaksChip = speaksChip
    }
}

/// One audio output of the current route.
public struct AudioOutput: Hashable, Sendable {
    public enum Kind: Sendable {
        /// Wired headphones: always private.
        case wiredHeadphones
        /// Bluetooth A2DP / HFP / LE: private only once the user confirmed this device (car kits
        /// look the same as headphones).
        case bluetooth
        /// Speaker, receiver, AirPlay, HDMI, USB, car, anything else: never private.
        case other
    }

    public var portUID: String
    public var name: String
    public var kind: Kind

    public init(portUID: String, name: String, kind: Kind) {
        self.portUID = portUID
        self.name = name
        self.kind = kind
    }
}

/// The current audio route.
public protocol AudioRouteChecking: Sendable {
    var outputs: [AudioOutput] { get }
}

/// Bluetooth devices the user has confirmed as personal headphones.
public protocol TrustedAudioDeviceStore: AnyObject {
    func isTrusted(_ portUID: String) -> Bool
    func trust(_ portUID: String)
}

public final class InMemoryTrustedAudioDeviceStore: TrustedAudioDeviceStore {
    private var uids: Set<String>
    public init(_ uids: Set<String> = []) { self.uids = uids }
    public func isTrusted(_ portUID: String) -> Bool { uids.contains(portUID) }
    public func trust(_ portUID: String) { uids.insert(portUID) }
}

public enum WhisperSpeechResult: Sendable {
    /// Played to the end.
    case finished
    /// Cancelled by the system or timed out: the person was not (fully) heard.
    case interrupted
}

/// Speech output. Utterances are never queued inside the synthesizer: the announcer hands over one
/// at a time.
@MainActor public protocol WhisperSpeaking: AnyObject {
    /// Speaks `text`; calls `completion` exactly once when it ends on its own (finished, cancelled
    /// by the system, or timed out). Not called after `stop()`.
    func speak(_ text: String, completion: @escaping @MainActor (WhisperSpeechResult) -> Void)
    /// Stops immediately and drops the pending completion.
    func stop()
}

@MainActor public protocol WhisperHaptics: AnyObject {
    func tap()
}

/// Discreetly announces known people through personal headphones.
///
/// Invariants: never speaks unless every output is private (wired headphones, or a Bluetooth device
/// the user confirmed); never for a track without a confirmed-person label; once per person per lens
/// session. The route is re-checked right before each utterance, utterances are played one at a
/// time, and `routeDidChange()` cancels everything the moment the route stops being private.
/// Cancelled people are un-marked so they are announced later.
///
/// Wiring note: the app audio session must be `.playback` with `.mixWithOthers` (or `.ambient`),
/// never `.defaultToSpeaker`, and `routeDidChange()` must be called on
/// `AVAudioSession.routeChangeNotification` (see `WhisperRouteObserver`).
@Observable
@MainActor
public final class WhisperAnnouncer {
    /// Turning whisper off cancels any queued or playing speech immediately.
    @ObservationIgnored public var settings: WhisperSettings {
        didSet { if !settings.isEnabled { cancelAll() } }
    }
    /// A Bluetooth output the user hasn't confirmed yet. Nothing is announced while it is the route;
    /// the UI asks the user, then calls `confirmPendingDevice()` or `dismissPendingDevice()`.
    public private(set) var pendingDeviceConfirmation: AudioOutput?

    @ObservationIgnored private let route: any AudioRouteChecking
    @ObservationIgnored private let devices: any TrustedAudioDeviceStore
    @ObservationIgnored private let speech: any WhisperSpeaking
    @ObservationIgnored private let haptics: any WhisperHaptics
    /// Spoken, speaking or queued.
    @ObservationIgnored private var announced: Set<PersonID> = []
    @ObservationIgnored private var queue: [(person: PersonID, text: String)] = []
    @ObservationIgnored private var current: (person: PersonID, text: String)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tapped: Set<PersonID> = []
    @ObservationIgnored private var dismissedDevices: Set<String> = []
    /// Interrupted attempts per person this session, and when the last one happened.
    @ObservationIgnored private var interruptions: [PersonID: (count: Int, last: Date)] = [:]
    @ObservationIgnored private let now: @MainActor () -> Date

    /// An interrupted person is retried at most this many times per lens session.
    public static let maxInterruptedAttempts = 3
    /// Minimum wait after an interruption before the person is announced again.
    public static let retryBackoff: TimeInterval = 5

    public init(
        settings: WhisperSettings = WhisperSettings(), route: any AudioRouteChecking,
        devices: any TrustedAudioDeviceStore = InMemoryTrustedAudioDeviceStore(),
        speech: any WhisperSpeaking, haptics: any WhisperHaptics,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.now = now
        self.settings = settings
        self.route = route
        self.devices = devices
        self.speech = speech
        self.haptics = haptics
    }

    /// Call with every lens overlay update.
    public func update(_ items: [LensOverlayItem]) {
        guard settings.isEnabled else { return }
        let isPrivate = evaluateRoute()
        for item in items where item.state == .stable {
            guard let label = item.label else { continue }  // unknown / ambiguous: silent
            let person = label.personID
            if tapped.insert(person).inserted { haptics.tap() }
            guard isPrivate, !announced.contains(person) else { continue }
            if let interruption = interruptions[person],
                now().timeIntervalSince(interruption.last) < Self.retryBackoff
            {
                continue
            }
            let name = label.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            var text = name
            if settings.speaksChip, let chip = label.chips.max(by: { $0.priority < $1.priority }) {
                text += " — \(chip.text)"
            }
            announced.insert(person)
            queue.append((person, text))
        }
        pump()
    }

    /// Call on every audio route change. Cancels all speech if the route is no longer private.
    public func routeDidChange() {
        if !evaluateRoute() { cancelAll() }
    }

    /// The user confirmed the pending Bluetooth device as personal headphones.
    public func confirmPendingDevice() {
        guard let device = pendingDeviceConfirmation else { return }
        devices.trust(device.portUID)
        pendingDeviceConfirmation = nil
    }

    /// The user said the pending device is not personal headphones; stay silent on it.
    public func dismissPendingDevice() {
        guard let device = pendingDeviceConfirmation else { return }
        dismissedDevices.insert(device.portUID)
        pendingDeviceConfirmation = nil
    }

    /// Start of a new lens session: everyone may be announced again.
    public func resetSession() {
        cancelAll()
        announced.removeAll()
        tapped.removeAll()
        interruptions.removeAll()
    }

    // MARK: - Private

    /// True when speaking is allowed right now. Also updates `pendingDeviceConfirmation`.
    private func evaluateRoute() -> Bool {
        let outputs = route.outputs
        guard !outputs.isEmpty else { return false }
        var allowed = true
        var pending: AudioOutput?
        for output in outputs {
            switch output.kind {
            case .wiredHeadphones: continue
            case .bluetooth:
                if devices.isTrusted(output.portUID) { continue }
                allowed = false
                if !dismissedDevices.contains(output.portUID), pending == nil { pending = output }
            case .other: allowed = false
            }
        }
        if pendingDeviceConfirmation != pending { pendingDeviceConfirmation = pending }
        return allowed
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        // Re-check right before each utterance.
        guard evaluateRoute() else { return cancelAll() }
        let next = queue.removeFirst()
        current = next
        let token = generation
        speech.speak(next.text) { [weak self] result in self?.finished(token, result) }
    }

    private func finished(_ token: Int, _ result: WhisperSpeechResult) {
        guard token == generation, let done = current else { return }
        if result == .interrupted {
            // Re-announce later, but give up after `maxInterruptedAttempts` (the person stays marked
            // as announced for the rest of the session).
            let count = (interruptions[done.person]?.count ?? 0) + 1
            interruptions[done.person] = (count, now())
            if count < Self.maxInterruptedAttempts { announced.remove(done.person) }
        }
        current = nil
        pump()
    }

    private func cancelAll() {
        generation += 1
        if current != nil { speech.stop() }
        if let current { announced.remove(current.person) }
        for item in queue { announced.remove(item.person) }
        current = nil
        queue.removeAll()
    }
}

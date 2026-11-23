import Foundation
import HaloCore
import HaloUI

#if os(iOS)
    import AVFoundation
#endif

// MARK: - Audio session

/// How the app audio session is set up while Whisper mode may speak.
public struct WhisperAudioSessionConfiguration: Equatable, Sendable {
    public enum Category: Equatable, Sendable {
        /// `AVAudioSession.Category.playback`.
        case playback
    }

    public var category: Category
    /// `.mixWithOthers`: whispers play over the user's music / podcast instead of stopping it.
    public var mixesWithOthers: Bool

    public init(category: Category, mixesWithOthers: Bool) {
        self.category = category
        self.mixesWithOthers = mixesWithOthers
    }

    /// `.playback` + `.mixWithOthers`. Never `.defaultToSpeaker`: there is no such option here, and
    /// the system configurator never sets it (the announcer additionally refuses any non-private
    /// route).
    public static let whisper = WhisperAudioSessionConfiguration(category: .playback, mixesWithOthers: true)
}

/// The app audio session, injected so tests can assert what is configured and when.
@MainActor
public protocol AudioSessionConfiguring: AnyObject {
    /// Sets the category and options, then activates the session.
    func activate(_ configuration: WhisperAudioSessionConfiguration) throws
    /// Deactivates the session (other apps' audio resumes at full volume).
    func deactivate()
}

/// `AVAudioSession.sharedInstance()` on iOS; nothing elsewhere.
@MainActor
public final class SystemAudioSessionConfigurator: AudioSessionConfiguring {
    public init() {}

    public func activate(_ configuration: WhisperAudioSessionConfiguration) throws {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            var options: AVAudioSession.CategoryOptions = []
            if configuration.mixesWithOthers { options.insert(.mixWithOthers) }
            // `.defaultToSpeaker` is deliberately never inserted.
            switch configuration.category {
            case .playback:
                try session.setCategory(.playback, mode: .default, options: options)
            }
            try session.setActive(true)
        #endif
    }

    public func deactivate() {
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

// MARK: - Settings persistence

/// Where the Whisper toggles live. Non-sensitive booleans; Whisper is OFF until the user turns it on.
@MainActor
public protocol WhisperSettingsStoring: AnyObject {
    func load() -> WhisperSettings
    func save(_ settings: WhisperSettings)
}

public final class InMemoryWhisperSettingsStore: WhisperSettingsStoring {
    private var settings: WhisperSettings
    public init(_ settings: WhisperSettings = WhisperSettings()) { self.settings = settings }
    public func load() -> WhisperSettings { settings }
    public func save(_ settings: WhisperSettings) { self.settings = settings }
}

public final class UserDefaultsWhisperSettingsStore: WhisperSettingsStoring {
    private let defaults: UserDefaults
    private let enabledKey: String
    private let chipKey: String

    public init(defaults: UserDefaults = .standard, prefix: String = "halo.whisper") {
        self.defaults = defaults
        enabledKey = prefix + ".enabled"
        chipKey = prefix + ".speaksChip"
    }

    public func load() -> WhisperSettings {
        let defaultValue = WhisperSettings()
        return WhisperSettings(
            isEnabled: defaults.object(forKey: enabledKey) as? Bool ?? defaultValue.isEnabled,
            speaksChip: defaults.object(forKey: chipKey) as? Bool ?? defaultValue.speaksChip)
    }

    public func save(_ settings: WhisperSettings) {
        defaults.set(settings.isEnabled, forKey: enabledKey)
        defaults.set(settings.speaksChip, forKey: chipKey)
    }
}

// MARK: - Components

/// Everything Whisper mode is built from. `system()` in the app, fakes in tests.
@MainActor
public struct WhisperComponents {
    public var route: any AudioRouteChecking
    public var devices: any TrustedAudioDeviceStore
    public var speech: any WhisperSpeaking
    public var haptics: any WhisperHaptics
    public var audioSession: any AudioSessionConfiguring
    public var settings: any WhisperSettingsStoring

    public init(
        route: any AudioRouteChecking, devices: any TrustedAudioDeviceStore, speech: any WhisperSpeaking,
        haptics: any WhisperHaptics, audioSession: any AudioSessionConfiguring,
        settings: any WhisperSettingsStoring
    ) {
        self.route = route
        self.devices = devices
        self.speech = speech
        self.haptics = haptics
        self.audioSession = audioSession
        self.settings = settings
    }

    /// The real route, `UserDefaultsTrustedAudioDeviceStore`, `AVSpeechSynthesizer`, haptics, the
    /// shared audio session and persisted toggles.
    public static func system() -> WhisperComponents {
        WhisperComponents(
            route: SystemAudioRouteChecker(), devices: UserDefaultsTrustedAudioDeviceStore(),
            speech: SystemWhisperSpeech(), haptics: SystemWhisperHaptics(),
            audioSession: SystemAudioSessionConfigurator(), settings: UserDefaultsWhisperSettingsStore())
    }

    /// Never speaks: no audio outputs, so the announcer stays silent. The default for tests and
    /// previews.
    public static func silent() -> WhisperComponents {
        WhisperComponents(
            route: NoAudioRoute(), devices: InMemoryTrustedAudioDeviceStore(), speech: SilentWhisperSpeech(),
            haptics: SilentWhisperHaptics(), audioSession: NoAudioSession(),
            settings: InMemoryWhisperSettingsStore())
    }
}

/// A route with no outputs: never private, so nothing is spoken.
struct NoAudioRoute: AudioRouteChecking {
    var outputs: [AudioOutput] { [] }
}

@MainActor
final class SilentWhisperSpeech: WhisperSpeaking {
    func speak(_ text: String, completion: @escaping @MainActor (WhisperSpeechResult) -> Void) {
        completion(.finished)
    }
    func stop() {}
}

@MainActor
final class SilentWhisperHaptics: WhisperHaptics {
    func tap() {}
}

@MainActor
final class NoAudioSession: AudioSessionConfiguring {
    func activate(_ configuration: WhisperAudioSessionConfiguration) throws {}
    func deactivate() {}
}

// MARK: - Environment wiring

/// What Whisper reacts to in one overlay item: who is labeled, with what, in which state. Box
/// moves are not part of it.
struct WhisperFeedKey: Hashable {
    let label: LabelData
    let state: HologramState
}

extension AppEnvironment {
    /// Re-feed an unchanged overlay at most this often (so an interrupted person's retry backoff
    /// can elapse while nobody moves).
    static let whisperRefeedInterval: TimeInterval = 1

    /// Whisper may speak right now: the user turned it on, a lens session is running, the app is
    /// unlocked and not in the background, no kill switch is running and no Moment is open.
    var whisperMayRun: Bool {
        whisperSettings.isEnabled && isLensRunning && !appLock.isLocked && phase != .background
            && !isErasing && !isMomentOpen
    }

    /// The Bluetooth device to ask about, only while Whisper is on. Bind the prompt to this.
    public var whisperDevicePrompt: AudioOutput? {
        whisperSettings.isEnabled ? whisper.pendingDeviceConfirmation : nil
    }

    /// Settings toggles. Turning Whisper off cancels any speech at once, withdraws a device question
    /// and releases the audio session; turning it on while the lens runs activates it.
    public func setWhisperSettings(_ settings: WhisperSettings) {
        whisperSettings = settings
        whisperComponents.settings.save(settings)
        whisper.settings = settings
        syncWhisperAudio()
        refeedWhisper()
    }

    /// The user confirmed / declined the Bluetooth device Whisper asked about.
    public func confirmWhisperDevice(_ trusted: Bool) {
        if trusted {
            whisper.confirmPendingDevice()
        } else {
            whisper.dismissPendingDevice()
        }
        refeedWhisper()
    }

    /// After a Moment closes, Whisper's session is set up once more after this delay: dictation's
    /// teardown (restore the category, deactivate the shared session) may land after the close.
    static let momentAudioResyncDelay: Duration = .milliseconds(300)

    /// A Moment sheet opened for `model`. Whisper is paused while it is open (speech cancelled,
    /// session released: dictation switches the shared session to `.record`).
    public func momentSheetOpened(_ model: MomentsModel) {
        openMoment = model
        guard !isMomentOpen else { return }
        isMomentOpen = true
        whisper.cancelSpeech()
        syncWhisperAudio()
    }

    /// The Moment sheet closed (Done, swipe-down, lock). Dictation is stopped FIRST, then Whisper's
    /// `.playback` + `.mixWithOthers` session is set up again from scratch, and once more after
    /// `momentAudioResyncDelay` in case dictation's teardown deactivated the session after that.
    public func momentSheetClosed() {
        openMoment?.stopDictation()
        openMoment = nil
        guard isMomentOpen else { return }
        isMomentOpen = false
        resyncWhisperAudioFromScratch()
        refeedWhisper()
        let delay = Self.momentAudioResyncDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !self.isMomentOpen else { return }
            self.resyncWhisperAudioFromScratch()
        }
    }

    /// Forgets what we believe about the shared session and applies the current rule again.
    private func resyncWhisperAudioFromScratch() {
        isWhisperAudioActive = false
        syncWhisperAudio()
    }

    /// `AVAudioSession.routeChangeNotification`. Forwarded only while Whisper may run, so a route
    /// change with Whisper off (new AirPods, dictation's `.record`) never asks about a device.
    /// Safety net while it may not run (e.g. the hop between a lock and the lens stopping): any
    /// speech still playing is cancelled if the new route is not private. No question is asked.
    func whisperRouteChanged() {
        guard whisperMayRun else {
            if !whisperRouteIsPrivate { whisper.cancelSpeech() }
            return
        }
        whisper.routeDidChange()
    }

    /// Every output is wired headphones or a Bluetooth device the user confirmed. Read-only: never
    /// sets the announcer's pending device.
    var whisperRouteIsPrivate: Bool {
        let outputs = whisperComponents.route.outputs
        guard !outputs.isEmpty else { return false }
        return outputs.allSatisfy { output in
            switch output.kind {
            case .wiredHeadphones: true
            case .bluetooth: whisperComponents.devices.isTrusted(output.portUID)
            case .other: false
            }
        }
    }

    /// The audio session is active exactly while Whisper may run. When it may not, any pending
    /// device question is withdrawn.
    func syncWhisperAudio() {
        if whisperMayRun {
            guard !isWhisperAudioActive else { return }
            do {
                try whisperComponents.audioSession.activate(.whisper)
                isWhisperAudioActive = true
            } catch {
                // Without our session Whisper stays silent rather than using another category.
                isWhisperAudioActive = false
            }
        } else {
            whisper.clearPendingDevice()
            lastWhisperFeed = nil
            if isWhisperAudioActive {
                whisperComponents.audioSession.deactivate()
                isWhisperAudioActive = false
            }
        }
    }

    /// Every lens overlay update. Fed to Whisper only while it may run with its session active,
    /// and only when the labeled people or their states changed (or `whisperRefeedInterval`
    /// passed), not on every box move.
    func lensItemsChanged(_ items: [LensOverlayItem], now: Date = Date()) {
        guard whisperMayRun, isWhisperAudioActive else { return }
        let signature = Set(
            items.compactMap { item in item.label.map { WhisperFeedKey(label: $0, state: item.state) } })
        if let last = lastWhisperFeed, last.signature == signature,
            now.timeIntervalSince(last.at) < Self.whisperRefeedInterval
        {
            return
        }
        lastWhisperFeed = (signature, now)
        whisper.update(items)
    }

    /// Feeds the current overlay regardless of the last signature (settings, device answer, Moment
    /// closed).
    private func refeedWhisper() {
        lastWhisperFeed = nil
        if let lens { lensItemsChanged(lens.items) }
    }

    /// Lens stopped (tab left, lock, background, kill switch): cancel speech, release the session.
    func stopWhisper() {
        whisper.resetSession()
        syncWhisperAudio()
    }

    /// Kill switch: the toggles go back to their defaults (off) and every trusted device is
    /// forgotten.
    func eraseWhisperData() {
        whisperComponents.devices.removeAll()
        setWhisperSettings(WhisperSettings())
        whisper.clearPendingDevice()
    }
}

import Foundation
import HaloCore
import HaloImport
import HaloUI
import Synchronization
import Testing

@testable import HaloAppCore

// Memory hooks + Whisper wiring and the #68 follow-ups (#69). Synthetic people, handles, message
// excerpts and audio devices only; no model, no speaker, no real audio session.

// MARK: - Fakes

/// Scripted on-device hook generator. Optionally parks inside `hooks` until `gate` opens (a
/// generation "in flight"); the park ignores cancellation, like a model call that is mid-inference.
actor EnvHookGenerator: MemoryHookGenerating {
    let log: EnvEventLog
    let gate: EnvGate?
    let texts: [String]
    private(set) var calls = 0

    init(log: EnvEventLog, texts: [String] = ["Training for a marathon"], gate: EnvGate? = nil) {
        self.log = log
        self.texts = texts
        self.gate = gate
    }

    var isAvailable: Bool { true }

    func hooks(for person: Person, messages: [InteractionDigest.DigestMessage], now: Date) async throws
        -> [MemoryHook]
    {
        calls += 1
        log.record("generator.start")
        await gate?.wait()
        log.record("generator.end")
        return texts.map {
            MemoryHook(personID: person.id, text: $0, source: .onDeviceSummary, createdAt: now)
        }
    }
}

final class EnvRoute: AudioRouteChecking {
    private let current: Mutex<[AudioOutput]>
    init(_ outputs: [AudioOutput]) { current = Mutex(outputs) }
    var outputs: [AudioOutput] { current.withLock { $0 } }
    func set(_ outputs: [AudioOutput]) { current.withLock { $0 = outputs } }

    static let wired = AudioOutput(
        portUID: "synthetic-wired", name: "Synthetic Headphones", kind: .wiredHeadphones)
    static let bluetooth = AudioOutput(portUID: "synthetic-bt", name: "Synthetic Buds", kind: .bluetooth)
    static let speaker = AudioOutput(portUID: "synthetic-speaker", name: "Speaker", kind: .other)
}

/// Records utterances; each one stays "playing" until `finishCurrent()` (or `stop()`).
@MainActor
final class EnvSpeech: WhisperSpeaking {
    private(set) var spoken: [String] = []
    private(set) var stops = 0
    private var completion: (@MainActor (WhisperSpeechResult) -> Void)?

    func speak(_ text: String, completion: @escaping @MainActor (WhisperSpeechResult) -> Void) {
        spoken.append(text)
        self.completion = completion
    }
    func stop() {
        stops += 1
        completion = nil
    }
    func finishCurrent() {
        let done = completion
        completion = nil
        done?(.finished)
    }
}

@MainActor
final class EnvHaptics: WhisperHaptics {
    private(set) var taps = 0
    func tap() { taps += 1 }
}

@MainActor
final class EnvAudioSession: AudioSessionConfiguring {
    enum Event: Equatable {
        case activate(WhisperAudioSessionConfiguration)
        case deactivate
    }
    let log: EnvEventLog?
    private(set) var events: [Event] = []
    private(set) var isActive = false

    init(log: EnvEventLog?) { self.log = log }

    func activate(_ configuration: WhisperAudioSessionConfiguration) throws {
        log?.record("audio.activate")
        events.append(.activate(configuration))
        isActive = true
    }
    func deactivate() {
        log?.record("audio.deactivate")
        events.append(.deactivate)
        isActive = false
    }
    var activations: Int { events.filter { $0 != .deactivate }.count }
}

/// Whisper fakes for one harness.
@MainActor
final class EnvWhisper {
    let route: EnvRoute
    let devices = InMemoryTrustedAudioDeviceStore()
    let speech = EnvSpeech()
    let haptics = EnvHaptics()
    let audio: EnvAudioSession
    let settings: InMemoryWhisperSettingsStore

    init(
        outputs: [AudioOutput] = [EnvRoute.wired], settings: WhisperSettings = WhisperSettings(),
        log: EnvEventLog? = nil
    ) {
        route = EnvRoute(outputs)
        audio = EnvAudioSession(log: log)
        self.settings = InMemoryWhisperSettingsStore(settings)
    }
}

/// Face ID stand-in that fails until `allow` is set (the app then stays locked).
final class EnvSwitchAuthenticator: Authenticating {
    let allow = Mutex(true)
    func authenticate(reason: String) async -> Bool { allow.withLock { $0 } }
}

extension EnvWhisper {

    var components: WhisperComponents {
        WhisperComponents(
            route: route, devices: devices, speech: speech, haptics: haptics, audioSession: audio,
            settings: settings)
    }
}

// MARK: - Tests

@MainActor
@Suite struct AppEnvironmentMemoryWhisperTests {
    static let alicePhone = AppEnvironmentWiringTests.alicePhone

    /// A digest whose only entry carries synthetic message excerpts for `handle`.
    static func excerptDigest(handle: String, now: Date) -> InteractionDigest {
        let messages = [
            InteractionDigest.DigestMessage(
                date: now.addingTimeInterval(-3_600), fromMe: false, text: "Synthetic: long run this weekend"),
            InteractionDigest.DigestMessage(
                date: now.addingTimeInterval(-7_200), fromMe: true, text: "Synthetic: good luck with training"
            ),
        ]
        return InteractionDigest(
            generatedAt: now,
            entries: [
                InteractionDigest.Entry(
                    handle: handle, lastMessageAt: messages[0].date, lastFromMeAt: messages[1].date,
                    lastFromThemAt: messages[0].date, messagesLast30Days: 2, messagesAllTime: 2,
                    awaitingMyReply: false, recentMessages: messages)
            ])
    }

    /// Synthetic Alice (confirmed, with a phone handle) and a saved digest with her excerpts.
    static func aliceWithExcerpts(_ h: EnvHarness) async throws -> Person {
        let alice = try await h.store.seedConfirmed("Synthetic Alice", vector: aliceVector)
        try await h.store.base.addIdentity(Identity(personID: alice.id, kind: .phone, value: alicePhone))
        try await h.store.base.saveDigest(excerptDigest(handle: alicePhone, now: Date()))
        return alice
    }

    // MARK: Memory refresher is a writer

    @Test func killSwitchCancelsAndAwaitsTheMemoryRefresher() async throws {
        let log = EnvEventLog()
        let gate = EnvGate()
        let generator = EnvHookGenerator(log: log, gate: gate)
        let h = try EnvHarness(hookGenerator: generator, log: log)
        _ = try await Self.aliceWithExcerpts(h)
        await h.environment.start()

        let refresh = try #require(h.environment.refreshMemoryHooks())
        try await waitUntil { log.count("generator.start") == 1 }

        let erase = Task {
            await h.environment.privacy.eraseEverything(typed: PrivacySettingsViewModel.eraseKeyword)
        }
        // The kill switch waits for the generation in flight: nothing erased yet.
        try await Task.sleep(for: .milliseconds(30))
        #expect(log.count("store.erase") == 0)
        gate.open()
        #expect(await erase.value)
        await refresh.value

        let eraseIndex = try #require(log.index("store.erase"))
        #expect(try #require(log.index("generator.end")) < eraseIndex)
        // Cancelled: the generated hooks were never written.
        #expect(log.count("store.replaceHooks") == 0)
        #expect(h.environment.memoryTask == nil)
        #expect(h.environment.eraseGeneration == 1)
    }

    @Test func forgetCancelsAndAwaitsTheMemoryRefresher() async throws {
        let log = EnvEventLog()
        let gate = EnvGate()
        let generator = EnvHookGenerator(log: log, gate: gate)
        let h = try EnvHarness(hookGenerator: generator, log: log)
        let alice = try await Self.aliceWithExcerpts(h)
        await h.environment.start()

        h.environment.refreshMemoryHooks()
        try await waitUntil { log.count("generator.start") == 1 }

        let forget = Task { try await h.environment.store.forget(alice.id) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(log.count("store.forget") == 0)
        gate.open()
        try await forget.value

        #expect(try #require(log.index("generator.end")) < (try #require(log.index("store.forget"))))
        #expect(log.count("store.replaceHooks") == 0)
        #expect(try await h.store.base.hooks(for: alice.id, now: Date()).isEmpty)
        #expect(h.environment.memoryTask == nil)
    }

    @Test func noRefreshStartsDuringAForget() async throws {
        let log = EnvEventLog()
        let generator = EnvHookGenerator(log: log)
        let h = try EnvHarness(hookGenerator: generator, log: log)
        let alice = try await Self.aliceWithExcerpts(h)
        await h.environment.start()
        let gate = EnvGate()
        h.store.forgetGate.withLock { $0 = gate }
        let forget = Task { try await h.environment.store.forget(alice.id) }
        try await waitUntil { log.count("store.forget") == 1 }

        #expect(h.environment.refreshMemoryHooks() == nil)
        gate.open()
        try await forget.value
        #expect(await generator.calls == 0)
    }

    // MARK: Digest import -> refresh -> labels

    @Test func digestImportSchedulesARefreshAndHooksReachTheLens() async throws {
        let log = EnvEventLog()
        let generator = EnvHookGenerator(log: log)
        let h = try EnvHarness(hookGenerator: generator, log: log)
        let alice = try await AppEnvironmentWiringTests.labeledAlice(h)
        let lens = try #require(h.environment.lens)
        #expect(await generator.calls == 0)

        let url = try h.digestFile(Self.excerptDigest(handle: Self.alicePhone, now: Date()))
        #expect(await h.environment.importDigest(url: url))
        // The import scheduled the refresh (it runs off the main actor).
        let refresh = try #require(h.environment.memoryTask)
        await refresh.value

        #expect(await generator.calls == 1)
        let hooks = try await h.store.base.hooks(for: alice.id, now: Date())
        #expect(hooks.map(\.text) == ["Training for a marathon"])
        #expect(hooks.allSatisfy { $0.source == .onDeviceSummary })
        // Hook change -> on-screen labels rebuilt within the same session.
        try await h.deliverFrames {
            lens.items.first?.label?.chips.contains {
                $0.kind == .memoryHook && $0.text == "Training for a marathon"
            } == true
        }
    }

    @Test func activeSchedulesARefresh() async throws {
        let log = EnvEventLog()
        let generator = EnvHookGenerator(log: log)
        let h = try EnvHarness(hookGenerator: generator, log: log)
        let alice = try await Self.aliceWithExcerpts(h)
        await h.environment.start()
        await h.environment.scenePhaseChanged(to: .active).value
        await h.environment.memoryTask?.value
        #expect(await generator.calls == 1)
        #expect(try await h.store.base.hooks(for: alice.id, now: Date()).count == 1)
    }

    @Test func hooksReachTheRankerOnTheLensAndThePersonDetail() async throws {
        let h = try EnvHarness()
        let alice = try await AppEnvironmentWiringTests.labeledAlice(h)
        let lens = try #require(h.environment.lens)
        let revision = h.environment.peopleRevision
        #expect(
            h.environment.recognizedPeople == [
                LensRecognizedPerson(id: alice.id, displayName: "Synthetic Alice")
            ])

        // A hook written through the app store (e.g. a Moment) invalidates the on-screen label.
        try await h.environment.store.addHook(
            MemoryHook(personID: alice.id, text: "Synthetic moment note", source: .moment))
        #expect(h.environment.peopleRevision > revision)
        try await h.deliverFrames {
            lens.items.first?.label?.chips.contains {
                $0.kind == .memoryHook && $0.text == "Synthetic moment note"
            }
                == true
        }

        let detail = h.environment.makePersonDetailModel(for: alice.id)
        await detail.load()
        #expect(detail.labelPreview?.chips.contains { $0.text == "Synthetic moment note" } == true)
        #expect(detail.labelPreview == lens.items.first?.label)
        let label = await h.environment.label(for: alice)
        #expect(label.chips.contains { $0.text == "Synthetic moment note" })
    }

    // MARK: Whisper

    @Test func whisperUsesPlaybackMixWithOthersOnlyWhileEnabledAndRunning() async throws {
        let whisper = EnvWhisper()
        let h = try EnvHarness(whisper: whisper)
        _ = try await AppEnvironmentWiringTests.labeledAlice(h)
        // Off by default: no session, no speech, no haptics.
        #expect(!h.environment.whisperSettings.isEnabled)
        #expect(whisper.audio.events.isEmpty)
        #expect(whisper.speech.spoken.isEmpty)
        #expect(whisper.haptics.taps == 0)

        h.environment.setWhisperSettings(WhisperSettings(isEnabled: true, speaksChip: false))
        #expect(whisper.audio.events == [.activate(.whisper)])
        #expect(WhisperAudioSessionConfiguration.whisper.category == .playback)
        #expect(WhisperAudioSessionConfiguration.whisper.mixesWithOthers)
        #expect(whisper.settings.load().isEnabled)
        try await h.deliverFrames { whisper.speech.spoken == ["Synthetic Alice"] }
        #expect(whisper.haptics.taps == 1)

        // Turning it off cancels the utterance and releases the session.
        h.environment.setWhisperSettings(WhisperSettings(isEnabled: false))
        #expect(whisper.speech.stops >= 1)
        #expect(whisper.audio.events.last == .deactivate)
        #expect(!whisper.audio.isActive)
    }

    @Test func whisperNeverSpeaksThroughTheSpeaker() async throws {
        let whisper = EnvWhisper(outputs: [EnvRoute.speaker], settings: WhisperSettings(isEnabled: true))
        let h = try EnvHarness(whisper: whisper)
        _ = try await AppEnvironmentWiringTests.labeledAlice(h)
        var frames = 0
        try await h.deliverFrames {
            frames += 1
            return frames > 20
        }
        #expect(whisper.audio.isActive)
        #expect(whisper.speech.spoken.isEmpty)
        #expect(h.environment.whisper.pendingDeviceConfirmation == nil)
    }

    @Test func bluetoothNeedsConfirmationBoundToThePrompt() async throws {
        let whisper = EnvWhisper(outputs: [EnvRoute.bluetooth], settings: WhisperSettings(isEnabled: true))
        let h = try EnvHarness(whisper: whisper)
        _ = try await AppEnvironmentWiringTests.labeledAlice(h)
        try await h.deliverFrames { h.environment.whisper.pendingDeviceConfirmation != nil }
        #expect(h.environment.whisper.pendingDeviceConfirmation == EnvRoute.bluetooth)
        #expect(whisper.speech.spoken.isEmpty)

        h.environment.confirmWhisperDevice(true)
        #expect(whisper.devices.isTrusted(EnvRoute.bluetooth.portUID))
        #expect(h.environment.whisper.pendingDeviceConfirmation == nil)
        try await h.deliverFrames { whisper.speech.spoken.first?.hasPrefix("Synthetic Alice") == true }
    }

    @Test func whisperStopsOnBackgroundAndNeverRunsWhileLocked() async throws {
        let whisper = EnvWhisper(settings: WhisperSettings(isEnabled: true, speaksChip: false))
        let auth = EnvSwitchAuthenticator()
        let h = try EnvHarness(lockTimeout: 0, whisper: whisper, authenticator: auth)
        _ = try await AppEnvironmentWiringTests.labeledAlice(h)
        try await h.deliverFrames { whisper.speech.spoken == ["Synthetic Alice"] }
        #expect(whisper.audio.isActive)

        await h.environment.scenePhaseChanged(to: .background).value
        #expect(whisper.speech.stops >= 1)
        #expect(!whisper.audio.isActive)
        #expect(!h.environment.isWhisperAudioActive)

        // Back to the foreground after the (zero) lock timeout with Face ID failing: locked, so
        // neither the lens nor Whisper comes back, and nothing is spoken.
        auth.allow.withLock { $0 = false }
        await h.environment.scenePhaseChanged(to: .active).value
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.environment.appLock.isLocked)
        #expect(!h.environment.isLensRunning)
        #expect(!whisper.audio.isActive)
        #expect(whisper.audio.activations == 1)
        h.environment.lensItemsChanged(h.environment.lens?.items ?? [])
        #expect(whisper.speech.spoken == ["Synthetic Alice"])

        // Unlocked: a new lens session, so Alice may be announced again.
        auth.allow.withLock { $0 = true }
        await h.unlock()
        try await waitUntil { h.environment.isLensRunning && whisper.audio.isActive }
        try await h.deliverFrames { whisper.speech.spoken == ["Synthetic Alice", "Synthetic Alice"] }
    }

    @Test func killSwitchStopsWhisper() async throws {
        let log = EnvEventLog()
        let whisper = EnvWhisper(settings: WhisperSettings(isEnabled: true), log: log)
        let h = try EnvHarness(whisper: whisper, log: log)
        _ = try await AppEnvironmentWiringTests.labeledAlice(h)
        try await h.deliverFrames { !whisper.speech.spoken.isEmpty }
        let stopsBefore = whisper.speech.stops
        #expect(await h.environment.privacy.eraseEverything(typed: PrivacySettingsViewModel.eraseKeyword))

        // Speech was cancelled and the session released before the erase, and Whisper did not
        // come back until the erase was over (the lens tab is still visible, so it restarts after).
        #expect(whisper.speech.stops > stopsBefore)
        let events = log.events
        let eraseIndex = try #require(events.firstIndex(of: "store.erase"))
        let lastDeactivate = try #require(events[..<eraseIndex].lastIndex(of: "audio.deactivate"))
        #expect(!events[lastDeactivate..<eraseIndex].contains("audio.activate"))
    }

    // MARK: #68 follow-ups

    @Test func failedEraseDoesNotBumpTheGenerationOrDropImports() async throws {
        let h = try EnvHarness(contacts: [
            ContactRecord(identifier: "synthetic-contact-9", givenName: "Synthetic", familyName: "Kim")
        ])
        let alice = try await h.store.seedConfirmed("Synthetic Alice", vector: aliceVector)
        await h.environment.start()
        h.store.failErase.withLock { $0 = true }
        // A forget holds both imports back; a (failing) kill switch then starts before they run.
        let gate = EnvGate()
        h.store.forgetGate.withLock { $0 = gate }
        let forget = Task { try await h.environment.store.forget(alice.id) }
        try await waitUntil { h.log.count("store.forget") == 1 }
        let contacts = Task { try await h.environment.importContacts() }
        let url = try h.digestFile(AppEnvironmentWiringTests.digest(handle: Self.alicePhone, now: Date()))
        let digest = Task { await h.environment.importDigest(url: url) }
        try await Task.sleep(for: .milliseconds(10))
        let erase = Task {
            await h.environment.privacy.eraseEverything(typed: PrivacySettingsViewModel.eraseKeyword)
        }
        try await Task.sleep(for: .milliseconds(10))
        gate.open()
        try await forget.value

        #expect(await erase.value == false)
        #expect(h.environment.eraseGeneration == 0)
        // Not dropped: the RootView "all data was erased" message is never shown for them.
        #expect(try await contacts.value.created == 1)
        #expect(await digest.value)
        #expect(try await h.store.latestDigest() != nil)

        // A successful erase does bump it.
        h.store.failErase.withLock { $0 = false }
        #expect(await h.environment.privacy.eraseEverything(typed: PrivacySettingsViewModel.eraseKeyword))
        #expect(h.environment.eraseGeneration == 1)
    }

    @Test func scanResumeIsDroppedWhenAKillSwitchRanDuringTheCursorRead() async throws {
        let h = try EnvHarness(permissions: [.photos: .granted], onboardingCompleted: true)
        await h.environment.start()  // no cursor yet: no scan
        try await h.store.base.setScanCursor("synthetic-cursor")
        let gate = EnvGate()
        h.store.scanCursorGate.withLock { $0 = gate }

        let resume = Task { await h.environment.resumePhotoScanIfConsented() }
        try await waitUntil { h.log.count("store.scanCursor.parked") == 1 }
        #expect(await h.environment.privacy.eraseEverything(typed: PrivacySettingsViewModel.eraseKeyword))
        gate.open()
        await resume.value

        try await Task.sleep(for: .milliseconds(30))
        #expect(h.log.count("scan.list") == 0)
        #expect(h.environment.scanStatus == .idle)
    }

    @Test func scanResumeStillRunsWithoutAKillSwitch() async throws {
        let h = try EnvHarness(permissions: [.photos: .granted], onboardingCompleted: true)
        await h.environment.start()
        try await h.store.base.setScanCursor("synthetic-cursor")
        await h.environment.resumePhotoScanIfConsented()
        try await waitUntil { h.log.count("scan.list") == 1 }
    }

    // MARK: Settings persistence

    @Test func whisperSettingsPersistInUserDefaults() throws {
        let suite = "halo.tests.whisper.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsWhisperSettingsStore(defaults: defaults)
        #expect(store.load() == WhisperSettings())
        #expect(!store.load().isEnabled)
        store.save(WhisperSettings(isEnabled: true, speaksChip: false))
        #expect(
            UserDefaultsWhisperSettingsStore(defaults: defaults).load()
                == WhisperSettings(isEnabled: true, speaksChip: false))
    }
}

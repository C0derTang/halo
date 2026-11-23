import Foundation
import HaloCore
import HaloUI
import Synchronization
import Testing

@testable import HaloAppCore

/// Never-speaker safety net and Moment-close audio ordering (#69 review). Synthetic only.
@MainActor
@Suite struct AppEnvironmentWhisperSafetyTests {
    /// Dictation stand-in that behaves like `OnDeviceSpeechTranscriber`'s teardown: when the stream
    /// ends it LATE-deactivates the shared audio session (after a main-actor hop).
    final class TeardownTranscriber: SpeechTranscribing {
        let log: EnvEventLog
        let audio: EnvAudioSession
        init(log: EnvEventLog, audio: EnvAudioSession) {
            self.log = log
            self.audio = audio
        }
        var isOnDeviceAvailable: Bool { get async { true } }
        func transcribe() -> AsyncThrowingStream<String, Error> {
            let log = self.log
            let audio = self.audio
            return AsyncThrowingStream { continuation in
                log.record("dictation.started")
                continuation.yield("Synthetic dictated words")
                continuation.onTermination = { _ in
                    log.record("dictation.stopped")
                    Task { @MainActor in audio.deactivate() }
                }
            }
        }
    }

    @Test func routeChangeWhileWhisperMayNotRunCancelsSpeechOnANonPrivateRoute() async throws {
        let whisper = EnvWhisper(settings: WhisperSettings(isEnabled: true, speaksChip: false))
        let h = try EnvHarness(whisper: whisper)
        _ = try await AppEnvironmentWiringTests.labeledAlice(h)
        try await h.deliverFrames { whisper.speech.spoken == ["Synthetic Alice"] }  // still playing

        // The window between "may not run" and the lens actually stopping (e.g. the lock hop).
        h.environment.isMomentOpen = true
        #expect(!h.environment.whisperMayRun)
        let stops = whisper.speech.stops

        // Still private (wired): nothing to cancel, nothing asked.
        h.environment.whisperRouteChanged()
        #expect(whisper.speech.stops == stops)

        // Headphones pulled, unconfirmed Bluetooth now: speech is cancelled, no question asked.
        whisper.route.set([EnvRoute.bluetooth])
        h.environment.whisperRouteChanged()
        #expect(whisper.speech.stops == stops + 1)
        #expect(h.environment.whisper.pendingDeviceConfirmation == nil)

        // Speaker: cancelled too (nothing playing any more, so no second stop is needed).
        whisper.route.set([EnvRoute.speaker])
        h.environment.whisperRouteChanged()
        #expect(h.environment.whisper.pendingDeviceConfirmation == nil)
        #expect(!h.environment.whisperRouteIsPrivate)
    }

    @Test func trustedBluetoothCountsAsPrivate() async throws {
        let whisper = EnvWhisper(outputs: [EnvRoute.bluetooth])
        let h = try EnvHarness(whisper: whisper)
        #expect(!h.environment.whisperRouteIsPrivate)
        whisper.devices.trust(EnvRoute.bluetooth.portUID)
        #expect(h.environment.whisperRouteIsPrivate)
        whisper.route.set([EnvRoute.wired, EnvRoute.speaker])
        #expect(!h.environment.whisperRouteIsPrivate)
    }

    @Test func lockEngagingOnActiveStopsTheLensSynchronously() async throws {
        let auth = EnvSwitchAuthenticator()
        let whisper = EnvWhisper(settings: WhisperSettings(isEnabled: true))
        let h = try EnvHarness(lockTimeout: 0, whisper: whisper, authenticator: auth)
        _ = try await AppEnvironmentWiringTests.labeledAlice(h)
        // `.inactive` keeps the lens; then the (zero) timeout elapses in the background.
        _ = h.environment.scenePhaseChanged(to: .inactive)
        #expect(h.environment.isLensRunning)
        h.environment.appLock.scenePhaseChanged(to: .background)
        auth.allow.withLock { $0 = false }

        // `.active` engages the lock: the lens and Whisper are off before any hop.
        let task = h.environment.scenePhaseChanged(to: .active)
        #expect(h.environment.appLock.isLocked)
        #expect(!h.environment.isLensRunning)
        #expect(!whisper.audio.isActive)
        await task.value
    }

    @Test func closingAMomentStopsDictationBeforeWhisperTakesTheSessionBack() async throws {
        let log = EnvEventLog()
        let whisper = EnvWhisper(settings: WhisperSettings(isEnabled: true), log: log)
        let transcriber = TeardownTranscriber(log: log, audio: whisper.audio)
        let h = try EnvHarness(whisper: whisper, log: log, speechTranscriber: transcriber)
        _ = try await AppEnvironmentWiringTests.labeledAlice(h)
        #expect(whisper.audio.isActive)

        let model = h.environment.makeMomentsModel()
        h.environment.momentSheetOpened(model)
        #expect(!whisper.audio.isActive)
        await model.prepareDictation()
        model.startDictation()
        try await waitUntil { log.count("dictation.started") == 1 && !model.text.isEmpty }

        // Swipe-down: the sheet's binding goes nil and the screen reports the close.
        h.environment.momentSheetClosed()
        #expect(!model.isDictating)
        #expect(h.environment.openMoment == nil)

        // Dictation stopped before Whisper re-activated; its late teardown deactivated the shared
        // session, and the delayed resync took it back.
        try await waitUntil(timeout: .seconds(3)) {
            let events = log.events
            guard let stopped = events.firstIndex(of: "dictation.stopped") else { return false }
            return events[stopped...].contains("audio.deactivate") && events.last == "audio.activate"
        }
        let stopped = try #require(log.index("dictation.stopped"))
        let reactivated = try #require(log.events.lastIndex(of: "audio.activate"))
        #expect(stopped < reactivated)
        #expect(whisper.audio.isActive)
        #expect(h.environment.isWhisperAudioActive)
        #expect(h.environment.whisperMayRun)
    }
}

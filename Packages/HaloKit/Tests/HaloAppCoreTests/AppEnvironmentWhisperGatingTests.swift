import CoreGraphics
import Foundation
import HaloCore
import HaloUI
import Testing

@testable import HaloAppCore

/// Whisper gating review fixes (#69): no device question while Whisper is off or stopped, pause
/// while a Moment is open, feed only on label/state changes, and the kill switch erases Whisper's
/// own data. Synthetic devices and people only.
@MainActor
@Suite struct AppEnvironmentWhisperGatingTests {
    @Test func whisperOffRouteChangeNeverAsksAboutADevice() async throws {
        let whisper = EnvWhisper(outputs: [EnvRoute.bluetooth])  // Whisper off (default)
        let h = try EnvHarness(whisper: whisper)
        _ = try await AppEnvironmentWiringTests.labeledAlice(h)

        // New AirPods connect (or dictation switches the session): a route change arrives.
        h.environment.whisperRouteChanged()
        var frames = 0
        try await h.deliverFrames {
            frames += 1
            return frames > 10
        }
        #expect(h.environment.whisper.pendingDeviceConfirmation == nil)
        #expect(h.environment.whisperDevicePrompt == nil)
        #expect(whisper.audio.events.isEmpty)
    }

    @Test func deviceQuestionIsWithdrawnWhenWhisperIsDisabledOrTheLensStops() async throws {
        let whisper = EnvWhisper(outputs: [EnvRoute.bluetooth], settings: WhisperSettings(isEnabled: true))
        let h = try EnvHarness(whisper: whisper)
        _ = try await AppEnvironmentWiringTests.labeledAlice(h)
        try await h.deliverFrames { h.environment.whisperDevicePrompt != nil }

        h.environment.setWhisperSettings(WhisperSettings(isEnabled: false))
        #expect(h.environment.whisper.pendingDeviceConfirmation == nil)
        #expect(h.environment.whisperDevicePrompt == nil)
        // A route change while off does not bring it back.
        h.environment.whisperRouteChanged()
        #expect(h.environment.whisper.pendingDeviceConfirmation == nil)

        // On again: asked again (not answered, so not remembered either way).
        h.environment.setWhisperSettings(WhisperSettings(isEnabled: true))
        try await h.deliverFrames { h.environment.whisperDevicePrompt == EnvRoute.bluetooth }
        #expect(!whisper.devices.isTrusted(EnvRoute.bluetooth.portUID))

        h.environment.lensDisappeared()
        #expect(h.environment.whisper.pendingDeviceConfirmation == nil)
    }

    @Test func anOpenMomentPausesWhisperAndClosingRestoresTheSession() async throws {
        let whisper = EnvWhisper(settings: WhisperSettings(isEnabled: true, speaksChip: false))
        let h = try EnvHarness(whisper: whisper)
        _ = try await AppEnvironmentWiringTests.labeledAlice(h)
        try await h.deliverFrames { whisper.speech.spoken == ["Synthetic Alice"] }
        let stops = whisper.speech.stops
        #expect(whisper.audio.activations == 1)

        h.environment.momentSheetOpened(h.environment.makeMomentsModel())
        #expect(!h.environment.whisperMayRun)
        #expect(whisper.speech.stops > stops)
        #expect(!whisper.audio.isActive)
        #expect(!h.environment.isWhisperAudioActive)
        // Dictation's `.record` route change and new frames are ignored while it is open.
        whisper.route.set([EnvRoute.bluetooth])
        h.environment.whisperRouteChanged()
        h.environment.lensItemsChanged(h.environment.lens?.items ?? [])
        #expect(h.environment.whisper.pendingDeviceConfirmation == nil)
        whisper.route.set([EnvRoute.wired])

        // Closed: our `.playback` + `.mixWithOthers` session is set up again.
        h.environment.momentSheetClosed()
        #expect(whisper.audio.activations == 2)
        #expect(whisper.audio.events.last == .activate(.whisper))
        #expect(h.environment.isWhisperAudioActive)
        #expect(h.environment.whisperMayRun)
    }

    @Test func whisperIsFedOnLabelOrStateChangesNotBoxMoves() async throws {
        let whisper = EnvWhisper(settings: WhisperSettings(isEnabled: true, speaksChip: false))
        let h = try EnvHarness(whisper: whisper)
        _ = try await AppEnvironmentWiringTests.labeledAlice(h)
        let label = try #require(h.environment.lens?.items.first?.label)
        func item(x: Double, state: HologramState = .stable) -> LensOverlayItem {
            LensOverlayItem(
                trackID: TrackID(1), rect: CGRect(x: x, y: 0.3, width: 0.2, height: 0.2), state: state,
                label: label)
        }
        let t0 = Date(timeIntervalSince1970: 1_900_000_000)

        h.environment.lastWhisperFeed = nil
        h.environment.lensItemsChanged([item(x: 0.1)], now: t0)
        #expect(h.environment.lastWhisperFeed?.at == t0)
        // Only the box moved: not fed again.
        h.environment.lensItemsChanged([item(x: 0.2)], now: t0.addingTimeInterval(0.1))
        #expect(h.environment.lastWhisperFeed?.at == t0)
        // The state changed: fed.
        let t1 = t0.addingTimeInterval(0.2)
        h.environment.lensItemsChanged([item(x: 0.2, state: .lost)], now: t1)
        #expect(h.environment.lastWhisperFeed?.at == t1)
        // Unchanged, but the re-feed interval passed (retry backoffs can elapse): fed.
        let t2 = t1.addingTimeInterval(AppEnvironment.whisperRefeedInterval + 0.1)
        h.environment.lensItemsChanged([item(x: 0.3, state: .lost)], now: t2)
        #expect(h.environment.lastWhisperFeed?.at == t2)
    }

    @Test func killSwitchErasesWhisperTogglesAndTrustedDevices() async throws {
        let whisper = EnvWhisper(outputs: [EnvRoute.bluetooth], settings: WhisperSettings(isEnabled: true))
        whisper.devices.trust("synthetic-old-device")
        let h = try EnvHarness(whisper: whisper)
        _ = try await AppEnvironmentWiringTests.labeledAlice(h)
        try await h.deliverFrames { h.environment.whisperDevicePrompt != nil }
        h.environment.confirmWhisperDevice(true)
        #expect(whisper.devices.isTrusted(EnvRoute.bluetooth.portUID))

        #expect(await h.environment.privacy.eraseEverything(typed: PrivacySettingsViewModel.eraseKeyword))

        #expect(h.environment.whisperSettings == WhisperSettings())
        #expect(!h.environment.whisperSettings.isEnabled)
        #expect(whisper.settings.load() == WhisperSettings())
        #expect(!whisper.devices.isTrusted(EnvRoute.bluetooth.portUID))
        #expect(!whisper.devices.isTrusted("synthetic-old-device"))
        #expect(h.environment.whisperDevicePrompt == nil)
    }

    @Test func failedKillSwitchKeepsWhisperData() async throws {
        let whisper = EnvWhisper(settings: WhisperSettings(isEnabled: true))
        whisper.devices.trust("synthetic-kept-device")
        let h = try EnvHarness(whisper: whisper)
        await h.environment.start()
        h.store.failErase.withLock { $0 = true }
        #expect(
            await h.environment.privacy.eraseEverything(typed: PrivacySettingsViewModel.eraseKeyword) == false
        )
        #expect(h.environment.whisperSettings.isEnabled)
        #expect(whisper.devices.isTrusted("synthetic-kept-device"))
    }

    @Test func userDefaultsTrustedDevicesCanBeErased() throws {
        let suite = "halo.tests.whisper.devices.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsTrustedAudioDeviceStore(defaults: defaults)
        store.trust("synthetic-device")
        #expect(store.isTrusted("synthetic-device"))
        store.removeAll()
        #expect(!UserDefaultsTrustedAudioDeviceStore(defaults: defaults).isTrusted("synthetic-device"))
    }
}

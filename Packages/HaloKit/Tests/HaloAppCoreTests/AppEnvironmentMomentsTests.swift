import Foundation
import HaloCore
import HaloUI
import Testing

@testable import HaloAppCore

/// The Lens "Moment" hookup (#69 + #70). Synthetic people and notes only; no microphone.
@MainActor
@Suite struct AppEnvironmentMomentsTests {
    /// On-device dictation stand-in: reports on-device support, yields one synthetic transcript.
    final class FakeTranscriber: SpeechTranscribing {
        var isOnDeviceAvailable: Bool { get async { true } }
        func transcribe() -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.yield("Synthetic dictated note") }
        }
    }

    @Test func buttonNeedsARecognizedConfirmedPerson() async throws {
        let h = try EnvHarness()
        await h.environment.start()
        await h.unlock()
        await h.environment.lensAppeared()
        // Lens running, nobody recognized.
        #expect(h.environment.momentsAllowed)
        #expect(h.environment.recognizedPeople.isEmpty)
        #expect(!h.environment.canStartMoment)

        let alice = try await h.store.seedConfirmed("Synthetic Alice", vector: aliceVector)
        try await h.environment.store.upsert(alice)  // identity change -> gallery rebuild
        try await h.deliverFrames { h.environment.canStartMoment }
        #expect(h.environment.recognizedPeople.map(\.id) == [alice.id])
    }

    @Test func momentSavesAHookThroughTheAppStoreAndRefreshesTheLabel() async throws {
        let h = try EnvHarness()
        let alice = try await AppEnvironmentWiringTests.labeledAlice(h)
        let lens = try #require(h.environment.lens)
        let model = h.environment.makeMomentsModel(for: h.environment.recognizedPeople)
        #expect(model.people.map(\.id) == [alice.id])
        #expect(model.isSelected(alice.id))  // one person: preselected

        let revision = h.environment.peopleRevision
        model.setText("Synthetic: talked about the new bakery")
        #expect(await model.save())

        let hooks = try await h.store.base.hooks(for: alice.id, now: Date())
        #expect(hooks.map(\.source) == [.moment])
        #expect(h.log.count("store.addHook") == 1)
        #expect(h.environment.peopleRevision > revision)
        try await h.deliverFrames {
            lens.items.first?.label?.chips.contains { $0.text.contains("bakery") } == true
        }
    }

    @Test func sanitizerRejectsLinksAndPhoneNumbers() async throws {
        let h = try EnvHarness()
        let alice = try await AppEnvironmentWiringTests.labeledAlice(h)
        let model = h.environment.makeMomentsModel(for: h.environment.recognizedPeople)
        model.setText("Synthetic: call me at +1 202 555 0188 or see example.com")
        #expect(await model.save() == false)
        #expect(try await h.store.base.hooks(for: alice.id, now: Date()).isEmpty)
    }

    @Test func liveConfirmationCheckBlocksAForgottenPerson() async throws {
        let h = try EnvHarness()
        let alice = try await AppEnvironmentWiringTests.labeledAlice(h)
        let model = h.environment.makeMomentsModel(for: h.environment.recognizedPeople)
        model.setText("Synthetic: note written while being forgotten")
        try await h.environment.store.forget(alice.id)
        #expect(await model.save() == false)
        #expect(h.log.count("store.addHook") == 0)
    }

    @Test func liveConfirmationCheckBlocksAnUnconfirmedPerson() async throws {
        let h = try EnvHarness()
        var alice = try await AppEnvironmentWiringTests.labeledAlice(h)
        let model = h.environment.makeMomentsModel(for: h.environment.recognizedPeople)
        alice.confirmed = false
        try await h.store.base.upsert(alice)
        model.setText("Synthetic: note for someone no longer confirmed")
        #expect(await model.save() == false)
        #expect(try await h.store.base.hooks(for: alice.id, now: Date()).isEmpty)
    }

    @Test func dictationUsesTheInjectedOnDeviceTranscriber() async throws {
        let without = try EnvHarness()
        let none = without.environment.makeMomentsModel(for: [])
        await none.prepareDictation()
        #expect(!none.isDictationAvailable)

        let h = try EnvHarness(speechTranscriber: FakeTranscriber())
        let model = h.environment.makeMomentsModel(for: [])
        await model.prepareDictation()
        #expect(model.isDictationAvailable)
    }

    @Test func momentsCloseOnBackgroundAndLock() async throws {
        let auth = EnvSwitchAuthenticator()
        let h = try EnvHarness(lockTimeout: 0, authenticator: auth)
        _ = try await AppEnvironmentWiringTests.labeledAlice(h)
        #expect(h.environment.momentsAllowed)

        await h.environment.scenePhaseChanged(to: .background).value
        #expect(!h.environment.momentsAllowed)

        auth.allow.withLock { $0 = false }
        await h.environment.scenePhaseChanged(to: .active).value
        #expect(h.environment.appLock.isLocked)
        #expect(!h.environment.momentsAllowed)
        #expect(!h.environment.canStartMoment)

        auth.allow.withLock { $0 = true }
        await h.unlock()
        try await waitUntil { h.environment.momentsAllowed }
    }
}

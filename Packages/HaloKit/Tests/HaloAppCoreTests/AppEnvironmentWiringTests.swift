import Foundation
import HaloBridgeKit
import HaloCore
import HaloImport
import HaloLens
import HaloUI
import Synchronization
import Testing

@testable import HaloAppCore

/// The final app hookup (#55): one camera, writers stopped before forget / erase, names off the
/// screen at once, onboarding consent, digest import refresh, shared ranker / normalizer / key.
/// Synthetic people, handles and vectors only.
@MainActor
@Suite struct AppEnvironmentWiringTests {
    static let alicePhone = "+12025550123"

    /// A started environment whose lens is on screen and labels Synthetic Alice.
    static func labeledAlice(_ h: EnvHarness) async throws -> Person {
        let alice = try await h.store.seedConfirmed("Synthetic Alice", vector: aliceVector)
        try await h.store.base.addIdentity(Identity(personID: alice.id, kind: .phone, value: alicePhone))
        await h.environment.start()
        await h.environment.lensAppeared()
        let lens = try #require(h.environment.lens)
        try await h.deliverFrames { lens.items.first?.label?.title == "Synthetic Alice" }
        return alice
    }

    static func digest(handle: String, now: Date) -> InteractionDigest {
        InteractionDigest(
            generatedAt: now,
            entries: [
                InteractionDigest.Entry(
                    handle: handle, lastMessageAt: now.addingTimeInterval(-2 * 86_400), lastFromMeAt: nil,
                    lastFromThemAt: nil, messagesLast30Days: 3, messagesAllTime: 9, awaitingMyReply: false)
            ])
    }

    // MARK: One camera

    @Test func theLensDrivesTheEnvironmentsOneCamera() async throws {
        let h = try EnvHarness()
        await h.environment.start()
        let lens = try #require(h.environment.lens)
        #expect(lens.recognitionAvailable)

        await h.environment.lensAppeared()
        #expect(h.log.count("camera.start") == 1)
        #expect(h.camera.isRunning)
        #expect(h.camera.hasFrameHandler)
        #expect(h.environment.isLensRunning)

        // Background stops that same camera; coming back restarts it because the lens is visible.
        await h.environment.scenePhaseChanged(to: .background).value
        #expect(!h.camera.isRunning)
        #expect(!h.environment.isLensRunning)
        await h.environment.scenePhaseChanged(to: .active).value
        try await waitUntil { h.camera.isRunning && h.environment.isLensRunning }

        // Leaving the tab stops it, and `.active` no longer restarts it.
        h.environment.lensDisappeared()
        #expect(!h.camera.isRunning)
        await h.environment.scenePhaseChanged(to: .active).value
        try await Task.sleep(for: .milliseconds(20))
        #expect(!h.camera.isRunning)
    }

    @Test func missingModelRunsThePreviewWithoutRecognition() async throws {
        let h = try EnvHarness(modelMissing: true)
        await h.environment.start()
        let lens = try #require(h.environment.lens)
        #expect(!lens.recognitionAvailable)
        await h.environment.lensAppeared()
        #expect(h.camera.isRunning)
        // No frame ever reaches a pipeline: there is none.
        #expect(!h.camera.hasFrameHandler)
    }

    // MARK: Kill switch

    @Test func killSwitchCancelsAndAwaitsScanContactsAndDigestBeforeErase() async throws {
        let h = try EnvHarness(blockingContacts: true)
        _ = try await Self.labeledAlice(h)
        try await h.startBlockedScan()

        // Contacts import parked in the address-book fetch.
        let contacts = Task { try await h.environment.importContacts() }
        try await waitUntil { h.log.count("contacts.fetch") == 1 }

        // Digest import parked inside its store write.
        let gate = EnvGate()
        h.store.saveDigestGate.withLock { $0 = gate }
        let url = try h.digestFile(Self.digest(handle: Self.alicePhone, now: Date()))
        let digest = Task { await h.environment.importDigest(url: url) }
        try await waitUntil { h.log.count("store.saveDigest") == 1 }

        let erase = Task {
            await h.environment.privacy.eraseEverything(typed: PrivacySettingsViewModel.eraseKeyword)
        }
        // The kill switch is waiting for the digest write to finish: nothing erased yet.
        try await waitUntil { h.log.count("contacts.returned") == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.log.count("store.erase") == 0)
        gate.open()
        #expect(await erase.value)
        await digest.value

        let eraseIndex = try #require(h.log.index("store.erase"))
        #expect(try #require(h.log.index("scan.partialWrite")) < eraseIndex)
        #expect(try #require(h.log.index("contacts.cancelled")) < eraseIndex)
        #expect(try #require(h.log.index("contacts.returned")) < eraseIndex)
        // The digest write in flight either landed before the erase or was refused (GRDB refuses a
        // write from a cancelled task); it never lands after it.
        if let saved = h.log.index("store.saveDigest.done") { #expect(saved < eraseIndex) }
        if case .succeeded = h.environment.digestImport.status {
            #expect(h.log.index("store.saveDigest.done") != nil)
        }
        #expect(try #require(h.log.index("camera.stop")) < eraseIndex)
        // The cancelled contacts import never wrote: its first write was refused.
        #expect(h.log.count("store.upsert") == 0)
        await #expect(throws: CancellationError.self) { _ = try await contacts.value }
        // Nothing survived the erase.
        #expect(try await h.store.allPeople().isEmpty)
        #expect(try await h.store.latestDigest() == nil)
        #expect(h.environment.lens?.items.allSatisfy { $0.label == nil } ?? true)
    }

    @Test func importsRequestedDuringAForgetWaitForIt() async throws {
        let h = try EnvHarness(contacts: [
            ContactRecord(identifier: "synthetic-contact-2", givenName: "Synthetic", familyName: "Robin")
        ])
        let alice = try await h.store.seedConfirmed("Synthetic Alice", vector: aliceVector)
        await h.environment.start()
        let gate = EnvGate()
        h.store.forgetGate.withLock { $0 = gate }
        let forget = Task { try await h.environment.store.forget(alice.id) }
        try await waitUntil { h.log.count("store.forget") == 1 }

        let contacts = Task { try await h.environment.importContacts() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.log.count("store.upsert") == 0)

        gate.open()
        try await forget.value
        let result = try await contacts.value
        #expect(result.created == 1)
        #expect(try #require(h.log.index("store.forget")) < (try #require(h.log.index("store.upsert"))))
    }

    // MARK: Forget

    @Test func forgetFromPersonDetailCallsSetMatcherAndForgetLabel() async throws {
        let h = try EnvHarness()
        let alice = try await Self.labeledAlice(h)
        let lens = try #require(h.environment.lens)
        let pipeline = try #require(h.environment.lensPipeline)

        let detail = h.environment.makePersonDetailModel(for: alice.id)
        await detail.load()
        #expect(await detail.confirmForget())

        // setMatcher: the lens gallery no longer contains Alice, and live tracks lost the name.
        #expect(h.environment.activeGallery?.match(aliceVector, policy: .conservative) == .unknown)
        #expect(await pipeline.currentTracks.allSatisfy { $0.identity == .unknown })
        // forgetLabel: no name on screen, and even a stale `.known` result is never labeled again.
        #expect(lens.items.allSatisfy { $0.label == nil })
        lens.apply([
            LensTrack(
                trackID: TrackID(99), smoothedBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                identity: .known(alice.id, similarity: 0.9, margin: 0.3), state: .stable)
        ])
        await lens.settle()
        #expect(lens.items.allSatisfy { $0.label == nil })
        #expect(try await h.store.person(alice.id) == nil)
    }

    @Test func failedForgetKeepsTheLabel() async throws {
        let h = try EnvHarness()
        let alice = try await Self.labeledAlice(h)
        let lens = try #require(h.environment.lens)
        h.store.failForget.withLock { $0 = true }

        await #expect(throws: EnvStoreFailure.self) { try await h.environment.store.forget(alice.id) }

        // The forget did not happen, so forgetLabel must not have run: she can be labeled again.
        try await h.deliverFrames { lens.items.first?.label?.title == "Synthetic Alice" }
    }

    // MARK: Digest import

    @Test func digestImportRefreshesGalleryAndLabels() async throws {
        let h = try EnvHarness()
        _ = try await Self.labeledAlice(h)
        let lens = try #require(h.environment.lens)
        #expect(lens.items.first?.label?.chips.isEmpty == true)
        let revision = h.environment.peopleRevision

        let url = try h.digestFile(Self.digest(handle: Self.alicePhone, now: Date()))
        await h.environment.importDigest(url: url)

        guard case .succeeded(let report) = h.environment.digestImport.status else {
            Issue.record("import failed: \(String(describing: h.environment.digestImport.message))")
            return
        }
        #expect(report.resolvedPeople == 1)
        #expect(h.environment.peopleRevision > revision)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // The label is rebuilt with the digest within the same lens session (without the refresh,
        // the session's cached label, with no chips, would stay up until the lens restarts).
        try await h.deliverFrames {
            lens.items.first?.label?.chips.contains { $0.kind == .lastInteraction } == true
        }
    }

    // MARK: Shared ranker / normalizer / key

    @Test func lensLabelsUseStoreWideIdentities() async throws {
        let h = try EnvHarness()
        let a = Person(displayName: "Synthetic A", confirmed: true)
        let b = Person(displayName: "Synthetic B", confirmed: true)
        try await h.store.base.upsert(a)
        try await h.store.base.upsert(b)
        try await h.store.base.addIdentity(Identity(personID: a.id, kind: .phone, value: Self.alicePhone))
        try await h.store.base.addIdentity(
            Identity(personID: b.id, kind: .imessageHandle, value: "(202) 555-0123"))
        let lensStore = LensLabelStore(base: h.environment.store)
        #expect(try await lensStore.identities(for: a.id).count == 2)
    }

    @Test func peopleListUsesTheSharedNormalizer() async throws {
        let h = try EnvHarness(region: "GB")
        let robin = Person(displayName: "Synthetic Robin", confirmed: true)
        try await h.store.base.upsert(robin)
        try await h.store.base.addIdentity(Identity(personID: robin.id, kind: .phone, value: "+447700900123"))
        let now = Date()
        try await h.store.base.saveDigest(Self.digest(handle: "07700 900123", now: now))

        let list = h.environment.makePeopleListModel()
        await list.load()
        #expect(list.rows.first?.lastInteraction != nil)
    }

    @Test func pairingAndDigestImportShareOneKey() async throws {
        let h = try EnvHarness()
        let pairing = h.environment.makePairingModel()
        #expect(await pairing.unlock())
        let key = try #require(try PairingKey.load(from: h.keyStore))
        #expect(pairing.payload == key.pairingPayload)
    }

    // MARK: Onboarding consent

    @Test func onboardingAdaptersDoNothingWithoutConsent() async throws {
        let h = try EnvHarness(
            contacts: [ContactRecord(identifier: "synthetic-contact-3", givenName: "Synthetic")],
            permissions: [.camera: .denied, .contacts: .denied, .photos: .denied])
        await h.environment.start()
        let model = h.environment.makeOnboardingModel()
        // Building the model and its adapters starts nothing.
        #expect(h.log.count("scan.list") == 0)

        model.acceptPrivacyExplanation()
        await model.allowCurrentStep()  // camera: denied
        await model.allowCurrentStep()  // contacts: denied
        await model.allowCurrentStep()  // photos: denied
        #expect(model.step == .bridge)
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.log.count("store.upsert") == 0)
        #expect(h.log.count("scan.list") == 0)
        #expect(h.environment.scanStatus == .idle)
        #expect(try await h.store.allPeople().isEmpty)
    }

    @Test func onboardingAdaptersRunTheRealJobsAfterConsent() async throws {
        let h = try EnvHarness(
            contacts: [
                ContactRecord(identifier: "synthetic-contact-4", givenName: "Synthetic", familyName: "Kim")
            ],
            permissions: [.camera: .granted, .contacts: .granted, .photos: .limited])
        await h.environment.start()
        let model = h.environment.makeOnboardingModel()
        model.acceptPrivacyExplanation()
        await model.allowCurrentStep()  // camera
        #expect(h.log.count("store.upsert") == 0)
        await model.allowCurrentStep()  // contacts: the real ContactsImporter ran
        #expect(model.importedContactCount == 1)
        let people = try await h.store.allPeople()
        #expect(people.map(\.displayName) == ["Synthetic Kim"])
        #expect(people.allSatisfy { !$0.confirmed })
        #expect(h.log.count("scan.list") == 0)
        await model.allowCurrentStep()  // photos: the environment's PhotoScanJob started
        try await waitUntil { h.log.count("scan.list") == 1 }
        #expect(h.environment.scanStatus == .scanning)
        #expect(h.permissions.requested == [.camera, .contacts, .photos])
    }

    @Test func settingsRetriesRunOnlyWithAccess() async throws {
        let denied = try EnvHarness(
            contacts: [ContactRecord(identifier: "synthetic-contact-5", givenName: "Synthetic")],
            permissions: [.contacts: .denied, .photos: .denied])
        await denied.environment.start()
        #expect(try await denied.environment.importContactsWithConsent() == nil)
        #expect(await denied.environment.scanPhotosWithConsent() == false)
        try await Task.sleep(for: .milliseconds(20))
        #expect(denied.log.count("store.upsert") == 0)
        #expect(denied.log.count("scan.list") == 0)

        let granted = try EnvHarness(
            contacts: [ContactRecord(identifier: "synthetic-contact-6", givenName: "Synthetic")],
            permissions: [.contacts: .granted, .photos: .granted])
        await granted.environment.start()
        #expect(try await granted.environment.importContactsWithConsent() == 1)
        #expect(await granted.environment.scanPhotosWithConsent())
        try await waitUntil { granted.log.count("scan.list") == 1 }
    }

    @Test func scanProgressStreamEndsWhenRecognitionIsUnavailable() async throws {
        let h = try EnvHarness(modelMissing: true, permissions: [.photos: .granted])
        await h.environment.start()
        var updates: [PhotoScanProgress] = []
        for await p in EnvironmentPhotoScanning(environment: h.environment).start() { updates.append(p) }
        #expect(updates.isEmpty)
        #expect(h.environment.scanStatus == .unavailable)
    }

    @Test func scanProgressMapsToOnboardingProgress() {
        var p = ScanProgress()
        p.assetsScanned = 5
        p.assetsSkipped = 2
        p.assetsUnavailable = 1
        p.assetsFailed = 1
        p.facesEmbedded = 40
        #expect(EnvironmentPhotoScanning.progress(p) == PhotoScanProgress(processed: 9, total: nil))
        p.phase = .finished
        #expect(EnvironmentPhotoScanning.progress(p).isFinished)
    }

    @Test(arguments: [
        (true, PermissionStatus.granted, true),
        (true, PermissionStatus.limited, true),
        (true, PermissionStatus.denied, false),
        (true, PermissionStatus.notDetermined, false),
        (false, PermissionStatus.granted, false),
    ])
    func scanResumesOnLaunchOnlyWithConsent(completed: Bool, photos: PermissionStatus, resumes: Bool)
        async throws
    {
        let h = try EnvHarness(permissions: [.photos: photos], onboardingCompleted: completed)
        await h.environment.start()
        if resumes {
            try await waitUntil { h.log.count("scan.list") == 1 }
            #expect(h.environment.scanStatus == .scanning)
        } else {
            try await Task.sleep(for: .milliseconds(30))
            #expect(h.log.count("scan.list") == 0)
        }
        // Never prompts on launch.
        #expect(h.permissions.requested.isEmpty)
        #expect(h.environment.needsOnboarding == !completed)
    }
}

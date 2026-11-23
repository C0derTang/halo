import Foundation
import HaloBridgeKit
import HaloCore
import HaloImport
import HaloLens
import HaloUI
import HaloVision
import SwiftUI
import Synchronization
import Testing

@testable import HaloAppCore

@MainActor
@Suite struct AppEnvironmentTests {
    // MARK: Kill switch

    @Test func killSwitchCancelsScanAndStopsLensBeforeErase() async throws {
        let h = try EnvHarness()
        try await h.store.seedConfirmed("Synthetic Alice", vector: aliceVector)
        await h.environment.start()
        #expect(h.environment.galleryPersonCount == 1)
        try await h.environment.startLens()
        #expect(h.environment.isLensRunning)
        try await h.startBlockedScan()
        let oldEnrollment = h.environment.enrollment
        let generation = h.environment.resetGeneration

        #expect(await h.environment.privacy.eraseEverything(typed: PrivacySettingsViewModel.eraseKeyword))

        let erase = try #require(h.log.index("store.erase"))
        let cancelled = try #require(h.log.index("scan.cancelled"))
        let cameraStop = try #require(h.log.index("camera.stop"))
        #expect(cancelled < erase)
        #expect(cameraStop < erase)
        // The scan's write after noticing the cancel (partial-batch save) lands before the erase,
        // so the erase wipes it instead of the scan re-inserting it afterwards.
        let partialWrite = try #require(h.log.index("scan.partialWrite"))
        #expect(partialWrite < erase)
        // In-memory state is reset: no gallery, no running lens or scan, fresh triage model.
        #expect(h.environment.galleryPersonCount == 0)
        #expect(h.environment.activeGallery?.personCount == 0)
        #expect(!h.environment.isLensRunning)
        #expect(h.environment.scanStatus == .idle)
        #expect(h.environment.enrollment !== oldEnrollment)
        #expect(h.environment.resetGeneration == generation + 1)
        #expect(try await h.store.allPeople().isEmpty)
        #expect(try await h.store.unassignedEmbeddings(space: envSpace).isEmpty)
    }

    @Test func killSwitchDoesNotResumeTheScan() async throws {
        let h = try EnvHarness()
        await h.environment.start()
        try await h.startBlockedScan()
        #expect(await h.environment.privacy.eraseEverything(typed: PrivacySettingsViewModel.eraseKeyword))
        await h.environment.scenePhaseChanged(to: .active).value
        #expect(h.log.count("scan.list") == 1)
        #expect(h.environment.scanStatus == .idle)
    }

    // MARK: Forget

    @Test func forgetHandsTheLensAGalleryWithoutThatPerson() async throws {
        let h = try EnvHarness()
        let alice = try await h.store.seedConfirmed("Synthetic Alice", vector: aliceVector)
        let bob = try await h.store.seedConfirmed("Synthetic Bob", vector: bobVector)
        await h.environment.start()
        let before = try #require(h.environment.activeGallery)
        #expect(before.personCount == 2)
        #expect(Self.knownID(before.match(aliceVector, policy: .conservative)) == alice.id)

        // The live lens labels Alice's face.
        let pipeline = try #require(h.environment.lensPipeline)
        let frames = EnvFrames()
        var output: [LensTrack] = []
        for i in 0..<4 { output = await pipeline.process(frames.frame(at: Double(i) * 0.3)) }
        #expect(Self.knownID(output.first?.identity) == alice.id)

        await h.environment.privacy.load()
        h.environment.privacy.requestForget(alice.id)
        #expect(await h.environment.privacy.confirmForget())
        await h.environment.settleGallery()

        let after = try #require(h.environment.activeGallery)
        #expect(after.personCount == 1)
        #expect(after.match(aliceVector, policy: .conservative) == .unknown)
        #expect(Self.knownID(after.match(bobVector, policy: .conservative)) == bob.id)
        #expect(h.environment.galleryPersonCount == 1)

        // setMatcher reached the pipeline: Alice's face is no longer labeled, now or later.
        #expect(await pipeline.currentTracks.allSatisfy { $0.identity == .unknown })
        for i in 4..<10 {
            output = await pipeline.process(frames.frame(at: Double(i) * 0.3))
            #expect(Self.knownID(output.first?.identity) == nil)
        }
        // Bob is still recognized.
        h.embedder.set(bobVector)
        for i in 10..<14 { output = await pipeline.process(frames.frame(at: Double(i) * 0.3)) }
        #expect(Self.knownID(output.first?.identity) == bob.id)
    }

    @Test func forgetPausesTheScanFirstAndResumesItAfter() async throws {
        let h = try EnvHarness()
        let alice = try await h.store.seedConfirmed("Synthetic Alice", vector: aliceVector)
        await h.environment.start()
        try await h.startBlockedScan()

        try await h.environment.store.forget(alice.id)

        let forget = try #require(h.log.index("store.forget"))
        let cancelled = try #require(h.log.index("scan.cancelled"))
        #expect(cancelled < forget)
        #expect(try #require(h.log.index("scan.partialWrite")) < forget)
        try await waitUntil { h.log.count("scan.list") == 2 }
        #expect(h.environment.scanStatus == .scanning)
    }

    @Test func failedForgetKeepsThePersonRecognizable() async throws {
        let h = try EnvHarness()
        let alice = try await h.store.seedConfirmed("Synthetic Alice", vector: aliceVector)
        await h.environment.start()
        h.store.failForget.withLock { $0 = true }

        await #expect(throws: EnvStoreFailure.self) { try await h.environment.store.forget(alice.id) }
        await h.environment.settleGallery()

        // Alice still exists, so the exclusion is lifted and she is in the rebuilt gallery.
        #expect(h.environment.galleryPersonCount == 1)
        #expect(
            Self.knownID(h.environment.activeGallery?.match(aliceVector, policy: .conservative)) == alice.id)
    }

    @Test func confirmingAClusterAddsThePersonToTheGallery() async throws {
        let h = try EnvHarness()
        await h.environment.start()
        #expect(h.environment.galleryPersonCount == 0)
        let face = FaceEmbedding(space: envSpace, vector: aliceVector, source: .photoLibrary, quality: 0.9)
        try await h.store.base.addEmbeddings([face])
        try await h.store.base.replaceClusters([
            ClusterRecord(id: "c1", memberIDs: [face.id], representativeID: face.id, cohesion: 1)
        ])
        let person = Person(displayName: "Synthetic Alice")
        try await h.environment.store.upsert(person)
        let revision = h.environment.peopleRevision

        try await h.environment.store.confirm(cluster: "c1", as: person.id)
        await h.environment.settleGallery()

        #expect(h.environment.galleryPersonCount == 1)
        #expect(
            Self.knownID(h.environment.activeGallery?.match(aliceVector, policy: .conservative)) == person.id)
        #expect(h.environment.peopleRevision > revision)
    }

    @Test func digestImportRefreshes() async throws {
        let h = try EnvHarness()
        await h.environment.start()
        let revision = h.environment.peopleRevision
        try await h.environment.store.saveDigest(InteractionDigest(generatedAt: Date(), entries: []))
        #expect(h.environment.peopleRevision > revision)
    }

    // MARK: Lifecycle

    @Test func backgroundPausesScanStopsCameraAndFlushes() async throws {
        let h = try EnvHarness()
        await h.environment.start()
        try await h.environment.startLens()
        try await h.startBlockedScan()

        await h.environment.scenePhaseChanged(to: .background).value

        let cancelled = try #require(h.log.index("scan.cancelled"))
        let flush = try #require(h.log.index("store.flush"))
        #expect(cancelled < flush)
        #expect(try #require(h.log.index("scan.partialWrite")) < flush)
        #expect(h.log.count("camera.stop") >= 1)
        #expect(!h.environment.isLensRunning)
        #expect(h.environment.scanStatus == .paused)
        #expect(h.environment.appLock.isCovered)

        // Coming back resumes the paused scan from its cursor.
        await h.environment.scenePhaseChanged(to: .active).value
        try await waitUntil { h.log.count("scan.list") == 2 }
        #expect(h.environment.scanStatus == .scanning)
    }

    @Test func lensDoesNotStartInTheBackground() async throws {
        let h = try EnvHarness()
        await h.environment.start()
        await h.environment.scenePhaseChanged(to: .background).value
        try await h.environment.startLens()
        #expect(!h.environment.isLensRunning)
        #expect(h.log.count("camera.start") == 0)
    }

    @Test func activeAppliesTheLockRules() async throws {
        let h = try EnvHarness()
        #expect(h.environment.appLock.isLocked)
        await h.environment.scenePhaseChanged(to: .active).value
        // The fake authenticator succeeds; the auto-prompt unlocks.
        try await waitUntil { !h.environment.appLock.isLocked }
        await h.environment.scenePhaseChanged(to: .inactive).value
        #expect(h.environment.appLock.isCovered)
        await h.environment.scenePhaseChanged(to: .active).value
        #expect(!h.environment.appLock.isCovered)
    }

    @Test func forgetDuringModelLoadNeverPublishesThatPerson() async throws {
        let modelGate = EnvGate()
        let h = try EnvHarness(embedderGate: modelGate)
        let alice = try await h.store.seedConfirmed("Synthetic Alice", vector: aliceVector)
        let bob = try await h.store.seedConfirmed("Synthetic Bob", vector: bobVector)
        let start = Task { await h.environment.start() }

        // Forget Alice while the model loads, and hold the store deletion so the gallery read made
        // by the refresher built at startup still sees her.
        let forgetGate = EnvGate()
        h.store.forgetGate.withLock { $0 = forgetGate }
        let forget = Task { try await h.environment.store.forget(alice.id) }
        try await waitUntil { h.log.count("store.forget") == 1 }
        modelGate.open()
        await start.value

        let atStart = try #require(h.environment.activeGallery)
        #expect(atStart.match(aliceVector, policy: .conservative) == .unknown)
        #expect(Self.knownID(atStart.match(bobVector, policy: .conservative)) == bob.id)

        forgetGate.open()
        try await forget.value
        await h.environment.settleGallery()
        #expect(h.environment.activeGallery?.match(aliceVector, policy: .conservative) == .unknown)
        #expect(h.environment.galleryPersonCount == 1)
    }

    @Test func overlappingStartsLeaveTheLensRunning() async throws {
        let cameraGate = EnvGate()
        let h = try EnvHarness(cameraStartGate: cameraGate)
        await h.environment.start()
        let first = Task { try await h.environment.startLens() }
        let second = Task { try await h.environment.startLens() }
        try await waitUntil { h.log.count("camera.start") == 2 }

        cameraGate.open()
        try await first.value
        try await second.value

        #expect(h.environment.isLensRunning)
        #expect(h.log.count("camera.stop") == 0)
        let camera = try #require(h.environment.camera as? EnvFakeCamera)
        #expect(camera.isRunning)
    }

    @Test func stopDuringCameraStartWins() async throws {
        let cameraGate = EnvGate()
        let h = try EnvHarness(cameraStartGate: cameraGate)
        await h.environment.start()
        let start = Task { try await h.environment.startLens() }
        try await waitUntil { h.log.count("camera.start") == 1 }

        h.environment.stopLens()
        cameraGate.open()
        try await start.value

        #expect(!h.environment.isLensRunning)
        // Stopped by stopLens, and again by startLens once the camera came up late.
        #expect(h.log.count("camera.stop") == 2)
        #expect(h.log.events.last == "camera.stop")
        #expect(try #require(h.environment.camera as? EnvFakeCamera).isRunning == false)
    }

    @Test func everyActiveRetriesTheGalleryRebuild() async throws {
        let h = try EnvHarness()
        await h.environment.start()
        #expect(h.environment.galleryPersonCount == 0)
        // Written behind the environment's back (stands in for a rebuild whose read failed).
        try await h.store.seedConfirmed("Synthetic Alice", vector: aliceVector)
        await h.environment.settleGallery()
        #expect(h.environment.galleryPersonCount == 0)

        await h.environment.scenePhaseChanged(to: .active).value
        await h.environment.settleGallery()
        #expect(h.environment.galleryPersonCount == 1)
    }

    // MARK: Missing model

    @Test func missingModelDegradesToRecognitionUnavailable() async throws {
        let h = try EnvHarness(modelMissing: true)
        try await h.store.seedConfirmed("Synthetic Alice", vector: aliceVector)
        await h.environment.start()

        #expect(h.environment.recognition == .unavailable)
        #expect(!h.environment.recognitionAvailable)
        #expect(h.environment.lensPipeline == nil)
        h.environment.startPhotoScan()
        #expect(h.environment.scanStatus == .unavailable)
        #expect(h.log.count("scan.list") == 0)
        // Everything else still works.
        await h.environment.privacy.load()
        #expect(h.environment.privacy.items.count == 1)
        try await h.environment.startLens()
        await h.environment.scenePhaseChanged(to: .background).value
        #expect(h.log.count("store.flush") == 1)
    }

    // MARK: Store availability

    @Test func storeOpenedLateRebuildsScreens() async throws {
        let log = EnvEventLog()
        let real = try EnvRecordingStore(log: log)
        let attempts = Mutex(0)
        let h = try EnvHarness(openStore: {
            let n = attempts.withLock {
                $0 += 1
                return $0
            }
            if n == 1 { throw AppStoreError.unavailable }
            return real
        })
        #expect(!h.environment.isStoreAvailable)
        let generation = h.environment.resetGeneration
        await h.environment.scenePhaseChanged(to: .active).value
        #expect(h.environment.isStoreAvailable)
        #expect(h.environment.resetGeneration == generation + 1)
    }

    @Test func concurrentCallersOpenTheStoreOnce() async throws {
        let log = EnvEventLog()
        let real = try EnvRecordingStore(log: log)
        let opens = Mutex(0)
        let lazy = LazyStore(open: {
            opens.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.02)  // a slow open (file setup + migrations)
            return real
        })
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try? await lazy.allPeople() }
            }
        }
        #expect(opens.withLock { $0 } == 1)
        #expect(lazy.isOpen)
    }

    @Test func unavailableStoreThrowsInsteadOfFallingBack() async throws {
        let h = try EnvHarness(openStore: { throw AppStoreError.unavailable })
        await #expect(throws: AppStoreError.unavailable) { try await h.environment.store.allPeople() }
        #expect(await h.environment.store.flushPendingErasure())
    }

    // MARK: Shared normalizer

    @Test func unknownRegionIsZZNeverUS() throws {
        let h = try EnvHarness(region: nil)
        #expect(!h.environment.handleNormalizer.isKnownRegion)
        #expect(h.environment.handleNormalizer.normalize("(202) 555-0123") == "2025550123")
        #expect(h.environment.handleNormalization.normalizer.defaultCountryCode == "")
        #expect(h.environment.handleNormalization.e164("(202) 555-0123") == nil)
    }

    @Test func importerResolverAndRankerShareOneNormalizer() async throws {
        let contact = ContactRecord(
            identifier: "synthetic-contact-1", givenName: "Synthetic", familyName: "Robin",
            nickname: "", organization: "", jobTitle: "", birthday: nil, phones: ["07700 900123"],
            emails: [], thumbnail: nil)
        let h = try EnvHarness(region: "GB", contacts: [contact])
        #expect(h.environment.handleNormalizer.defaultCountryCode == "44")
        #expect(h.environment.handleNormalization.normalizer.defaultCountryCode == "44")

        // Importer: the national number is stored in the GB-normalized E.164 form.
        _ = try await h.environment.makeContactsImporter().importContacts()
        let person = try #require(try await h.environment.store.allPeople().first)
        let phones = try await h.environment.store.identities(for: person.id).filter { $0.kind == .phone }
        #expect(phones.map(\.value) == ["+447700900123"])

        // Resolver: an international handle resolves to the same person.
        #expect(try await h.environment.handleResolver.resolve(handle: "+44 7700 900123") == person.id)
        #expect(try await h.environment.handleResolver.resolve(handle: "07700900123") == person.id)

        // Ranker: a digest entry in national format attributes to them.
        let now = Date()
        try await h.environment.store.saveDigest(
            InteractionDigest(
                generatedAt: now,
                entries: [
                    InteractionDigest.Entry(
                        handle: "07700 900123", lastMessageAt: now.addingTimeInterval(-2 * 86_400),
                        lastFromMeAt: nil, lastFromThemAt: nil, messagesLast30Days: 3, messagesAllTime: 9,
                        awaitingMyReply: false)
                ]))
        let label = await h.environment.label(for: person, now: now)
        #expect(label.chips.contains { $0.kind == .lastInteraction })
    }

    @Test func labelUsesStoreWideIdentitiesForTheAmbiguityGuard() async throws {
        let h = try EnvHarness(region: "US")
        let a = Person(displayName: "Synthetic A")
        let b = Person(displayName: "Synthetic B")
        try await h.store.base.upsert(a)
        try await h.store.base.upsert(b)
        // A shared landline: stored as an iMessage handle for both people.
        try await h.store.base.addIdentity(Identity(personID: a.id, kind: .phone, value: "+12025550123"))
        try await h.store.base.addIdentity(
            Identity(personID: b.id, kind: .imessageHandle, value: "(202) 555-0123"))
        let now = Date()
        try await h.store.base.saveDigest(
            InteractionDigest(
                generatedAt: now,
                entries: [
                    InteractionDigest.Entry(
                        handle: "+12025550123", lastMessageAt: now, lastFromMeAt: nil, lastFromThemAt: nil,
                        messagesLast30Days: 1, messagesAllTime: 1, awaitingMyReply: true)
                ]))
        #expect(try await h.environment.storeWideIdentities().count == 2)
        let label = await h.environment.label(for: a, now: now)
        #expect(!label.chips.contains { $0.kind == .lastInteraction || $0.kind == .openLoop })
    }

    // MARK: Helpers

    static func knownID(_ result: MatchResult?) -> PersonID? {
        if case .known(let id, _, _) = result { return id }
        return nil
    }
}

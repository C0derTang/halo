import CoreGraphics
import Foundation
import HaloCore
import HaloVision
import SwiftUI
import Testing

@testable import HaloAppCore

/// Google Photos import: Cancel before the task exists, background vs device lock, the importer's restricted
/// store and the systemic-failure predicate. Synthetic fakes only.
@MainActor
@Suite struct GooglePhotosLifecycleTests {
    // MARK: Cancel before the import task exists

    @Test func cancelWhileWaitingForTheModelNeverStartsTheImport() async throws {
        let log = EnvEventLog()
        let fake = EnvFakeGooglePhotos(log: log, mode: .succeed(faces: 1, gate: nil))
        let modelGate = EnvGate()
        let h = try EnvHarness(embedderGate: modelGate, log: log, googlePhotos: fake)
        let model = h.environment.googleImport
        let run = Task { await model.start() }
        try await waitUntil { h.environment.googleRunPending }
        #expect(h.environment.googleTask == nil)

        model.cancel()
        modelGate.open()
        await run.value

        // Never started: no sign-in sheet later, nothing written.
        #expect(log.count("google.import") == 0)
        #expect(model.state == .idle)
        #expect(!h.environment.googleRunPending)
        // The next import runs normally.
        await model.start()
        #expect(log.count("google.import") == 1)
    }

    @Test func cancelWhileWaitingForAForgetNeverStartsTheImport() async throws {
        let (h, _) = try GooglePhotosAppTests.harness(.succeed(faces: 1, gate: nil))
        let alice = try await h.store.seedConfirmed("Synthetic Alice", vector: aliceVector)
        await h.environment.start()
        let gate = EnvGate()
        h.store.forgetGate.withLock { $0 = gate }
        let forget = Task { try await h.environment.store.forget(alice.id) }
        try await waitUntil { h.log.count("store.forget") == 1 }
        let model = h.environment.googleImport
        let run = Task { await model.start() }
        try await waitUntil { h.environment.googleRunPending }

        model.cancel()
        gate.open()
        try await forget.value
        await run.value
        #expect(h.log.count("google.import") == 0)
        #expect(model.state == .idle)
    }

    // MARK: Background and device lock

    @Test func backgroundNeverStopsTheImport() async throws {
        // Picking happens in Google Photos, outside Halo: the import must survive backgrounding,
        // in every phase (waiting for the picker and writing).
        let picked = EnvGate()
        let (h, _) = try GooglePhotosAppTests.harness(.scanUntilCancelled(gate: picked))
        await h.environment.start()
        let model = h.environment.googleImport
        let run = Task { await model.start() }
        try await waitUntil { model.state == .waitingForPicker }

        await h.environment.scenePhaseChanged(to: .background).value
        #expect(h.environment.googleTask != nil)
        picked.open()
        try await waitUntil { h.log.count("google.write") >= 2 }
        #expect(h.log.count("google.returned") == 0)
        await h.environment.scenePhaseChanged(to: .active).value
        #expect(model.state == .scanning)

        model.cancel()
        await run.value
        #expect(model.state == .idle)
    }

    @Test func deviceLockStopsAnImportThatIsWriting() async throws {
        let (h, _) = try GooglePhotosAppTests.harness(.scanUntilCancelled(gate: nil))
        await h.environment.start()
        let model = h.environment.googleImport
        let run = Task { await model.start() }
        try await waitUntil { h.log.count("google.write") >= 2 }

        await h.environment.protectedDataWillBecomeUnavailable()
        // Stopped and awaited before the files lock: nothing writes afterwards.
        #expect(h.log.count("google.returned") == 1)
        let writes = h.log.count("store.addEmbeddings")
        await run.value
        #expect(h.environment.googleTask == nil)
        #expect(model.state == .error("Import paused (phone locked). Run it again to continue."))
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.log.count("store.addEmbeddings") == writes)

        // Running it again works.
        let again = Task { await model.start() }
        try await waitUntil { h.log.count("google.import") == 2 }
        model.cancel()
        await again.value
    }

    @Test func deviceLockWhileWaitingToStartNeverStartsTheImport() async throws {
        let log = EnvEventLog()
        let fake = EnvFakeGooglePhotos(log: log, mode: .succeed(faces: 1, gate: nil))
        let modelGate = EnvGate()
        let h = try EnvHarness(embedderGate: modelGate, log: log, googlePhotos: fake)
        let model = h.environment.googleImport
        let run = Task { await model.start() }
        try await waitUntil { h.environment.googleRunPending }

        await h.environment.protectedDataWillBecomeUnavailable()
        modelGate.open()
        await run.value
        #expect(log.count("google.import") == 0)
        #expect(model.state == .error(GooglePhotosImportModel.pausedMessage))
    }

    @Test func deviceLockWithoutAnImportDoesNothing() async throws {
        let (h, _) = try GooglePhotosAppTests.harness(.succeed(faces: 1, gate: nil))
        await h.environment.start()
        await h.environment.protectedDataWillBecomeUnavailable()
        await h.environment.googleImport.start()
        guard case .done = h.environment.googleImport.state else {
            Issue.record("expected done, got \(h.environment.googleImport.state)")
            return
        }
    }

    @Test func pausedMessageCarriesNoIds() {
        let text = GooglePhotosImportModel.message(
            for: GooglePhotosAppError.pausedForDeviceLock, userCancelled: false)
        #expect(text == GooglePhotosImportModel.pausedMessage)
        #expect(text?.contains("://") == false)
    }

    // MARK: Restricted store

    @Test func importStoreRefusesEveryWriteButFacesAndSuggestions() async throws {
        let log = EnvEventLog()
        let base = try EnvRecordingStore(log: log)
        let alice = try await base.seedConfirmed("Synthetic Alice", vector: aliceVector)
        try await base.setScanCursor("synthetic-apple-cursor")
        let store = CancellableImportStore(base: base)
        let refused: [(String, () async throws -> Void)] = [
            ("forget", { try await store.forget(alice.id) }),
            ("upsert", { try await store.upsert(Person(displayName: "Synthetic Late")) }),
            (
                "addIdentity",
                {
                    try await store.addIdentity(
                        Identity(personID: alice.id, kind: .phone, value: "+12025550100"))
                }
            ),
            (
                "removeIdentity",
                {
                    try await store.removeIdentity(
                        Identity(personID: alice.id, kind: .phone, value: "+12025550100"))
                }
            ),
            ("confirm", { try await store.confirm(cluster: "synthetic", as: alice.id) }),
            ("deleteEmbeddings", { try await store.deleteEmbeddings(ids: [UUID()]) }),
            ("setScanCursor", { try await store.setScanCursor(nil) }),
            (
                "saveDigest",
                { try await store.saveDigest(InteractionDigest(generatedAt: Date(), entries: [])) }
            ),
        ]
        for (name, write) in refused {
            await #expect(throws: ImportStoreError.notAllowed, "\(name)") { try await write() }
        }
        #expect(log.count("store.forget") == 0)
        #expect(log.count("store.upsert") == 0)
        #expect(try await base.person(alice.id) != nil)
        #expect(try await base.scanCursor() == "synthetic-apple-cursor")

        // What an importer does write still lands.
        let face = EnvFakeGooglePhotos.face(1, space: envSpace)
        try await store.addEmbeddings([face])
        try await store.replaceClusters([
            ClusterRecord(id: "synthetic", memberIDs: [face.id], representativeID: face.id, cohesion: 1)
        ])
        #expect(try await base.clusters().count == 1)
    }

    // MARK: Systemic failures

    @Test func systemicFailurePredicateMatchesTheScan() async throws {
        let isSystemic = GooglePhotosServices.isRecognitionUnavailable
        #expect(isSystemic(DeferredFaceEmbedder.NotLoaded()))
        #expect(isSystemic(HaloVisionError.modelNotFound(URL(fileURLWithPath: "/nonexistent"))))
        #expect(!isSystemic(HaloVisionError.preprocessingFailed))
        #expect(!isSystemic(CancellationError()))

        let (h, fake) = try GooglePhotosAppTests.harness(.succeed(faces: 1, gate: nil))
        _ = h
        let services = try #require(fake.services)
        #expect(services.isSystemicFailure(DeferredFaceEmbedder.NotLoaded()))
        #expect(!services.isSystemicFailure(EnvStoreFailure()))
    }
}

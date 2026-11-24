import CoreGraphics
import Foundation
import HaloCore
import HaloImport
import HaloUI
import Synchronization
import Testing

@testable import HaloAppCore

/// App side of the Google Photos import (#81): the kill switch and forget stop the importer like
/// every other writer, it never runs alongside the Apple Photos scan, imported faces are suggestions
/// only, thumbnails come from the on-device copy, and the screen shows fixed strings only.
/// Synthetic fakes only: no network, no Google ids or URLs, no real faces.
@MainActor
@Suite struct GooglePhotosAppTests {
    static func harness(_ mode: EnvFakeGooglePhotos.Mode, configured: Bool = true, modelMissing: Bool = false)
        throws -> (EnvHarness, EnvFakeGooglePhotos)
    {
        let log = EnvEventLog()
        let fake = EnvFakeGooglePhotos(log: log, configured: configured, mode: mode)
        let h = try EnvHarness(modelMissing: modelMissing, log: log, googlePhotos: fake)
        return (h, fake)
    }

    static func googleFaces(_ h: EnvHarness) async throws -> [FaceEmbedding] {
        try await h.store.base.unassignedEmbeddings(space: envSpace).filter { $0.source == .googlePhotos }
    }

    // MARK: Kill switch (load-bearing)

    @Test func killSwitchCancelsAwaitsAndErasesAGoogleImportWaitingInThePicker() async throws {
        let (h, fake) = try Self.harness(.blockUntilCancelled)
        await h.environment.start()
        let model = h.environment.googleImport
        let run = Task { await model.start() }
        try await waitUntil { model.state == .waitingForPicker }

        let erase = Task {
            await h.environment.privacy.eraseEverything(typed: PrivacySettingsViewModel.eraseKeyword)
        }
        #expect(await erase.value)
        await run.value

        let eraseIndex = try #require(h.log.index("store.erase"))
        // Cancelled, its tokens and photos erased, and finished, all before the store erase.
        #expect(try #require(h.log.index("google.cancelled")) < eraseIndex)
        #expect(try #require(h.log.index("google.eraseAll")) < eraseIndex)
        #expect(try #require(h.log.index("google.returned")) < eraseIndex)
        // Its late write was refused (the task was cancelled), never landed.
        #expect(h.log.count("google.lateWrite.refused") == 1)
        #expect(h.log.count("google.lateWrite") == 0)
        #expect(h.log.count("store.addEmbeddings") == 0)
        #expect(try await Self.googleFaces(h).isEmpty)
        #expect(fake.isErased)
        #expect(h.environment.googleTask == nil)
        // A fresh, signed-out screen.
        #expect(model.state == .idle)
        #expect(!model.isSignedIn)
    }

    @Test func killSwitchStopsAGoogleImportThatIsWritingFaces() async throws {
        let (h, fake) = try Self.harness(.writeLoop)
        await h.environment.start()
        let model = h.environment.googleImport
        let run = Task { await model.start() }
        try await waitUntil { h.log.count("google.write") >= 3 }

        #expect(await h.environment.privacy.eraseEverything(typed: PrivacySettingsViewModel.eraseKeyword))
        await run.value

        let eraseIndex = try #require(h.log.index("store.erase"))
        #expect(try #require(h.log.index("google.returned")) < eraseIndex)
        // Every write that reached the store happened before the erase.
        let lastWrite = try #require(h.log.events.lastIndex(of: "store.addEmbeddings"))
        #expect(lastWrite < eraseIndex)
        #expect(fake.isErased)
        // Nothing lands afterwards either.
        try await Task.sleep(for: .milliseconds(30))
        #expect(try await Self.googleFaces(h).isEmpty)
        #expect(h.log.events.lastIndex(of: "store.addEmbeddings") == lastWrite)
        #expect(model.state == .idle)
    }

    @Test func googleImportRequestedBeforeAKillSwitchIsDropped() async throws {
        let (h, _) = try Self.harness(.succeed(faces: 2, gate: nil))
        let alice = try await h.store.seedConfirmed("Synthetic Alice", vector: aliceVector)
        await h.environment.start()
        // A forget holds the import back; a kill switch then starts before it may run.
        let gate = EnvGate()
        h.store.forgetGate.withLock { $0 = gate }
        let forget = Task { try await h.environment.store.forget(alice.id) }
        try await waitUntil { h.log.count("store.forget") == 1 }
        let run = Task { try await h.environment.runGooglePhotosImport { _ in } }
        try await Task.sleep(for: .milliseconds(10))
        let erase = Task {
            await h.environment.privacy.eraseEverything(typed: PrivacySettingsViewModel.eraseKeyword)
        }
        try await Task.sleep(for: .milliseconds(10))
        gate.open()
        _ = try? await forget.value
        #expect(await erase.value)
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(h.log.count("google.import") == 0)
        #expect(try await Self.googleFaces(h).isEmpty)
    }

    @Test func eraseAllFailureIsRetriedAfterTheStoreErase() async throws {
        let log = EnvEventLog()
        let fake = EnvFailingEraseGooglePhotos(log: log)
        let h = try EnvHarness(log: log, googlePhotos: fake)
        await h.environment.start()
        #expect(await h.environment.privacy.eraseEverything(typed: PrivacySettingsViewModel.eraseKeyword))
        #expect(log.count("google.eraseAll") == 2)
        #expect(
            try #require(log.events.lastIndex(of: "google.eraseAll"))
                > (try #require(log.index("store.erase"))))
        #expect(!h.environment.googleEraseFailed)
    }

    // MARK: Forget

    @Test func forgetCancelsAndAwaitsAGoogleImportBeforeDeleting() async throws {
        let (h, _) = try Self.harness(.blockUntilCancelled)
        let alice = try await h.store.seedConfirmed("Synthetic Alice", vector: aliceVector)
        await h.environment.start()
        let model = h.environment.googleImport
        let run = Task { await model.start() }
        try await waitUntil { model.state == .waitingForPicker }

        try await h.environment.store.forget(alice.id)
        await run.value

        let forgetIndex = try #require(h.log.index("store.forget"))
        #expect(try #require(h.log.index("google.returned")) < forgetIndex)
        #expect(h.log.count("store.addEmbeddings") == 0)
        #expect(h.environment.googleTask == nil)
        // Not the user's cancel: say what happened (no ids, no URLs).
        guard case .error(let text) = model.state else {
            Issue.record("expected an error state, got \(model.state)")
            return
        }
        #expect(text.contains("interrupted"))
    }

    // MARK: One photo writer at a time

    @Test func googleImportPausesTheAppleScanWhichResumesAfterwards() async throws {
        let gate = EnvGate()
        let (h, _) = try Self.harness(.succeed(faces: 1, gate: gate))
        await h.environment.start()
        try await h.startBlockedScan()
        let model = h.environment.googleImport
        let run = Task { await model.start() }

        // The scan stopped writing before the import got going, and stays parked.
        try await waitUntil { h.log.count("google.import") == 1 }
        #expect(try #require(h.log.index("scan.partialWrite")) < (try #require(h.log.index("google.import"))))
        #expect(h.environment.scanStatus == .paused)
        h.environment.startPhotoScan()
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.log.count("scan.list") == 1)

        gate.open()
        await run.value
        // Picked up again once the import finished.
        try await waitUntil { h.log.count("scan.list") == 2 }
        #expect(h.environment.scanStatus == .scanning)
        await h.environment.pauseScan()
    }

    @Test func secondGoogleImportIsBusy() async throws {
        let (h, _) = try Self.harness(.blockUntilCancelled)
        await h.environment.start()
        let model = h.environment.googleImport
        let run = Task { await model.start() }
        try await waitUntil { model.state == .waitingForPicker }

        await #expect(throws: GooglePhotosImportError.busy) {
            _ = try await h.environment.runGooglePhotosImport { _ in }
        }
        // The screen ignores a second tap while running.
        await model.start()
        #expect(h.log.count("google.import") == 1)

        model.cancel()
        await run.value
        #expect(model.state == .idle)
        #expect(model.message == nil)
    }

    // MARK: Results

    @Test func importedFacesAreSuggestionsInWhoIsThisNeverRecognized() async throws {
        let (h, fake) = try Self.harness(.succeed(faces: 2, gate: nil))
        await h.environment.start()
        let revision = h.environment.peopleRevision
        let model = h.environment.googleImport
        for n in 0..<2 {
            fake.setCached(try EnvSyntheticImage.make(width: 400, height: 300), for: "gphotos:synthetic-\(n)")
        }

        await model.start()

        guard case .done(let summary) = model.state else {
            Issue.record("expected done, got \(model.state)")
            return
        }
        #expect(summary.facesFound == 2)
        #expect(model.message?.contains("Who is this?") == true)
        #expect(h.environment.peopleRevision > revision)
        // Suggestions only (invariant 3): nobody is recognizable until confirmed.
        #expect(try await h.store.confirmedGallery(space: envSpace).isEmpty)
        let faces = try await Self.googleFaces(h)
        #expect(faces.count == 2)
        #expect(faces.allSatisfy { $0.personID == nil })
        await h.environment.settleGallery()
        #expect(h.environment.galleryPersonCount == 0)
        // "Who is this?" shows the new card, with thumbnails from the on-device copies.
        let enrollment = h.environment.enrollment
        try await waitUntil { enrollment.pending.count == 1 }
        #expect(enrollment.pending.first?.representative.image != nil)
    }

    @Test func notConfiguredImportNeverReachesTheImporter() async throws {
        let (h, _) = try Self.harness(.succeed(faces: 1, gate: nil), configured: false)
        await h.environment.start()
        let model = h.environment.googleImport
        #expect(!model.isConfigured)
        await model.start()
        #expect(model.state == .error(GooglePhotosImportModel.notConfiguredMessage))
        #expect(model.message?.contains("e2e/google-photos.md") == true)
        #expect(h.log.count("google.import") == 0)
    }

    @Test func missingModelRefusesTheImport() async throws {
        let (h, _) = try Self.harness(.succeed(faces: 1, gate: nil), modelMissing: true)
        await h.environment.start()
        let model = h.environment.googleImport
        await model.start()
        #expect(h.log.count("google.import") == 0)
        guard case .error = model.state else {
            Issue.record("expected an error, got \(model.state)")
            return
        }
    }

    @Test func importerErrorsShowFixedMessages() async throws {
        let (h, _) = try Self.harness(.fail(.reauthenticationRequired))
        await h.environment.start()
        let model = h.environment.googleImport
        await model.start()
        #expect(model.message == "Google sign-in expired. Import again to sign in.")
        #expect(h.environment.googleTask == nil)
    }

    @Test(arguments: [
        GooglePhotosImportError.notConfigured, .reauthenticationRequired, .pickerTimedOut, .network, .busy,
    ])
    func messagesNeverCarryURLsOrIds(_ error: GooglePhotosImportError) throws {
        let text = try #require(GooglePhotosImportModel.message(for: error, userCancelled: false))
        #expect(!text.contains("://"))
        #expect(!text.lowercased().contains("token"))
        #expect(!text.contains("gphotos:"))
    }

    @Test func messageMapping() {
        typealias M = GooglePhotosImportModel
        #expect(
            M.message(for: GooglePhotosImportError.busy, userCancelled: false)
                == "A photo scan is already running.")
        #expect(M.message(for: GooglePhotosImportError.cancelled, userCancelled: false) == nil)
        #expect(M.message(for: CancellationError(), userCancelled: true) == nil)
        #expect(M.message(for: CancellationError(), userCancelled: false)?.contains("interrupted") == true)
        #expect(M.state(after: GooglePhotosImportError.cancelled, userCancelled: false) == .idle)
        #expect(M.message(for: EnvStoreFailure(), userCancelled: false) != nil)
    }

    @Test func signOutAsksTheImporterAndUpdatesTheScreen() async throws {
        let (h, _) = try Self.harness(.succeed(faces: 1, gate: nil))
        let model = h.environment.googleImport
        await model.refreshSignInState()
        #expect(model.isSignedIn)
        await model.signOut()
        #expect(h.log.count("google.signOut") == 1)
        #expect(!model.isSignedIn)
    }

    // MARK: Wiring

    @Test func theImporterGetsTheAppsCancellableStoreAndLoadedEmbedder() async throws {
        let (h, fake) = try Self.harness(.succeed(faces: 1, gate: nil))
        let services = try #require(fake.services)
        #expect(services.store is CancellableImportStore)
        #expect(services.embedder.space == DeferredFaceEmbedder.placeholderSpace)
        await h.environment.start()
        #expect(services.embedder.space == envSpace)
    }

    /// The live factory builds the HaloImport importer, configured exactly when the build has a
    /// client ID. Construction only: nothing here touches the Keychain or the network.
    @Test func liveFactoryBuildsTheImporterFromTheConfig() {
        func live(_ clientID: String?) -> any GooglePhotosImporting {
            AppDependencies.liveGooglePhotos(
                GooglePhotosServices(
                    config: GooglePhotosConfig(clientID: clientID),
                    store: CancellableImportStore(base: EnvNullStore()), detector: EnvFakeDetector(),
                    embedder: DeferredFaceEmbedder()))
        }
        let configured = live("synthetic-client.apps.googleusercontent.com")
        #expect(configured is GooglePhotosImporter)
        #expect(configured.isConfigured)
        #expect(!live(nil).isConfigured)
    }
}

// MARK: - Pure pieces

@Suite struct GooglePhotosConfigTests {
    @Test(arguments: [nil, "", "   ", "$(HALO_GOOGLE_CLIENT_ID)"])
    func missingOrEmptyClientIDIsNotConfigured(_ value: String?) {
        #expect(!GooglePhotosConfig(clientID: value).isConfigured)
        #expect(GooglePhotosConfig(clientID: value) == .notConfigured)
    }

    @Test func clientIDFromInfoDictionary() {
        let config = GooglePhotosConfig(infoDictionary: [
            GooglePhotosConfig.infoKey: " synthetic-client.apps.googleusercontent.com\n"
        ])
        #expect(config.isConfigured)
        #expect(config.clientID == "synthetic-client.apps.googleusercontent.com")
        #expect(!GooglePhotosConfig(infoDictionary: nil).isConfigured)
        #expect(!GooglePhotosConfig(infoDictionary: [GooglePhotosConfig.infoKey: 42]).isConfigured)
    }

    @Test func deferredEmbedderThrowsUntilLoaded() async throws {
        let deferred = DeferredFaceEmbedder()
        let face = FaceObservation(
            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), quality: 0.9, timestamp: 0)
        let image = try EnvSyntheticImage.make(width: 8, height: 8)
        await #expect(throws: DeferredFaceEmbedder.NotLoaded.self) {
            _ = try await deferred.embed(face: face, in: image)
        }
        let real = EnvFakeEmbedder()
        real.set(aliceVector)
        deferred.resolve(real)
        #expect(deferred.space == envSpace)
        #expect(try await deferred.embed(face: face, in: image) == aliceVector)
    }

    @Test func cancellableImportStoreRefusesWritesFromACancelledTask() async throws {
        let log = EnvEventLog()
        let store = CancellableImportStore(base: try EnvRecordingStore(log: log))
        let face = EnvFakeGooglePhotos.face(1, space: envSpace)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            try await store.addEmbeddings([face])
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(log.count("store.addEmbeddings") == 0)
        try await store.addEmbeddings([face])  // not cancelled: lands
        #expect(log.count("store.addEmbeddings") == 1)
    }
}

@Suite struct GooglePhotosThumbnailTests {
    @Test func googlePhotosFacesAreCroppedFromTheOnDeviceCopy() async throws {
        let log = EnvEventLog()
        let fake = EnvFakeGooglePhotos(log: log, mode: .fail(.network))
        // Marker at the face centre of a 1600 x 1200 photo.
        let photo = try ThumbnailCropTests.image(width: 1600, height: 1200, marker: (x: 800, y: 510))
        fake.setCached(photo, for: "gphotos:synthetic-1")
        let photoKit = EnvRecordingThumbnails()
        let router = SourceRoutedThumbnails(photoLibrary: photoKit, googlePhotos: fake)
        var face = EnvFakeGooglePhotos.face(1, space: envSpace)
        face.faceBox = CGRect(x: 0.45, y: 0.35, width: 0.1, height: 0.15)

        let thumbnail = try #require(await router.thumbnail(for: face))
        #expect(max(thumbnail.width, thumbnail.height) <= 320)
        #expect(thumbnail.width == thumbnail.height)
        #expect(photoKit.count == 0)
    }

    @Test func otherSourcesStayOnPhotoKit() async throws {
        let fake = EnvFakeGooglePhotos(log: EnvEventLog(), mode: .fail(.network))
        let photoKit = EnvRecordingThumbnails()
        let router = SourceRoutedThumbnails(photoLibrary: photoKit, googlePhotos: fake)
        let face = FaceEmbedding(
            space: envSpace, vector: aliceVector, source: .photoLibrary, sourceRef: "synthetic-asset",
            quality: 0.9)
        #expect(await router.thumbnail(for: face) != nil)
        #expect(photoKit.count == 1)
    }

    @Test func missingGoogleCopyOrRefHasNoThumbnail() async throws {
        let fake = EnvFakeGooglePhotos(log: EnvEventLog(), mode: .fail(.network))
        let photoKit = EnvRecordingThumbnails()
        let router = SourceRoutedThumbnails(photoLibrary: photoKit, googlePhotos: fake)
        var face = EnvFakeGooglePhotos.face(7, space: envSpace)
        #expect(await router.thumbnail(for: face) == nil)
        face.sourceRef = nil
        #expect(await router.thumbnail(for: face) == nil)
        #expect(photoKit.count == 0)
    }

    @Test func scaledDownKeepsSmallImagesAndShrinksLargeOnes() throws {
        let small = try EnvSyntheticImage.make(width: 100, height: 80)
        #expect(FaceThumbnailCrop.scaledDown(small, maxPixelSize: 320).width == 100)
        let large = try EnvSyntheticImage.make(width: 1000, height: 500)
        let scaled = FaceThumbnailCrop.scaledDown(large, maxPixelSize: 320)
        #expect(scaled.width == 320)
        #expect(scaled.height == 160)
    }
}

// MARK: - Fakes local to these tests

enum EnvSyntheticImage {
    /// A solid grey RGBA image.
    static func make(width: Int, height: Int) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}

/// PhotoKit stand-in: counts calls, returns a tiny synthetic image.
final class EnvRecordingThumbnails: FaceThumbnailProvider {
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }
    func thumbnail(for embedding: FaceEmbedding) async -> CGImage? {
        calls.withLock { $0 += 1 }
        return try? EnvSyntheticImage.make(width: 4, height: 4)
    }
}

/// Google importer whose first `eraseAll()` fails.
final class EnvFailingEraseGooglePhotos: GooglePhotosImporting, EnvGooglePhotosAttaching {
    let log: EnvEventLog
    private let calls = Mutex(0)
    init(log: EnvEventLog) { self.log = log }
    func attach(_ services: GooglePhotosServices) {}
    var isConfigured: Bool { true }
    func isSignedIn() async -> Bool { false }
    func importPicked(progress: @escaping @Sendable (GooglePhotosImportProgress) -> Void) async throws
        -> GooglePhotosImportProgress
    { throw GooglePhotosImportError.network }
    func cachedImage(for sourceRef: String) async -> CGImage? { nil }
    func signOut() async {}
    func eraseAll() async throws {
        log.record("google.eraseAll")
        let first = calls.withLock { c in
            c += 1
            return c == 1
        }
        if first { throw EnvStoreFailure() }
    }
}

/// An empty store that ignores writes.
struct EnvNullStore: PeopleStoring, EnrollmentStoring {
    func person(_ id: PersonID) async throws -> Person? { nil }
    func allPeople() async throws -> [Person] { [] }
    func upsert(_ person: Person) async throws {}
    func identities(for id: PersonID) async throws -> [Identity] { [] }
    func addIdentity(_ identity: Identity) async throws {}
    func person(matching kind: Identity.Kind, value: String) async throws -> Person? { nil }
    func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] { [] }
    func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws {}
    func forget(_ id: PersonID) async throws {}
    func latestDigest() async throws -> InteractionDigest? { nil }
    func saveDigest(_ digest: InteractionDigest) async throws {}
    func unassignedEmbeddings(space: EmbeddingSpace) async throws -> [FaceEmbedding] { [] }
    func embeddings(ids: [UUID]) async throws -> [FaceEmbedding] { [] }
    func replaceClusters(_ clusters: [ClusterRecord]) async throws {}
    func clusters() async throws -> [ClusterRecord] { [] }
    func confirm(cluster id: String, as person: PersonID) async throws {}
    func deleteEmbeddings(ids: [UUID]) async throws {}
    func removeIdentity(_ identity: Identity) async throws {}
    func scanCursor() async throws -> String? { nil }
    func setScanCursor(_ cursor: String?) async throws {}
}

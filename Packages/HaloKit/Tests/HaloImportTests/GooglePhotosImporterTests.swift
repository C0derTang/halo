import CoreGraphics
import Foundation
import HaloClustering
import HaloCore
import Testing

@testable import HaloImport

private typealias G = GoogleFixture
private typealias F = PhotoScanFixture

/// One importer wired to fakes: fake Google, in-memory Keychain, temp cache dir, fake clock.
private struct Harness {
    let google: FakeGoogle
    let store = PhotoScanFakeStore()
    let tokenStore: KeychainGoogleTokenStore
    let keys: InMemoryKeyStore
    let dir = G.tempDirectory()
    let clock = FakeClock()
    let presenter: FakePresenter
    let embedder: SyntheticEmbedder
    let importer: GooglePhotosImporter
    let cache: GooglePhotosCache

    /// `faces` is keyed by item width (each synthetic photo has a unique width).
    init(
        items: [FakeGoogle.Item], faces: [Int: [FaceObservation]] = [:],
        tokens: GoogleTokens? = G.validTokens(),
        presenter: FakePresenter = FakePresenter(), clientID: String? = G.clientID,
        detector: ScriptedDetector? = nil, embedder: SyntheticEmbedder = SyntheticEmbedder(),
        sessionCleanupTimeout: Duration = .seconds(3),
        isSystemicFailure: @escaping @Sendable (any Error) -> Bool = { _ in false }
    ) {
        google = FakeGoogle(items: items)
        (tokenStore, keys) = G.tokenStore(tokens)
        self.presenter = presenter
        self.embedder = embedder
        let config = GooglePhotosImportConfig(
            scan: PhotoScanConfig(maxPixelSize: 2048), sessionCleanupTimeout: sessionCleanupTimeout)
        importer = GooglePhotosImporter(
            clientID: clientID, store: store, detector: detector ?? ScriptedDetector(facesByWidth: faces),
            embedder: embedder, presenter: presenter, transport: google, tokenStore: tokenStore,
            cacheDirectory: dir, config: config, clock: clock, now: { G.now },
            isSystemicFailure: isSystemicFailure)
        cache = GooglePhotosCache(directory: dir)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }

    var dirExists: Bool { FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) }
}

private func photo(_ i: Int) -> FakeGoogle.Item { .init(id: "m\(i)", type: "PHOTO", width: 1000 + i) }
private func video(_ i: Int) -> FakeGoogle.Item { .init(id: "m\(i)", type: "VIDEO", width: 1000 + i) }

/// m0: one face; m1: video; m2: two faces; m3: no face.
private let standardItems = [photo(0), video(1), photo(2), photo(3)]
private let standardFaces: [Int: [FaceObservation]] = [
    1000: [F.face(identity: 0)],
    1002: [F.face(identity: 1), F.face(identity: 2, jitter: 0.01)],
]

/// Signals when a download for `id` starts.
private func downloadStarted(_ google: FakeGoogle, id: String, hang: Bool) -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    google.with {
        $0.onDownload[id] = { continuation.yield() }
        if hang { $0.hangingDownloads.insert(id) }
    }
    return stream
}

@Suite struct GooglePhotosImporterTests {
    // MARK: Happy path

    @Test func importWritesUnconfirmedGooglePhotosEmbeddings() async throws {
        let h = Harness(items: standardItems, faces: standardFaces)
        defer { h.cleanUp() }
        let phases = Recorder<GooglePhotosImportProgress.Phase>()
        let result = try await h.importer.importPicked { phases.append($0.phase) }

        let stored = await h.store.embeddings
        #expect(stored.count == 3)
        #expect(stored.allSatisfy { $0.personID == nil })
        #expect(stored.allSatisfy { $0.source == .googlePhotos && $0.space == h.embedder.space })
        #expect(stored.allSatisfy { $0.faceBox == F.face(identity: 0).boundingBox })
        #expect(Set(stored.compactMap(\.sourceRef)) == ["gphotos:m0", "gphotos:m2"])

        #expect(
            result
                == GooglePhotosImportProgress(
                    phase: .finished, picked: 3, downloaded: 3, facesEmbedded: 3, skipped: 1))
        #expect(
            Self.dedup(phases.all) == [
                .signingIn, .waitingForPicker, .downloading, .scanning, .clustering, .finished,
            ])

        // Suggestions only; no person, identity or confirmation; Apple scan cursor untouched.
        #expect(await h.store.identityMutations.isEmpty)
        #expect(await h.store.replaceClustersCalls == 1)
        #expect(await h.store.cursorWrites == 0)
        #expect(await h.store.cursor == nil)

        // Picker opened with /autoclose; session cleaned up; video never downloaded.
        #expect(
            h.presenter.pickerURLs.all.map(\.absoluteString) == [
                "https://photos.google.com/picker/s1/autoclose"
            ])
        #expect(h.google.with { $0.deletedSessions } == ["s1"])
        #expect(h.google.with { $0.downloads } == ["m0", "m2", "m3"])
        #expect(h.google.with { $0.downloadURLs }.allSatisfy { $0.absoluteString.hasSuffix("=w2048-h2048") })

        // Only photos with faces stay cached.
        #expect(h.cache.contains(itemID: "m0") && h.cache.contains(itemID: "m2"))
        #expect(!h.cache.contains(itemID: "m3"))
        let image = try #require(await h.importer.cachedImage(for: "gphotos:m0"))
        #expect(image.width == 1000 && image.height == 800)
        #expect(await h.importer.cachedImage(for: "m0") == nil)
        #expect(await h.importer.isSignedIn())
    }

    @Test func embeddingSpaceIsReadAtImportTimeNotInInit() async throws {
        // Like the app's lazily loading embedder: a placeholder space until the model loads.
        let lazy = LazySpaceEmbedder()
        let store = PhotoScanFakeStore()
        let google = FakeGoogle(items: [photo(0)])
        let (tokenStore, _) = G.tokenStore()
        let dir = G.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let importer = GooglePhotosImporter(
            clientID: G.clientID, store: store, detector: ScriptedDetector(facesByWidth: standardFaces),
            embedder: lazy, clusterer: FaceClusterer(), presenter: FakePresenter(), transport: google,
            tokenStore: tokenStore, cacheDirectory: dir,
            config: GooglePhotosImportConfig(scan: PhotoScanConfig(maxPixelSize: 2048)), clock: FakeClock(),
            now: { G.now })
        lazy.load()
        let result = try await importer.importPicked { _ in }
        #expect(result.facesEmbedded == 1)
        #expect(await store.embeddings.map(\.space) == [SyntheticEmbedder().space])
    }

    @Test func nothingIsUploadedAndOnlyGoogleIsContacted() async throws {
        let h = Harness(items: standardItems, faces: standardFaces)
        defer { h.cleanUp() }
        _ = try await h.importer.importPicked { _ in }
        let requests = h.google.requests.all
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { GoogleHosts.isAllowed($0.url) })
        for request in requests where !(request.httpBody ?? Data()).isEmpty {
            // The only request bodies: the picker session config. (Token calls would be form posts.)
            #expect(request.url?.path == "/v1/sessions")
            #expect(
                String(decoding: request.httpBody!, as: UTF8.self)
                    == #"{"pickingConfig":{"maxItemCount":"200"}}"#)
        }
        #expect(requests.allSatisfy { ["GET", "POST", "DELETE"].contains($0.httpMethod ?? "GET") })
    }

    @Test func alreadyImportedItemsAreSkippedNextTime() async throws {
        let h = Harness(items: standardItems, faces: standardFaces)
        defer { h.cleanUp() }
        // An Apple Photos embedding whose ref happens to equal a Google id must not count.
        await h.store.seed(embeddings: [
            FaceEmbedding(
                space: h.embedder.space, vector: [1, 0, 0, 0, 0, 0, 0, 0], source: .photoLibrary,
                sourceRef: "m3", quality: 0.9)
        ])
        _ = try await h.importer.importPicked { _ in }
        let downloadsBefore = h.google.with { $0.downloads.count }
        let second = try await h.importer.importPicked { _ in }

        #expect(await h.store.embeddings.count == 4)  // 1 seeded + 3 imported, no duplicates
        #expect(second.facesEmbedded == 0)
        #expect(second.picked == 3)
        #expect(second.skipped == 3)  // video + m0 + m2
        // Only the face-less photo is fetched again (it was not kept).
        #expect(Array(h.google.with { $0.downloads }.dropFirst(downloadsBefore)) == ["m3"])
        // Nothing new: stored suggestions (the Apple scan's too) are not rewritten.
        #expect(await h.store.replaceClustersCalls == 1)
    }

    @Test func systemicFailureAbortsInsteadOfSkippingEveryFace() async throws {
        let h = Harness(
            items: [photo(0), photo(2)], faces: standardFaces, embedder: SyntheticEmbedder(alwaysFails: true),
            isSystemicFailure: { $0 is SyntheticEmbedder.Failure })
        defer { h.cleanUp() }
        await #expect(throws: SyntheticEmbedder.Failure.self) {
            _ = try await h.importer.importPicked { _ in }
        }
        #expect(await h.store.embeddings.isEmpty)
        #expect(await h.store.replaceClustersCalls == 0)
        #expect(h.embedder.sizes.all.count == 1)  // stopped at the first face
    }

    @Test func nonSystemicEmbedFailuresAreSkipped() async throws {
        let h = Harness(
            items: [photo(0), photo(2)], faces: standardFaces, embedder: SyntheticEmbedder(alwaysFails: true))
        defer { h.cleanUp() }
        let result = try await h.importer.importPicked { _ in }
        #expect(result.facesEmbedded == 0)
        #expect(await h.store.embeddings.isEmpty)
        #expect(await h.store.replaceClustersCalls == 0)
    }

    @Test func photosNoLongerBackingAFaceAreDroppedFromTheCache() async throws {
        let h = Harness(items: [photo(0), photo(2)], faces: standardFaces)
        defer { h.cleanUp() }
        _ = try await h.importer.importPicked { _ in }
        #expect(h.cache.contains(itemID: "m0") && h.cache.contains(itemID: "m2"))
        // The user rejects m0's face; the next import picks something else.
        let m0 = await h.store.embeddings.filter { $0.sourceRef == "gphotos:m0" }.map(\.id)
        await h.store.removeEmbeddings(ids: m0)
        h.google.with { $0.items = [photo(4)] }
        _ = try await h.importer.importPicked { _ in }
        #expect(!h.cache.contains(itemID: "m0"))
        #expect(h.cache.contains(itemID: "m2"))
    }

    @Test func expiredBaseURLsAreReListedAndRetried() async throws {
        let h = Harness(items: [photo(0)], faces: standardFaces)
        defer { h.cleanUp() }
        h.google.with { $0.firstValidGeneration = 2 }
        let result = try await h.importer.importPicked { _ in }
        #expect(result.downloaded == 1 && result.facesEmbedded == 1)
        #expect(h.google.requests.all.filter { $0.url?.path == "/v1/mediaItems" }.count == 2)
    }

    @Test func unavailableItemsAreSkippedNotFatal() async throws {
        let h = Harness(items: [photo(0), photo(2)], faces: standardFaces)
        defer { h.cleanUp() }
        h.google.with { $0.firstValidGeneration = 100 }  // every baseUrl stays "expired"
        let result = try await h.importer.importPicked { _ in }
        #expect(result.downloaded == 0)
        #expect(result.skipped == 2)
        #expect(await h.store.embeddings.isEmpty)
        #expect(h.google.with { $0.deletedSessions } == ["s1"])
    }

    // MARK: Sign-in

    @Test func signsInFirstWhenThereIsNoGrant() async throws {
        let presenter = FakePresenter(.approve)
        let h = Harness(items: [photo(0)], faces: standardFaces, tokens: nil, presenter: presenter)
        defer { h.cleanUp() }
        #expect(await !h.importer.isSignedIn())
        _ = try await h.importer.importPicked { _ in }
        #expect(presenter.authURLs.all.count == 1)
        #expect(try h.tokenStore.load()?.accessToken == "access-new")
        #expect(await h.importer.isSignedIn())
    }

    @Test func invalidGrantSurfacesReauthenticationAndDeletesTokens() async throws {
        let h = Harness(items: [photo(0)], faces: standardFaces, tokens: G.validTokens(expiresIn: -100))
        defer { h.cleanUp() }
        h.google.with { $0.refreshResponse = (400, G.json(["error": "invalid_grant"])) }
        await #expect(throws: GooglePhotosImportError.reauthenticationRequired) {
            _ = try await h.importer.importPicked { _ in }
        }
        #expect(h.keys.isEmpty)
        #expect(h.google.with { $0.createdSessions } == 0)
        #expect(await !h.importer.isSignedIn())
    }

    @Test func stateMismatchFailsTheImportWithoutStoringTokens() async throws {
        let h = Harness(items: [photo(0)], tokens: nil, presenter: FakePresenter(.wrongState))
        defer { h.cleanUp() }
        await #expect(throws: GooglePhotosImportError.network) {
            _ = try await h.importer.importPicked { _ in }
        }
        #expect(h.keys.isEmpty)
        #expect(h.google.requests.all.isEmpty)
    }

    @Test(arguments: [nil, "", "  "])
    func withoutAClientIDNothingHappens(_ clientID: String?) async throws {
        let h = Harness(items: [photo(0)], clientID: clientID)
        defer { h.cleanUp() }
        #expect(!h.importer.isConfigured)
        #expect(await !h.importer.isSignedIn())
        await #expect(throws: GooglePhotosImportError.notConfigured) {
            _ = try await h.importer.importPicked { _ in }
        }
        #expect(h.google.requests.all.isEmpty)
    }

    // MARK: Picker

    @Test func pickerTimeoutDeletesTheSession() async throws {
        let h = Harness(items: [photo(0)])
        defer { h.cleanUp() }
        h.google.with {
            $0.pollsBeforeSet = 10_000
            $0.timeoutIn = "12s"
        }
        await #expect(throws: GooglePhotosImportError.pickerTimedOut) {
            _ = try await h.importer.importPicked { _ in }
        }
        #expect(h.google.with { $0.deletedSessions } == ["s1"])
        #expect(await h.store.embeddings.isEmpty)
    }

    // MARK: Concurrency, cancellation, erase

    @Test func aSecondImportWhileOneRunsIsBusy() async throws {
        let h = Harness(items: [photo(0)], faces: standardFaces)
        defer { h.cleanUp() }
        let started = downloadStarted(h.google, id: "m0", hang: true)
        let first = Task { try await h.importer.importPicked { _ in } }
        for await _ in started { break }
        await #expect(throws: GooglePhotosImportError.busy) { _ = try await h.importer.importPicked { _ in } }
        first.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        // Free again once the first one ended.
        h.google.with { $0.hangingDownloads = [] }
        _ = try await h.importer.importPicked { _ in }
    }

    @Test func cancellationDeletesTheSessionAndKeepsDownloadedPhotos() async throws {
        let h = Harness(items: [photo(0), photo(2)], faces: standardFaces)
        defer { h.cleanUp() }
        let started = downloadStarted(h.google, id: "m2", hang: true)
        let task = Task { try await h.importer.importPicked { _ in } }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(h.google.with { $0.deletedSessions } == ["s1"])
        #expect(h.cache.contains(itemID: "m0"))
        #expect(await h.store.embeddings.isEmpty)

        // The next import reuses the downloaded photo instead of fetching it again.
        h.google.with { $0.hangingDownloads = [] }
        let result = try await h.importer.importPicked { _ in }
        #expect(h.google.with { $0.downloads } == ["m0", "m2"])
        #expect(result.facesEmbedded == 3)
    }

    @Test func cancellationDuringTheScanKeepsWhatWasPersisted() async throws {
        let detector = ScriptedDetector(facesByWidth: standardFaces, cancelOnCall: 2)
        let h = Harness(items: [photo(0), photo(2), photo(4)], detector: detector)
        defer { h.cleanUp() }
        await #expect(throws: CancellationError.self) { _ = try await h.importer.importPicked { _ in } }
        // m0 and m2 were scanned (m2's detection cancelled the run after returning); m4 was not.
        #expect(Set(await h.store.embeddings.compactMap(\.sourceRef)) == ["gphotos:m0", "gphotos:m2"])
        #expect(detector.sizes.all.count == 2)
        #expect(h.google.with { $0.deletedSessions } == ["s1"])
        #expect(await h.store.replaceClustersCalls == 0)
    }

    @Test func eraseAllDuringAnImportLeavesNoTokensFilesOrLaterWrites() async throws {
        let h = Harness(items: [photo(0), photo(2)], faces: standardFaces)
        defer { h.cleanUp() }
        let started = downloadStarted(h.google, id: "m2", hang: true)
        let task = Task { try await h.importer.importPicked { _ in } }
        for await _ in started { break }
        #expect(h.dirExists)  // m0 is already cached

        try await h.importer.eraseAll()

        #expect(h.keys.isEmpty)
        #expect(!h.dirExists)
        #expect(h.google.with { $0.deletedSessions } == ["s1"])
        #expect(await !h.importer.isSignedIn())
        let embeddingsAtErase = await h.store.embeddings.count
        let requestsAtErase = h.google.requests.all.count
        await #expect(throws: CancellationError.self) { _ = try await task.value }

        // Nothing happens afterwards.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await h.store.embeddings.count == embeddingsAtErase)
        #expect(await h.store.replaceClustersCalls == 0)
        #expect(h.google.requests.all.count == requestsAtErase)
        #expect(!h.dirExists)
        #expect(h.keys.isEmpty)
    }

    @Test func eraseAllDoesNotWaitOnASlowSessionDelete() async throws {
        let h = Harness(
            items: [photo(0), photo(2)], faces: standardFaces, sessionCleanupTimeout: .milliseconds(200))
        defer { h.cleanUp() }
        h.google.with { $0.hangDelete = true }
        let started = downloadStarted(h.google, id: "m2", hang: true)
        let task = Task { try await h.importer.importPicked { _ in } }
        for await _ in started { break }

        let begin = ContinuousClock.now
        try await h.importer.eraseAll()
        #expect(ContinuousClock.now - begin < .seconds(10))  // the DELETE hangs for 30 s
        #expect(h.keys.isEmpty)
        #expect(!h.dirExists)
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(h.google.requests.all.contains { $0.httpMethod == "DELETE" })
    }

    @Test func eraseAllWithoutAnImportDeletesTokensAndPhotos() async throws {
        let h = Harness(items: [photo(0)], faces: standardFaces)
        defer { h.cleanUp() }
        _ = try await h.importer.importPicked { _ in }
        #expect(h.dirExists && !h.keys.isEmpty)
        try await h.importer.eraseAll()
        #expect(!h.dirExists && h.keys.isEmpty)
        #expect(await h.importer.cachedImage(for: "gphotos:m0") == nil)
        // Embeddings are the store's to erase (eraseEverything), not ours.
        #expect(await h.store.embeddings.count == 1)
    }

    @Test func signOutRevokesDeletesTokensAndKeepsFaces() async throws {
        let h = Harness(items: [photo(0)], faces: standardFaces)
        defer { h.cleanUp() }
        _ = try await h.importer.importPicked { _ in }
        await h.importer.signOut()
        #expect(h.keys.isEmpty)
        #expect(await !h.importer.isSignedIn())
        #expect(h.google.requests.all.last?.url?.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(await h.store.embeddings.count == 1)
        #expect(h.cache.contains(itemID: "m0"))
    }

    private static func dedup(_ phases: [GooglePhotosImportProgress.Phase]) -> [GooglePhotosImportProgress
        .Phase]
    {
        phases.reduce(into: []) { if $0.last != $1 { $0.append($1) } }
    }
}

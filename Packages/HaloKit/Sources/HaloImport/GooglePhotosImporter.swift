import CoreGraphics
import Foundation
import HaloClustering
import HaloCore

/// Tunables for `GooglePhotosImporter`.
public struct GooglePhotosImportConfig: Hashable, Sendable {
    /// Most items one picker session may return (the API allows up to 2000).
    public var maxItemCount: Int
    /// `mediaItems.list` page size.
    public var pageSize: Int
    /// Long edge requested from Google (`=w<n>-h<n>`) and kept in the cache.
    public var downloadPixelSize: Int
    /// baseUrls live about 60 minutes; items are re-listed once this much time has passed.
    public var baseURLLifetime: Duration
    /// Face filter, scan image size and clustering attempts (shared with the Apple Photos scan).
    public var scan: PhotoScanConfig
    /// Longest wait (real time) for the best-effort picker session DELETE.
    public var sessionCleanupTimeout: Duration

    public init(
        maxItemCount: Int = 200, pageSize: Int = 100, downloadPixelSize: Int = 2048,
        baseURLLifetime: Duration = .seconds(55 * 60), scan: PhotoScanConfig = PhotoScanConfig(),
        sessionCleanupTimeout: Duration = .seconds(3)
    ) {
        self.maxItemCount = maxItemCount
        self.pageSize = pageSize
        self.downloadPixelSize = downloadPixelSize
        self.baseURLLifetime = baseURLLifetime
        self.scan = scan
        self.sessionCleanupTimeout = sessionCleanupTimeout
    }
}

/// Imports photos the user picks in Google's Photos Picker and scans them for faces ON DEVICE.
///
/// Flow: sign in (OAuth PKCE, if needed) -> create a picker session and open the picker -> poll
/// until the user is done -> list the picked items -> download the photos (not videos) into
/// `GooglePhotosCache` -> delete the session -> detect, filter and embed faces with the same
/// pipeline as the Apple Photos scan -> refresh cluster suggestions.
///
/// - Invariant 2: the only requests are Google OAuth, the Picker API and baseUrl GETs (see
///   `GoogleHosts`). Faces, crops and embeddings never leave the device. Nothing is logged.
/// - Invariant 3: embeddings are written with `personID == nil`, `source == .googlePhotos`,
///   `sourceRef == "gphotos:" + id`; clustering stores suggestions only.
/// - Invariant 5: tokens only in `GoogleTokenStoring` (Keychain). The client ID comes from config.
/// - Invariant 7: decoding and scanning run on this actor, never the main actor.
/// - The Apple Photos scan cursor is never read or written: a Google import is a finite list.
///
/// One import at a time (`.busy` otherwise). Cancelling the calling task deletes the picker
/// session and keeps what was already persisted. `eraseAll()` and `signOut()` cancel and await an
/// in-flight import first, so nothing is written after they return.
public actor GooglePhotosImporter: GooglePhotosImporting {
    public nonisolated let isConfigured: Bool

    private let authorizer: GoogleAuthorizer?
    private let client: GooglePhotosPickerClient?
    private let presenter: any GoogleBrowserPresenting
    private let tokenStore: any GoogleTokenStoring
    private let cache: GooglePhotosCache
    private let store: any PeopleStoring & EnrollmentStoring
    /// `space` is read per import, never here: the app's lazily loading embedder only knows its
    /// space once the model has loaded.
    private let embedder: any FaceEmbedder
    private let pipeline: FaceScanPipeline
    private let refresher: ClusterSuggestionRefresher
    private let config: GooglePhotosImportConfig
    private let clock: any GoogleImportClock

    private var current: (id: UUID, task: Task<GooglePhotosImportProgress, any Error>)?
    /// > 0 while `eraseAll` / `signOut` run: new imports are refused (`.busy`).
    private var exclusiveOperations = 0

    /// - Parameters:
    ///   - clientID: the iOS OAuth client ID from the build config; nil or empty means
    ///     `isConfigured == false`.
    ///   - presenter: sign-in + picker presentation; nil uses `WebAuthenticationPresenter` on iOS.
    ///   - cacheDirectory: nil uses `Application Support/GooglePhotos/`.
    public init(
        clientID: String?, store: any PeopleStoring & EnrollmentStoring, detector: any FaceDetecting,
        embedder: any FaceEmbedder, clusterer: FaceClusterer = FaceClusterer(),
        presenter: (any GoogleBrowserPresenting)? = nil, transport: any HTTPTransport = URLSessionTransport(),
        tokenStore: any GoogleTokenStoring = KeychainGoogleTokenStore(), cacheDirectory: URL? = nil,
        config: GooglePhotosImportConfig = GooglePhotosImportConfig(),
        uprighter: any PhotoScanUprighting = CoreImageUprighter(),
        clock: any GoogleImportClock = SystemGoogleImportClock(),
        now: @escaping @Sendable () -> Date = { Date() },
        isSystemicFailure: @escaping @Sendable (any Error) -> Bool = { _ in false }
    ) {
        let presenter = presenter ?? Self.livePresenter()
        let oauth = GoogleOAuth(clientID: clientID)
        isConfigured = oauth != nil
        if let oauth {
            let authorizer = GoogleAuthorizer(
                oauth: oauth, transport: transport, tokenStore: tokenStore, presenter: presenter, now: now)
            self.authorizer = authorizer
            client = GooglePhotosPickerClient(
                transport: transport, tokens: authorizer, pageSize: config.pageSize)
        } else {
            authorizer = nil
            client = nil
        }
        self.presenter = presenter
        self.tokenStore = tokenStore
        let directory =
            cacheDirectory ?? (try? GooglePhotosCache.defaultDirectory())
            ?? FileManager.default.temporaryDirectory.appending(
                path: "GooglePhotos", directoryHint: .isDirectory)
        cache = GooglePhotosCache(directory: directory, maxPixelSize: config.downloadPixelSize)
        self.store = store
        self.embedder = embedder
        pipeline = FaceScanPipeline(
            detector: detector, embedder: embedder, uprighter: uprighter, config: config.scan,
            isSystemicFailure: isSystemicFailure)
        refresher = ClusterSuggestionRefresher(store: store, clusterer: clusterer)
        self.config = config
        self.clock = clock
    }

    private static func livePresenter() -> any GoogleBrowserPresenting {
        #if os(iOS)
            WebAuthenticationPresenter()
        #else
            UnavailableBrowserPresenter()
        #endif
    }

    // MARK: - GooglePhotosImporting

    public func isSignedIn() async -> Bool {
        guard let authorizer else { return false }
        return await authorizer.hasTokens()
    }

    public func importPicked(progress: @escaping @Sendable (GooglePhotosImportProgress) -> Void)
        async throws -> GooglePhotosImportProgress
    {
        guard let authorizer, let client else { throw GooglePhotosImportError.notConfigured }
        guard current == nil, exclusiveOperations == 0 else { throw GooglePhotosImportError.busy }
        let id = UUID()
        let task = Task {
            defer { self.finished(id) }
            return try await self.run(authorizer: authorizer, client: client, progress: progress)
        }
        current = (id, task)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func cachedImage(for sourceRef: String) async -> CGImage? {
        cache.image(forSourceRef: sourceRef)
    }

    public func signOut() async {
        exclusiveOperations += 1
        defer { exclusiveOperations -= 1 }
        await cancelCurrentImport()
        if let authorizer {
            await authorizer.signOut()
        } else {
            try? tokenStore.delete()
        }
    }

    public func eraseAll() async throws {
        exclusiveOperations += 1
        defer { exclusiveOperations -= 1 }
        // The import deletes its picker session on the way out, before this resumes.
        await cancelCurrentImport()
        var firstError: (any Error)?
        do { try tokenStore.delete() } catch { firstError = error }
        do { try cache.removeAll() } catch { firstError = firstError ?? error }
        if let firstError { throw firstError }
    }

    // MARK: - Import

    private func finished(_ id: UUID) {
        if current?.id == id { current = nil }
    }

    private func cancelCurrentImport() async {
        guard let task = current?.task else { return }
        task.cancel()
        _ = await task.result
    }

    private func run(
        authorizer: GoogleAuthorizer, client: GooglePhotosPickerClient,
        progress: @escaping @Sendable (GooglePhotosImportProgress) -> Void
    ) async throws -> GooglePhotosImportProgress {
        var state = GooglePhotosImportProgress(phase: .signingIn)
        func publish(_ phase: GooglePhotosImportProgress.Phase) {
            state.phase = phase
            progress(state)
        }

        publish(.signingIn)
        do {
            try await authorizer.signInIfNeeded()
        } catch {
            throw Self.surfaced(error)
        }
        try Task.checkCancellation()

        publish(.waitingForPicker)
        let session: PickerSession
        do {
            session = try await client.createSession(maxItemCount: config.maxItemCount)
        } catch {
            throw Self.surfaced(error)
        }
        var sessionOpen = true
        do {
            guard let pickerURL = session.autocloseURL else { throw GooglePhotosImportError.network }
            try await presenter.openPicker(pickerURL)
            _ = try await client.waitForSelection(session, clock: clock)
            var listedAt = clock.now
            var items = try await client.listMediaItems(sessionID: session.id)
            let photos = items.filter { $0.kind == .photo }
            state.picked = photos.count
            state.skipped = items.count - photos.count

            // Read once per run, as late as possible (after the picker): the app's embedder loads
            // lazily and reports a placeholder space until then. Dedupe, scan and clustering all
            // use this one value.
            let space = embedder.space
            let embedded = try await embeddedItemIDs(space: space)
            // Photos that no longer back an embedding (rejected faces, forgotten people) and are
            // not picked again go; a picked photo downloaded by a cancelled import is reused.
            try? cache.prune(keepingItemIDs: embedded.union(photos.map(\.id)))

            publish(.downloading)
            var toScan: [PickedMediaItem] = []
            for photo in photos {
                try Task.checkCancellation()
                if embedded.contains(photo.id) {
                    state.skipped += 1
                } else if cache.contains(itemID: photo.id) {
                    state.downloaded += 1
                    toScan.append(photo)
                } else {
                    if clock.now - listedAt > config.baseURLLifetime {
                        items = try await client.listMediaItems(sessionID: session.id)
                        listedAt = clock.now
                    }
                    if try await download(
                        photo, items: &items, listedAt: &listedAt, client: client, sessionID: session.id)
                    {
                        state.downloaded += 1
                        toScan.append(photo)
                    } else {
                        state.skipped += 1
                    }
                }
                publish(.downloading)
            }

            sessionOpen = false
            await deleteSession(session.id, client: client)

            publish(.scanning)
            for photo in toScan {
                try Task.checkCancellation()
                let (faces, skipped) = try await scan(photo, space: space)
                state.facesEmbedded += faces
                if skipped { state.skipped += 1 }
                publish(.scanning)
            }

            // Nothing new: leave the stored suggestions (including the Apple scan's) untouched.
            if state.facesEmbedded > 0 {
                publish(.clustering)
                _ = try await refresher.refreshRetrying(
                    space: space, full: true, attempts: config.scan.clusteringAttempts)
            }
            publish(.finished)
            return state
        } catch {
            if sessionOpen { await deleteSession(session.id, client: client) }
            throw Self.surfaced(error)
        }
    }

    /// Downloads one photo into the cache. Re-lists once when its baseUrl has expired. Returns false
    /// when the item cannot be downloaded or decoded (it is skipped).
    private func download(
        _ photo: PickedMediaItem, items: inout [PickedMediaItem], listedAt: inout ContinuousClock.Instant,
        client: GooglePhotosPickerClient, sessionID: String
    ) async throws -> Bool {
        var item = items.first { $0.id == photo.id } ?? photo
        for attempt in 0..<2 {
            do {
                let data = try await client.download(item, maxPixelSize: config.downloadPixelSize)
                try Task.checkCancellation()
                return (try? cache.store(data, forItemID: photo.id)) ?? false
            } catch GooglePickerClientError.baseURLExpired where attempt == 0 {
                items = try await client.listMediaItems(sessionID: sessionID)
                listedAt = clock.now
                guard let fresh = items.first(where: { $0.id == photo.id }) else { return false }
                item = fresh
            } catch GooglePickerClientError.baseURLExpired {
                return false
            } catch GooglePhotosImportError.network {
                return false
            }
        }
        return false
    }

    /// Detect, filter and embed one cached photo; persists its unassigned embeddings. Returns how
    /// many faces were embedded, and whether the photo could not be scanned at all. A photo with no
    /// embedded face is removed from the cache.
    private func scan(_ photo: PickedMediaItem, space: EmbeddingSpace) async throws -> (
        faces: Int, skipped: Bool
    ) {
        guard let image = cache.image(forItemID: photo.id, maxPixelSize: config.scan.maxPixelSize) else {
            try? cache.remove(itemID: photo.id)
            return (0, true)
        }
        let outcome = try await pipeline.scan(
            PhotoScanImage(image: image, orientation: .up),
            timestamp: photo.createTime?.timeIntervalSinceReferenceDate ?? 0, source: .googlePhotos,
            sourceRef: photo.sourceRef, space: space)
        guard case .scanned(let result) = outcome else {
            try? cache.remove(itemID: photo.id)
            return (0, true)
        }
        guard !result.embeddings.isEmpty else {
            try? cache.remove(itemID: photo.id)
            return (0, false)
        }
        try await store.addEmbeddings(result.embeddings)
        return (result.embeddings.count, false)
    }

    /// Ids of Google items that already have embeddings in this space.
    private func embeddedItemIDs(space: EmbeddingSpace) async throws -> Set<String> {
        let existing =
            try await store.unassignedEmbeddings(space: space) + store.confirmedGallery(space: space)
        return Set(
            existing.lazy.filter { $0.source == .googlePhotos }.compactMap(\.sourceRef)
                .compactMap(GooglePhotosCache.itemID(fromSourceRef:)))
    }

    /// Best effort and bounded by `config.sessionCleanupTimeout`, so cancel, forget and the kill
    /// switch never wait on a slow network. Runs in its own task so it is not cancelled together
    /// with the import it cleans up after.
    private func deleteSession(_ id: String, client: GooglePhotosPickerClient) async {
        let timeout = config.sessionCleanupTimeout
        await Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await client.deleteSession(id: id) }
                group.addTask { try? await Task.sleep(for: timeout) }
                await group.next()
                group.cancelAll()
            }
        }.value
    }

    /// The error `importPicked` throws: cancellation stays `CancellationError`, client-internal
    /// errors become `.network`, everything else (store, systemic vision failures) passes through.
    private static func surfaced(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if error is GooglePickerClientError { return GooglePhotosImportError.network }
        return error
    }
}

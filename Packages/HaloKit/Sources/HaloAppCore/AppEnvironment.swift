import Foundation
import HaloBridgeKit
import HaloClustering
import HaloCore
import HaloImport
import HaloLabels
import HaloLens
import HaloMatching
import HaloUI
import HaloVision
import Observation
import SwiftUI

/// The app's composition root: builds the real services once at launch and owns the app-wide
/// lifecycle and privacy rules.
///
/// Load-bearing rules (invariants 2, 3, 5, 7):
/// - **Writers stop before erasure.** `forget` and the kill switch (through `store`, the only store
///   screens get) first cancel and await any running photo scan; the kill switch also stops the
///   camera and clears the lens gallery before `eraseEverything` runs. Afterwards every in-memory
///   copy (gallery, lens votes, triage view model) is reset.
/// - **The gallery follows identity changes.** Every confirm / forget / deleteEmbeddings / erase /
///   digest import / upsert rebuilds the `GalleryMatcher` and calls `LensPipeline.setMatcher`
///   (debounced, off the main actor). A forgotten person is dropped from the lens *before* the store
///   deletes them.
/// - **Nothing per frame on the main actor.** Camera frames go straight from the capture queue to
///   the `LensPipeline` actor via `LensFrameRouter`.
/// - **Missing model is not a crash.** `recognition == .unavailable`: no lens pipeline, no photo
///   scan; the rest of the app works.
/// - **One handle normalizer** (device region, unknown -> "ZZ", never a guessed "US") shared by the
///   contacts importer, the handle resolver and the label ranker.
@MainActor @Observable
public final class AppEnvironment {
    public enum RecognitionStatus: Hashable, Sendable {
        case loading, available, unavailable
    }

    public enum PhotoScanStatus: Hashable, Sendable {
        case idle, scanning, paused, finished, failed, unavailable
    }

    // MARK: Services for screens

    /// The store every screen uses. Routes forget / erase through this environment.
    public let store: ObservedStore
    public let appLock: AppLock
    public let privacy: PrivacySettingsViewModel
    /// Replaced (fresh state) after the kill switch; observe `resetGeneration`.
    public private(set) var enrollment: EnrollmentViewModel
    public let thumbnails: any FaceThumbnailProvider
    public let handleNormalizer: HandleNormalizer
    public let labelRanker: ContextLabelRanker
    public let handleResolver: HandleResolver
    public let camera: (any AppCamera)?
    public let policy: MatchPolicy
    /// nil until the model loaded, and forever when recognition is unavailable.
    public private(set) var lensPipeline: LensPipeline?

    // MARK: Observable state

    public private(set) var recognition: RecognitionStatus = .loading
    public var recognitionAvailable: Bool { recognition == .available }
    public private(set) var isStoreAvailable = false
    public private(set) var isLensRunning = false
    public private(set) var scanStatus: PhotoScanStatus = .idle
    public private(set) var scanProgress: ScanProgress?
    public private(set) var phase: ScenePhase = .active
    /// Number of people the lens can currently recognize.
    public private(set) var galleryPersonCount = 0
    /// Bumped after every identity change; screens that cache labels re-read on change.
    public private(set) var peopleRevision = 0
    /// Bumped when every screen must rebuild from scratch (kill switch, store opened late).
    public private(set) var resetGeneration = 0

    /// The matcher most recently handed to the lens (tests).
    @ObservationIgnored private(set) var activeGallery: GalleryMatcher?

    // MARK: Private

    @ObservationIgnored private let dependencies: AppDependencies
    @ObservationIgnored private let lazyStore: LazyStore
    @ObservationIgnored private let frameRouter = LensFrameRouter()
    @ObservationIgnored private var refresher: GalleryRefresher?
    @ObservationIgnored private var embedder: AppDependencies.Embedder?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleChain: Task<Void, Never>?
    /// Forgets / erases in progress. The scan does not (re)start while any is running.
    @ObservationIgnored private var destructiveOperations = 0
    /// The user asked for a scan that has not finished yet (it may be paused).
    @ObservationIgnored private var wantsScan = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanRunID = 0

    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        let lazyStore = LazyStore(open: dependencies.openStore)
        self.lazyStore = lazyStore
        let store = ObservedStore(base: lazyStore)
        self.store = store
        appLock = AppLock(authenticator: dependencies.authenticator, timeout: dependencies.lockTimeout)
        privacy = PrivacySettingsViewModel(store: store, authenticator: dependencies.authenticator)
        enrollment = EnrollmentViewModel(store: store, thumbnails: dependencies.thumbnails)
        thumbnails = dependencies.thumbnails
        policy = dependencies.policy

        let normalizer = HandleNormalizer(region: dependencies.region ?? "ZZ")
        handleNormalizer = normalizer
        labelRanker = ContextLabelRanker(
            calendar: Calendar.current, locale: Locale.current, normalizer: normalizer)
        handleResolver = HandleResolver(
            store: store, normalization: HandleNormalization(normalizer: normalizer))

        let router = frameRouter
        camera = dependencies.makeCamera { frame in router.route(frame) }

        isStoreAvailable = lazyStore.openIfNeeded()
        store.setDelegate(self)
    }

    /// The real app.
    public static func live() -> AppEnvironment {
        AppEnvironment(dependencies: .live())
    }

    /// The same normalizer, wrapped for HaloImport.
    public var handleNormalization: HandleNormalization { HandleNormalization(normalizer: handleNormalizer) }

    /// Contacts importer sharing the app's normalizer.
    public func makeContactsImporter() -> ContactsImporter {
        ContactsImporter(store: store, source: dependencies.contacts, normalization: handleNormalization)
    }

    // MARK: - Startup

    /// Loads the embedding model (off the main actor) and builds the lens pipeline with the confirmed
    /// gallery. Safe to call more than once; later calls wait for the first.
    public func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { await self.performStart() }
        startTask = task
        await task.value
    }

    private func performStart() async {
        openStoreIfNeeded()
        let embedder: AppDependencies.Embedder
        do {
            embedder = try await dependencies.loadEmbedder()
        } catch {
            // Never crash on a missing or broken model: the lens and scan are simply unavailable.
            recognition = .unavailable
            wantsScan = false
            scanStatus = .unavailable
            return
        }
        let pipeline = LensPipeline(
            detector: dependencies.detector, embedder: embedder, matcher: NullMatcher(),
            policy: dependencies.policy, config: dependencies.lensConfig)
        let refresher = GalleryRefresher(
            store: lazyStore, space: embedder.space, sink: pipeline, debounce: dependencies.galleryDebounce
        ) { [weak self] matcher in
            await self?.galleryApplied(matcher)
        }
        self.embedder = embedder
        self.refresher = refresher
        lensPipeline = pipeline
        await refresher.refreshNow()
        frameRouter.attach(pipeline)
        recognition = .available
        reconcileScan()
    }

    private func galleryApplied(_ matcher: GalleryMatcher) {
        activeGallery = matcher
        galleryPersonCount = matcher.personCount
    }

    /// Opens the store if it is not open yet (e.g. after a pre-warmed launch before first unlock).
    @discardableResult
    private func openStoreIfNeeded() -> Bool {
        let wasAvailable = isStoreAvailable
        isStoreAvailable = lazyStore.openIfNeeded()
        if isStoreAvailable, !wasAvailable {
            // Screens that loaded while it was unavailable showed errors: rebuild them.
            resetGeneration += 1
            if let refresher { Task { await refresher.requestRefresh() } }
        }
        return isStoreAvailable
    }

    /// Waits until scheduled gallery rebuilds reached the lens (tests).
    func settleGallery() async {
        await refresher?.settle()
    }

    // MARK: - Lifecycle

    /// Forward every `scenePhase` change from the root. Synchronous effects (lock, camera) apply at
    /// once; async work runs in order on a serial chain. The returned task finishes with it.
    ///
    /// - `.background`: stop the camera, pause the photo scan (cancel + await, resumed on
    ///   `.active`), then flush any pending store erasure, inside a background task.
    /// - `.active`: AppLock rules (re-lock after the timeout, auto-prompt), reopen the store if
    ///   needed, resume a paused scan.
    @discardableResult
    public func scenePhaseChanged(to newPhase: ScenePhase) -> Task<Void, Never> {
        phase = newPhase
        appLock.scenePhaseChanged(to: newPhase)
        switch newPhase {
        case .background:
            stopLens()
            return enqueueLifecycle { [self] in
                await dependencies.backgroundWork("halo.background") { [self] in
                    await pauseScan()
                    // Flushes the store's pending erasure (and refreshes the privacy screen's flag).
                    await privacy.scenePhaseChanged(to: .background)
                }
            }
        case .active:
            openStoreIfNeeded()
            if appLock.shouldAutoPrompt {
                let lock = appLock
                Task { await lock.unlock() }
            }
            return enqueueLifecycle { [self] in reconcileScan() }
        default:
            return enqueueLifecycle {}
        }
    }

    private func enqueueLifecycle(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = lifecycleChain
        let task = Task {
            await previous?.value
            await work()
        }
        lifecycleChain = task
        return task
    }

    // MARK: - Lens

    /// Starts the camera; frames flow to the lens pipeline off the main actor. Refused in the
    /// background.
    public func startLens() async throws {
        guard let camera, phase != .background else { return }
        try await camera.start()
        isLensRunning = phase != .background
        if !isLensRunning { camera.stop() }
    }

    public func stopLens() {
        camera?.stop()
        isLensRunning = false
    }

    // MARK: - Photo scan

    /// Starts (or resumes) the on-device photo scan. No-op when recognition is unavailable.
    public func startPhotoScan() {
        guard recognition != .unavailable else {
            scanStatus = .unavailable
            return
        }
        wantsScan = true
        reconcileScan()
    }

    /// Starts the scan when it is wanted and nothing forbids it (no model yet, backgrounded, or a
    /// forget / erase in progress).
    private func reconcileScan() {
        guard wantsScan, scanTask == nil, destructiveOperations == 0, phase != .background,
            let embedder
        else { return }
        let job = PhotoScanJob(
            source: dependencies.photoLibrary, detector: dependencies.detector, embedder: embedder,
            store: lazyStore, clusterer: FaceClusterer(), config: dependencies.scanConfig,
            isSystemicFailure: { ($0 as? HaloVisionError)?.isRecognitionUnavailable == true })
        scanRunID += 1
        let runID = scanRunID
        scanStatus = .scanning
        Task { [weak self] in
            for await progress in job.progress {
                guard let self, self.scanRunID == runID else { return }
                self.scanProgress = progress
            }
        }
        scanTask = Task { [weak self] in
            let outcome: Result<ScanProgress, any Error>
            do {
                outcome = .success(try await job.run())
            } catch {
                outcome = .failure(error)
            }
            self?.scanEnded(runID: runID, outcome)
        }
    }

    private func scanEnded(runID: Int, _ outcome: Result<ScanProgress, any Error>) {
        guard runID == scanRunID else { return }
        scanTask = nil
        switch outcome {
        case .success(let progress):
            scanProgress = progress
            scanStatus = .finished
            wantsScan = false
            let enrollment = self.enrollment
            Task { await enrollment.load() }
        case .failure(let error) where error is CancellationError:
            scanStatus = wantsScan ? .paused : .idle
        case .failure:
            scanStatus = .failed
            wantsScan = false
        }
    }

    /// Cancels the running scan and waits until it has stopped writing. It stays wanted, so it
    /// resumes from its persisted cursor on the next `reconcileScan()`.
    func pauseScan() async {
        guard let task = scanTask else { return }
        task.cancel()
        await task.value
    }

    // MARK: - Labels

    /// Every identity in the store. The label ranker needs other people's handles too, so a handle
    /// shared by two people is dropped instead of attributed (its ambiguity guard).
    public func storeWideIdentities() async throws -> [Identity] {
        var all: [Identity] = []
        for person in try await store.allPeople() {
            all += try await store.identities(for: person.id)
        }
        return all
    }

    /// The label the lens shows for `person`, ranked with store-wide identities and the latest digest.
    public func label(for person: Person, now: Date = Date()) async -> LabelData {
        let identities = (try? await storeWideIdentities()) ?? []
        let digest = (try? await store.latestDigest()) ?? nil
        return labelRanker.label(for: person, identities: identities, digest: digest, now: now)
    }
}

// MARK: - Store events (forget / erase ordering, gallery refresh)

extension AppEnvironment: ObservedStoreDelegate {
    func storeWillForget(_ id: PersonID) async {
        destructiveOperations += 1
        await pauseScan()
        await refresher?.exclude(id)
    }

    func storeDidForget(_ id: PersonID, succeeded: Bool) async {
        if !succeeded { await refresher?.include(id) }
        await refresher?.requestRefresh()
        peopleRevision += 1
        destructiveOperations -= 1
        reconcileScan()
    }

    func storeWillEraseEverything() async {
        destructiveOperations += 1
        wantsScan = false
        await pauseScan()
        stopLens()
        await refresher?.reset()
    }

    func storeDidEraseEverything(succeeded: Bool) async {
        if succeeded {
            await refresher?.reset()
            scanProgress = nil
            scanStatus = recognition == .unavailable ? .unavailable : .idle
            enrollment = EnrollmentViewModel(store: store, thumbnails: dependencies.thumbnails)
            resetGeneration += 1
        } else {
            await refresher?.requestRefresh()
        }
        peopleRevision += 1
        destructiveOperations -= 1
    }

    func storeDidChangeIdentities() async {
        peopleRevision += 1
        await refresher?.requestRefresh()
    }
}

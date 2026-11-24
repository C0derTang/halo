import Foundation
import HaloBridgeKit
import HaloClustering
import HaloCore
import HaloImport
import HaloLabels
import HaloLens
import HaloMatching
import HaloMemory
import HaloUI
import HaloVision
import Observation
import SwiftUI

/// The app's composition root: builds the real services once at launch and owns the app-wide
/// lifecycle and privacy rules.
///
/// Load-bearing rules (invariants 2, 3, 5, 7):
/// - **One camera.** `camera` is the only capture source. The Live Lens drives it through `lens`
///   (`LensScreenModel`); backgrounding and the kill switch stop that same instance.
/// - **Writers stop before erasure.** `forget` and the kill switch (through `store`, the only store
///   screens get) first stop every writer: the photo scan (cancelled and awaited), the contacts
///   and digest imports (awaited for a forget; cancelled and awaited for the kill switch) and the
///   lens's recognition-log writes. The kill switch also stops the camera and clears the lens
///   gallery before `eraseEverything` runs. New imports wait until the operation has finished.
///   Afterwards every in-memory copy (gallery, lens votes and labels, triage view model) is reset.
/// - **Names leave the screen at once.** A forgotten person is dropped from the lens gallery
///   (`setMatcher`) before the store deletes them, and `LensScreenModel.forgetLabel` runs as soon as
///   the forget succeeded.
/// - **The gallery follows identity changes.** Every confirm / forget / deleteEmbeddings / erase /
///   digest import / upsert rebuilds the `GalleryMatcher` and calls `LensPipeline.setMatcher`
///   (debounced, off the main actor). A forgotten person is dropped from the lens *before* the store
///   deletes them.
/// - **Nothing per frame on the main actor.** Camera frames go straight from the capture queue to
///   the `LensPipeline` actor (`LensScreenModel`'s frame handler calls `submit`).
/// - **Missing model is not a crash.** `recognition == .unavailable`: no lens pipeline, no photo
///   scan; the rest of the app works.
/// - **One handle normalizer and one ranker** (device region, unknown -> "ZZ", never a guessed "US")
///   shared by the contacts importer, the digest importer, the handle resolver, the People screens,
///   the memory hook refresher and the label ranker the lens and the person detail screen both use.
/// - **Memory hooks** (`AppEnvironmentMemory.swift`): the refresher is a writer like the imports:
///   off the main actor, never during a forget / erase, cancelled and awaited by both. Labels on the
///   lens and the detail screen include the person's hooks and rebuild when hooks change.
/// - **Whisper** (`AppEnvironmentWhisper.swift`): fed by the lens's overlay updates, only while
///   enabled, the lens runs, the app is unlocked and in the foreground; every lens stop (tab, lock,
///   background, kill switch) cancels speech and releases the `.playback` + `.mixWithOthers` audio
///   session.
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
    /// The app's one camera (nil on the macOS host).
    public let camera: (any CameraControlling)?
    public let policy: MatchPolicy
    /// `.halodigest` import status for the UI. Imports run through `importDigest(url:)`.
    public let digestImport: DigestImportModel
    /// nil until the model loaded, and forever when recognition is unavailable.
    public private(set) var lensPipeline: LensPipeline?
    /// The Live Lens screen model, driving `camera`. nil until recognition is known (and without a
    /// camera). When the model is missing it runs the preview with `recognitionAvailable == false`.
    public private(set) var lens: LensScreenModel?
    /// The embedding space of the loaded model; nil until loaded and when recognition is unavailable.
    public private(set) var embeddingSpace: EmbeddingSpace?

    // MARK: Observable state

    public private(set) var recognition: RecognitionStatus = .loading
    public var recognitionAvailable: Bool { recognition == .available }
    public private(set) var isStoreAvailable = false
    /// A lens session is running (the camera is on or coming up).
    public var isLensRunning: Bool { lens?.isRunning ?? false }
    public private(set) var scanStatus: PhotoScanStatus = .idle
    public private(set) var scanProgress: ScanProgress?
    public private(set) var phase: ScenePhase = .active
    /// Number of people the lens can currently recognize.
    public private(set) var galleryPersonCount = 0
    /// Bumped after every identity change; screens that cache labels re-read on change.
    public internal(set) var peopleRevision = 0
    /// Bumped when every screen must rebuild from scratch (kill switch, store opened late).
    public private(set) var resetGeneration = 0

    // MARK: Whisper

    /// Announces recognized people through private headphones. Observe `pendingDeviceConfirmation`
    /// for the Bluetooth prompt; answer through `confirmWhisperDevice(_:)`.
    public let whisper: WhisperAnnouncer
    /// The Whisper toggles (off by default). Change them through `setWhisperSettings(_:)`.
    public internal(set) var whisperSettings: WhisperSettings
    @ObservationIgnored let whisperComponents: WhisperComponents
    /// Forwards audio route changes to `whisper` for the app's lifetime.
    @ObservationIgnored private var whisperRouteObserver: WhisperRouteObserver?
    /// The `.playback` + `.mixWithOthers` session is active (only while Whisper may run).
    @ObservationIgnored var isWhisperAudioActive = false
    /// A Moment sheet is open: Whisper pauses (dictation owns the audio session).
    @ObservationIgnored var isMomentOpen = false
    /// The open Moment's model: its dictation is stopped before Whisper's session comes back.
    @ObservationIgnored var openMoment: MomentsModel?
    /// What Whisper was last fed (labeled people + states) and when; rect-only moves are skipped.
    @ObservationIgnored var lastWhisperFeed: (signature: Set<WhisperFeedKey>, at: Date)?

    /// The matcher most recently handed to the lens (tests).
    @ObservationIgnored private(set) var activeGallery: GalleryMatcher?

    // MARK: Private

    @ObservationIgnored let dependencies: AppDependencies
    @ObservationIgnored private let lazyStore: LazyStore
    @ObservationIgnored private var refresher: GalleryRefresher?
    @ObservationIgnored private var embedder: AppDependencies.Embedder?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleChain: Task<Void, Never>?
    /// Forgets / erases in progress. The scan does not (re)start and imports do not start while any
    /// is running.
    @ObservationIgnored private(set) var destructiveOperations = 0
    /// The kill switch is running: the lens does not (re)start.
    @ObservationIgnored private(set) var isErasing = false
    /// Imports parked until the running forget / erase has finished.
    @ObservationIgnored private var destructiveWaiters: [CheckedContinuation<Void, Never>] = []
    /// Running contacts import (onboarding or Settings). Owned here so forget / erase can stop it.
    @ObservationIgnored var contactsTask: Task<ContactsImportResult, any Error>?
    /// The `.halodigest` import currently writing (at most one). Owned here so forget / erase can
    /// stop it.
    @ObservationIgnored var digestTask: Task<Void, Never>?
    /// Tail of the queue of requested digest imports (they run one at a time, in order).
    @ObservationIgnored var digestQueue: Task<Bool, Never>?
    /// Bumped by every kill switch that SUCCEEDED (before waiting imports may resume). An import
    /// or scan resume requested before it is dropped, never run afterwards; a failed erase drops
    /// nothing.
    @ObservationIgnored private(set) var eraseGeneration = 0
    /// Writes on-device memory hooks from the latest digest. A writer: see `AppEnvironmentMemory`.
    @ObservationIgnored let memoryRefresher: MemoryHookRefresher
    /// The refresh pass currently running (at most one).
    @ObservationIgnored var memoryTask: Task<Void, Never>?
    @ObservationIgnored var memoryRefreshPending = false
    @ObservationIgnored var memoryRunID = 0
    /// Lens label source with a cached store-wide identity set, invalidated on identity changes.
    @ObservationIgnored let lensLabels: LensLabelStore
    /// Progress subscribers (onboarding). Finished when the scan is over (not when it pauses).
    @ObservationIgnored private var scanObservers: [UUID: AsyncStream<ScanProgress>.Continuation] = [:]
    /// The Lens tab is on screen: the lens restarts on `.active` and after the kill switch.
    @ObservationIgnored private var lensVisible = false
    /// The user asked for a scan that has not finished yet (it may be paused).
    @ObservationIgnored private var wantsScan = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanRunID = 0
    /// People being or already forgotten. Owned here (not only by the refresher) so a refresher
    /// created while a forget is in flight (e.g. during model load) starts with them excluded.
    @ObservationIgnored private var excludedPeople: Set<PersonID> = []

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
        digestImport = DigestImportModel(
            importer: DigestImporter(
                keyStore: dependencies.keyStore, store: CancellableWriteStore(base: store),
                normalization: HandleNormalization(normalizer: normalizer)))

        camera = dependencies.makeCamera()
        lensLabels = LensLabelStore(base: store)
        // Writes straight to the store (not through `store`): one label rebuild per pass instead of
        // one per person; forget / erase stop it explicitly.
        memoryRefresher = MemoryHookRefresher(
            store: lazyStore, generator: dependencies.hookGenerator,
            minimumInterval: dependencies.memoryRefreshInterval,
            normalizeHandle: { normalizer.normalize($0) })

        let whisperComponents = dependencies.makeWhisper()
        self.whisperComponents = whisperComponents
        let settings = whisperComponents.settings.load()
        whisperSettings = settings
        let whisper = WhisperAnnouncer(
            settings: settings, route: whisperComponents.route, devices: whisperComponents.devices,
            speech: whisperComponents.speech, haptics: whisperComponents.haptics)
        self.whisper = whisper
        whisperRouteObserver = WhisperRouteObserver { [weak self] in self?.whisperRouteChanged() }

        isStoreAvailable = lazyStore.openIfNeeded()
        store.setDelegate(self)
        observeAppLock()
    }

    /// Stops the lens whenever the app locks and restarts it (if on screen) once unlocked: nothing
    /// is captured, recognized or logged behind the privacy cover.
    private func observeAppLock() {
        withObservationTracking {
            _ = appLock.isLocked
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.appLockChanged()
                self.observeAppLock()
            }
        }
    }

    private func appLockChanged() {
        if appLock.isLocked {
            stopLens()
        } else if lensVisible {
            Task { await startLens() }
        }
    }

    /// The real app.
    public static func live() -> AppEnvironment {
        AppEnvironment(dependencies: .live())
    }

    /// The same normalizer, wrapped for HaloImport.
    public var handleNormalization: HandleNormalization { HandleNormalization(normalizer: handleNormalizer) }

    /// Contacts importer sharing the app's normalizer. Its writes stop at the first one after its
    /// task is cancelled (the kill switch). Run it through `importContacts()`.
    func makeContactsImporter() -> ContactsImporter {
        ContactsImporter(
            store: CancellableWriteStore(base: store), source: dependencies.contacts,
            normalization: handleNormalization)
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
            // Never crash on a missing or broken model: the lens preview runs without recognition,
            // and the scan is unavailable.
            wantsScan = false
            scanStatus = .unavailable
            finishScanObservers()
            lens = makeLens(source: UnavailableLensTrackSource(), recognitionAvailable: false)
            recognition = .unavailable
            return
        }
        let pipeline = LensPipeline(
            detector: dependencies.detector, embedder: embedder, matcher: NullMatcher(),
            policy: dependencies.policy, config: dependencies.lensConfig)
        let refresher = GalleryRefresher(
            store: lazyStore, space: embedder.space, sink: pipeline, debounce: dependencies.galleryDebounce,
            excluded: excludedPeople
        ) { [weak self] matcher in
            await self?.galleryApplied(matcher)
        }
        self.embedder = embedder
        self.refresher = refresher
        embeddingSpace = embedder.space
        lensPipeline = pipeline
        await refresher.refreshNow()
        lens = makeLens(source: pipeline, recognitionAvailable: true)
        recognition = .available
        reconcileScan()
        await resumePhotoScanIfConsented()
    }

    /// The lens screen model over `camera`. Labels come from the shared ranker with store-wide
    /// identities (`LensLabelStore`) and the person's memory hooks, the same as the person detail
    /// screen. Its overlay updates feed Whisper.
    private func makeLens(source: any LensTrackSource, recognitionAvailable: Bool) -> LensScreenModel? {
        guard let camera else { return nil }
        let model = LensScreenModel(
            source: source, camera: camera, store: lensLabels, ranker: labelRanker,
            recognitionAvailable: recognitionAvailable, hooks: Self.hookReader(store))
        model.onItemsChange = { [weak self] items in self?.lensItemsChanged(items) }
        return model
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
            // The lock may have engaged just now (timeout): nothing runs behind the cover, not
            // even until the lock observer's hop.
            if appLock.isLocked { stopLens() }
            openStoreIfNeeded()
            if appLock.shouldAutoPrompt {
                let lock = appLock
                Task { await lock.unlock() }
            }
            if lensVisible {
                Task { await self.startLens() }
            }
            return enqueueLifecycle { [self] in
                // Retry a rebuild that failed earlier (e.g. a read while the device was locked).
                await refresher?.requestRefresh()
                reconcileScan()
                // Off the main actor; rate-limited by the refresher itself.
                refreshMemoryHooks()
            }
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

    /// The Lens tab appeared: start the lens, and restart it after backgrounding / the kill switch.
    public func lensAppeared() async {
        lensVisible = true
        await startLens()
    }

    /// The Lens tab disappeared: stop the camera.
    public func lensDisappeared() {
        lensVisible = false
        stopLens()
    }

    /// Starts a lens session (camera on, frames to the pipeline off the main actor). Refused while
    /// the app is locked (it starts on unlock), in the background and during the kill switch. A
    /// `stopLens()` while the camera is coming up wins (`LensScreenModel.start` stops the camera
    /// again).
    public func startLens() async {
        guard let lens, phase != .background, !isErasing, !appLock.isLocked else { return }
        // A new lens session: everyone may be announced again.
        if !lens.isRunning { whisper.resetSession() }
        await lens.start()
        syncWhisperAudio()
    }

    /// Stops the lens session and Whisper with it (speech cancelled, audio session released).
    public func stopLens() {
        lens?.stop()
        stopWhisper()
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
                self.publishScanProgress(progress)
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
            publishScanProgress(progress)
            finishScanObservers()
            let enrollment = self.enrollment
            Task { await enrollment.load() }
        case .failure(let error) where error is CancellationError:
            scanStatus = wantsScan ? .paused : .idle
            if !wantsScan { finishScanObservers() }
        case .failure:
            scanStatus = .failed
            wantsScan = false
            finishScanObservers()
        }
    }

    /// Progress of the current (or next) scan run, until the scan is over: finished, failed,
    /// unavailable or erased. A pause (backgrounding, a forget) does not end it. Finishes at once
    /// when no scan is wanted.
    public func photoScanUpdates() -> AsyncStream<ScanProgress> {
        let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)
        if let scanProgress, scanTask != nil { continuation.yield(scanProgress) }
        guard wantsScan || scanTask != nil else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        scanObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.scanObservers[id] = nil }
        }
        return stream
    }

    private func publishScanProgress(_ progress: ScanProgress) {
        for observer in scanObservers.values { observer.yield(progress) }
    }

    private func finishScanObservers() {
        let observers = scanObservers.values
        scanObservers = [:]
        for observer in observers { observer.finish() }
    }

    /// Cancels the running scan and waits until it has stopped writing. It stays wanted, so it
    /// resumes from its persisted cursor on the next `reconcileScan()`.
    func pauseScan() async {
        guard let task = scanTask else { return }
        task.cancel()
        await task.value
    }

    // MARK: - Writers vs. destructive operations

    /// Parks until no forget / erase is running. Imports call this before they start writing.
    func whenNoDestructiveOperation() async {
        while destructiveOperations > 0 {
            await withCheckedContinuation { destructiveWaiters.append($0) }
        }
    }

    private func destructiveOperationEnded() {
        destructiveOperations -= 1
        guard destructiveOperations == 0 else { return }
        let waiters = destructiveWaiters
        destructiveWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Waits for the running imports. With `cancel`, cancels them first: their next store write
    /// throws (`CancellableWriteStore`), and a write already in flight lands before this returns.
    private func stopImports(cancel: Bool) async {
        let contacts = contactsTask
        let digest = digestTask
        if cancel {
            contacts?.cancel()
            digest?.cancel()
        }
        _ = try? await contacts?.value
        await digest?.value
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
        let hooks = await hooks(for: person.id, now: now)
        return labelRanker.label(for: person, identities: identities, digest: digest, hooks: hooks, now: now)
    }
}

// MARK: - Store events (forget / erase ordering, gallery refresh)

extension AppEnvironment: ObservedStoreDelegate {
    func storeWillForget(_ id: PersonID) async {
        destructiveOperations += 1
        excludedPeople.insert(id)
        // Drop them from the lens first: `setMatcher` clears every on-screen name at once.
        await refresher?.exclude(id)
        await pauseScan()
        // The memory hook refresher is a writer: stop it before anything is deleted.
        await stopMemoryRefresh()
        // Let running imports finish their writes (new ones wait for this forget).
        await stopImports(cancel: false)
        // Recognition-log writes the lens already issued land before the delete.
        await lens?.settle()
    }

    func storeDidForget(_ id: PersonID, succeeded: Bool) async {
        lensLabels.invalidate()
        if succeeded {
            // The refresher may have been created during the forget (model load).
            await refresher?.exclude(id)
            lens?.forgetLabel(id)
        } else {
            excludedPeople.remove(id)
            await refresher?.include(id)
        }
        await refresher?.requestRefresh()
        peopleRevision += 1
        destructiveOperationEnded()
        reconcileScan()
    }

    func storeWillEraseEverything() async {
        destructiveOperations += 1
        isErasing = true
        wantsScan = false
        stopLens()
        await refresher?.reset()
        // Every writer is stopped and has finished writing before the erase.
        await pauseScan()
        await stopMemoryRefresh()
        await stopImports(cancel: true)
        await lens?.settle()
        finishScanObservers()
    }

    func storeDidEraseEverything(succeeded: Bool) async {
        // The kill switch is final: nothing it stopped resumes by itself.
        wantsScan = false
        lensLabels.invalidate()
        if succeeded {
            // Before `destructiveOperationEnded()` resumes the waiting imports: they see the bump
            // and are dropped. A failed erase bumps nothing, so nothing is dropped.
            eraseGeneration += 1
            excludedPeople = []
            await refresher?.reset()
            scanProgress = nil
            scanStatus = recognition == .unavailable ? .unavailable : .idle
            enrollment = EnrollmentViewModel(store: store, thumbnails: dependencies.thumbnails)
            // "Erase all Halo data" includes the Whisper toggles and trusted Bluetooth devices.
            eraseWhisperData()
            resetGeneration += 1
        } else {
            await refresher?.requestRefresh()
        }
        peopleRevision += 1
        isErasing = false
        destructiveOperationEnded()
        if lensVisible, phase != .background {
            Task { await self.startLens() }
        }
    }

    func storeDidChangeIdentities() async {
        lensLabels.invalidate()
        peopleRevision += 1
        await refresher?.requestRefresh()
    }

    func storeDidChangeHooks() async {
        hooksDidChange()
    }
}

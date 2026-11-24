import CoreGraphics
import CoreVideo
import Foundation
import HaloCore
import HaloLens
import HaloUI
import Observation
import Synchronization

/// Screen model for the Live Lens: camera on/off, pipeline output -> overlay items, per-person
/// label cache, and the once-per-session recognition log.
///
/// Load-bearing rules:
/// - Known people only (invariant 1): the store and ranker are only ever asked about a
///   `PersonID` taken from a `.known` track identity. `.unknown` / `.ambiguous` tracks are never
///   looked up and never carry a label, so they render as a text-free ring. A known person that
///   is missing or not `confirmed` in the store gets no label either (invariant 3).
/// - Frame budget (invariant 7): frames go from the camera's capture queue straight to
///   `LensTrackSource.submit`; the main actor only maps the (small) per-frame track list.
/// - `logRecognition` runs once per person per lens session (`start()` ... `stop()`).
/// - `forgetLabel(_:)` removes a forgotten person's name synchronously; that person is never
///   looked up, labeled or logged again by this model.
///
/// Ownership: one model per `LensPipeline`, owned for the app's lifetime (the composition root).
/// The pipeline's `tracks` stream is single-consumer and cancelling its iteration finishes it, so
/// the subscription is created on the first `start()`, kept across `stop()` / `start()` (output is
/// ignored while stopped), and cancelled only when the model is deallocated.
@MainActor @Observable
public final class LensScreenModel {
    /// What the overlay draws, one per live track, sorted by track ID.
    public private(set) var items: [LensOverlayItem] = []
    /// The camera frame the item boxes are normalized against; nil until the first frame.
    public private(set) var frame: LensOverlayFrame?
    /// A lens session is active (between `start()` and `stop()`).
    public private(set) var isRunning = false
    /// The camera has started for this session (the session is configured and capturing).
    public private(set) var isCapturing = false
    /// User-facing camera error (e.g. access denied); nil when none.
    public private(set) var cameraError: String?
    /// False when the face model is missing: the preview runs, nothing is recognized.
    public let recognitionAvailable: Bool
    /// Debug overlay toggle.
    public var showsMetrics = false
    /// Latest pipeline numbers, refreshed by `refreshMetrics()` while the debug overlay is shown.
    public private(set) var metrics: LensMetrics?
    /// At least one item carries a (confirmed person's) label. Changes far less often than
    /// `items`, so views that only need this don't re-render on every box move.
    public private(set) var hasRecognizedPeople = false
    /// Called on the main actor whenever `items` changes (Whisper is fed from here).
    @ObservationIgnored public var onItemsChange: (@MainActor ([LensOverlayItem]) -> Void)?

    private let source: any LensTrackSource
    private let camera: any CameraControlling
    private let store: any PeopleStoring & PrivacyStoring
    private let ranker: any LabelRanking
    /// The person's unexpired memory hooks, passed to the ranker.
    private let hooks: @Sendable (PersonID, Date) async -> [MemoryHook]
    private let now: @Sendable () -> Date
    private let frameBox = LensFrameRecorder()

    /// Pipeline subscription. Held in a Sendable box so the nonisolated `deinit` can cancel it.
    private let subscription = LensSubscription()
    @ObservationIgnored private var latestTracks: [LensTrack] = []
    /// Label cache, per person. Survives track loss; cleared on `start()` and `refreshLabels()`.
    @ObservationIgnored private var labels: [PersonID: LabelData] = [:]
    /// People whose label is being built for the current `labelGeneration`.
    @ObservationIgnored private var loading: Set<PersonID> = []
    /// People with no label this generation (missing, unconfirmed, or the load failed). Not retried
    /// every frame; retried on the next `refreshLabels()` / session.
    @ObservationIgnored private var unlabeled: Set<PersonID> = []
    @ObservationIgnored private var labelGeneration = 0
    @ObservationIgnored private var loggedThisSession: Set<PersonID> = []
    /// Forgotten people (irreversible; IDs are never reused). Never looked up, labeled or logged.
    @ObservationIgnored private var forgotten: Set<PersonID> = []
    @ObservationIgnored private var pending: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextPendingID = 0
    /// Bumped per `start()`, so a camera failure from an earlier session is ignored.
    @ObservationIgnored private var sessionID = 0

    public convenience init(
        pipeline: LensPipeline, camera: any CameraControlling, store: any PeopleStoring & PrivacyStoring,
        ranker: any LabelRanking = MinimalLabelRanker(), recognitionAvailable: Bool = true,
        hooks: @escaping @Sendable (PersonID, Date) async -> [MemoryHook] = { _, _ in [] },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            source: pipeline, camera: camera, store: store, ranker: ranker,
            recognitionAvailable: recognitionAvailable, hooks: hooks, now: now)
    }

    public init(
        source: any LensTrackSource, camera: any CameraControlling, store: any PeopleStoring & PrivacyStoring,
        ranker: any LabelRanking = MinimalLabelRanker(), recognitionAvailable: Bool = true,
        hooks: @escaping @Sendable (PersonID, Date) async -> [MemoryHook] = { _, _ in [] },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.hooks = hooks
        self.camera = camera
        self.store = store
        self.ranker = ranker
        self.recognitionAvailable = recognitionAvailable
        self.now = now
    }

    deinit {
        subscription.cancel()
    }

    // MARK: - Session

    /// Starts a lens session: camera on, frames into the pipeline. A new session re-logs
    /// recognitions and rebuilds labels (so a digest imported meanwhile shows up).
    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        cameraError = nil
        loggedThisSession = []
        resetLabels()
        subscribeIfNeeded()
        sessionID += 1
        if let reporting = camera as? any CameraFailureReporting {
            reporting.setFailureHandler(makeFailureHandler(session: sessionID))
        }
        if recognitionAvailable { camera.setFrameHandler(makeFrameHandler()) }
        do {
            try await camera.start()
            if isRunning {
                isCapturing = true
            } else {
                // stop() ran while start() was suspended (e.g. on the permission prompt) and may
                // have reached the camera first: make sure it ends up off.
                camera.stop()
            }
        } catch {
            guard isRunning else { return }  // stopped while starting
            camera.setFrameHandler(nil)
            isRunning = false
            cameraError = Self.message(for: error)
        }
    }

    /// Ends the session: camera off, overlay cleared.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        isCapturing = false
        camera.setFrameHandler(nil)
        camera.stop()
        latestTracks = []
        items = []
        hasRecognizedPeople = false
        loggedThisSession = []
        onItemsChange?([])
    }

    /// The people graph or digest changed (digest import, edit, forget): rebuild the labels of the
    /// people on screen. Their current labels stay up until the new ones are ready.
    public func refreshLabels() {
        labelGeneration += 1
        let visible = Set(latestTracks.compactMap(\.personID)).subtracting(forgotten)
        labels = labels.filter { visible.contains($0.key) }
        loading = []
        unlabeled = []
        for person in visible.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            loadLabel(for: person)
        }
        rebuildItems()
    }

    /// "Forget this person" just happened: drop their label NOW, without a store round-trip, so
    /// the name disappears from the lens immediately (invariant 3). In-flight loads for them are
    /// discarded, and they are never looked up, labeled or logged again by this model.
    public func forgetLabel(_ person: PersonID) {
        forgotten.insert(person)
        labels[person] = nil
        loading.remove(person)
        unlabeled.remove(person)
        rebuildItems()
    }

    public func refreshMetrics() async {
        metrics = await source.metrics
    }

    // MARK: - Pipeline output

    private func subscribeIfNeeded() {
        // Subscribe once for the model's lifetime: cancelling an AsyncStream iteration finishes
        // the stream, so the subscription must not be torn down on stop().
        let stream = source.tracks
        subscription.startIfNeeded {
            Task { [weak self] in
                for await tracks in stream {
                    guard let self else { return }
                    self.apply(tracks)
                }
            }
        }
    }

    /// One pipeline result. Ignored while stopped.
    func apply(_ tracks: [LensTrack]) {
        guard isRunning else { return }
        latestTracks = tracks
        for track in tracks {
            guard let person = Self.knownPerson(track), !forgotten.contains(person) else { continue }
            logOnce(person)
            if labels[person] == nil, !loading.contains(person), !unlabeled.contains(person) {
                loadLabel(for: person)
            }
        }
        rebuildItems()
    }

    /// Publishes only on change, so an unchanged frame doesn't invalidate the overlay.
    private func rebuildItems() {
        let next = latestTracks.map { track in
            LensOverlayItem(
                trackID: track.trackID, rect: track.smoothedBox, state: Self.hologramState(track.state),
                label: Self.knownPerson(track).flatMap { labels[$0] })
        }
        let recognized = next.contains { $0.label != nil }
        if recognized != hasRecognizedPeople { hasRecognizedPeople = recognized }
        guard next != items else { return }
        items = next
        onItemsChange?(next)
    }

    /// The person a track is recognized as, only when its stable identity is `.known`.
    private static func knownPerson(_ track: LensTrack) -> PersonID? {
        guard case .known(let person, _, _) = track.identity else { return nil }
        return person
    }

    private static func hologramState(_ state: LensTrack.State) -> HologramState {
        switch state {
        case .appearing: .appearing
        case .stable: .stable
        case .lost: .lost
        }
    }

    // MARK: - Recognition log

    private func logOnce(_ person: PersonID) {
        guard loggedThisSession.insert(person).inserted else { return }
        let store = self.store
        let date = now()
        spawn {
            // Best effort: a failed write is not retried this session (no per-frame retry storm).
            try? await store.logRecognition(of: person, at: date)
        }
    }

    // MARK: - Labels

    private func resetLabels() {
        labelGeneration += 1
        labels = [:]
        loading = []
        unlabeled = []
    }

    private func loadLabel(for person: PersonID) {
        let generation = labelGeneration
        loading.insert(person)
        let store = self.store
        let ranker = self.ranker
        let hooks = self.hooks
        let now = self.now
        spawn { [weak self] in
            let label = await Self.buildLabel(
                for: person, store: store, ranker: ranker, hooks: hooks, now: now)
            self?.finishLoad(person, label: label, generation: generation)
        }
    }

    private func finishLoad(_ person: PersonID, label: LabelData?, generation: Int) {
        // Superseded by a refresh, or forgotten while loading.
        guard generation == labelGeneration, !forgotten.contains(person) else { return }
        loading.remove(person)
        if let label {
            labels[person] = label
        } else {
            labels[person] = nil
            unlabeled.insert(person)
        }
        rebuildItems()
    }

    /// Builds the label off the main actor. Nil for a missing or unconfirmed person, or when the
    /// store fails. A digest / hook read failure only drops the chips derived from it.
    nonisolated private static func buildLabel(
        for id: PersonID, store: any PeopleStoring & PrivacyStoring, ranker: any LabelRanking,
        hooks: @Sendable (PersonID, Date) async -> [MemoryHook], now: @Sendable () -> Date
    ) async -> LabelData? {
        do {
            guard let person = try await store.person(id), person.confirmed, person.id == id else {
                return nil
            }
            let identities = try await store.identities(for: id)
            let digest = try? await store.latestDigest()
            let date = now()
            let personHooks = await hooks(id, date)
            return ranker.label(
                for: person, identities: identities, digest: digest, hooks: personHooks, now: date)
        } catch {
            return nil
        }
    }

    // MARK: - Frames

    /// Runs on the camera's capture queue: hand the frame to the pipeline, and publish the frame
    /// geometry when it changes (once per session in practice).
    private func makeFrameHandler() -> @Sendable (VideoFrame) -> Void {
        let source = self.source
        let recorder = frameBox
        return { [weak self] videoFrame in
            source.submit(videoFrame)
            if let changed = recorder.record(videoFrame) {
                Task { @MainActor [weak self] in self?.frame = changed }
            }
        }
    }

    /// Runs on the camera's queue when it stopped on its own (the demo video became unreadable):
    /// end this session on the main actor and show why.
    private func makeFailureHandler(session: Int) -> @Sendable (any Error) -> Void {
        { [weak self] error in
            let message = Self.message(for: error)
            Task { @MainActor [weak self] in self?.cameraFailed(message: message, session: session) }
        }
    }

    func cameraFailed(message: String, session: Int) {
        guard isRunning, session == sessionID else { return }
        stop()
        cameraError = message
    }

    // MARK: - Helpers

    private func spawn(_ work: @escaping @MainActor () async -> Void) {
        let id = nextPendingID
        nextPendingID += 1
        pending[id] = Task { [weak self] in
            await work()
            self?.pending[id] = nil
        }
    }

    /// Whether the pipeline subscription is live (tests).
    var isSubscribed: Bool { subscription.isActive }

    /// Waits for in-flight label loads and log writes (tests).
    func settle() async {
        while let (_, task) = pending.first {
            await task.value
        }
    }

    nonisolated static func message(for error: any Error) -> String {
        if let error = error as? any LensCameraUserMessage { return error.userMessage }
        #if os(iOS)
            if let cameraError = error as? CameraSourceError {
                switch cameraError {
                case .notAuthorized: return "Camera access is off. Turn it on in Settings to use the lens."
                case .noCamera: return "No camera is available."
                case .cannotAddInput, .cannotAddOutput: return "The camera could not be started."
                }
            }
        #endif
        return "The camera could not be started."
    }
}

/// Remembers the last frame geometry seen on the capture queue, so the main actor only hears about
/// changes.
final class LensFrameRecorder: Sendable {
    private let last = Mutex<LensOverlayFrame?>(nil)

    /// Returns the frame's geometry when it differs from the previous frame's, else nil.
    func record(_ frame: VideoFrame) -> LensOverlayFrame? {
        let geometry = LensOverlayFrame(
            bufferSize: CGSize(
                width: CVPixelBufferGetWidth(frame.pixelBuffer),
                height: CVPixelBufferGetHeight(frame.pixelBuffer)),
            orientation: frame.orientation)
        return last.withLock { stored -> LensOverlayFrame? in
            if stored == geometry { return nil }
            stored = geometry
            return geometry
        }
    }
}

/// Owns the pipeline subscription task. Sendable so the model's nonisolated `deinit` can cancel it.
final class LensSubscription: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    /// Starts the subscription unless one exists. `make` runs at most once.
    func startIfNeeded(_ make: () -> Task<Void, Never>) {
        task.withLock { current in
            if current == nil { current = make() }
        }
    }

    func cancel() {
        let current = task.withLock { current -> Task<Void, Never>? in
            defer { current = nil }
            return current
        }
        current?.cancel()
    }

    var isActive: Bool { task.withLock { $0 != nil } }
}

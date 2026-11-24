import CoreGraphics
import CoreVideo
import Foundation
import HaloBridgeKit
import HaloCore
import HaloImport
import HaloStore
import HaloUI
import HaloVision
import ImageIO
import Synchronization
import Testing

@testable import HaloAppCore

// Synthetic fakes for the AppEnvironment tests. No real faces, photos or contacts: "faces" are
// hand-placed boxes and "embeddings" are 4-float unit vectors. Type names are prefixed `Env` so they
// cannot collide with other HaloAppCore test files.

let envSpace = EmbeddingSpace(modelID: "env-fake", dimension: 4)
let aliceVector: [Float] = [1, 0, 0, 0]
let bobVector: [Float] = [0, 1, 0, 0]

/// Ordered, thread-safe log of what the fakes saw.
final class EnvEventLog: Sendable {
    private let entries = Mutex<[String]>([])

    func record(_ event: String) { entries.withLock { $0.append(event) } }
    var events: [String] { entries.withLock { $0 } }
    func count(_ event: String) -> Int { events.filter { $0 == event }.count }
    func index(_ event: String) -> Int? { events.firstIndex(of: event) }
}

/// Real in-memory `PeopleStore`, recording the calls the ordering tests care about.
final class EnvRecordingStore: AppStoring {
    let base: PeopleStore
    let log: EnvEventLog
    /// When set, `forget` throws without deleting anything.
    let failForget = Mutex(false)
    /// When set, `forget` parks on it before touching the store.
    let forgetGate = Mutex<EnvGate?>(nil)
    /// When set, `saveDigest` parks on it before touching the store (an import "in flight").
    let saveDigestGate = Mutex<EnvGate?>(nil)
    /// When set, `eraseEverything` throws without erasing anything.
    let failErase = Mutex(false)
    /// When set, `scanCursor` parks on it AFTER reading the cursor (a read "in flight").
    let scanCursorGate = Mutex<EnvGate?>(nil)

    init(log: EnvEventLog) throws {
        base = try PeopleStore.inMemory()
        self.log = log
    }

    func person(_ id: PersonID) async throws -> Person? { try await base.person(id) }
    func allPeople() async throws -> [Person] { try await base.allPeople() }
    func upsert(_ person: Person) async throws {
        log.record("store.upsert")
        try await base.upsert(person)
    }
    func identities(for id: PersonID) async throws -> [Identity] { try await base.identities(for: id) }
    func addIdentity(_ identity: Identity) async throws { try await base.addIdentity(identity) }
    func person(matching kind: Identity.Kind, value: String) async throws -> Person? {
        try await base.person(matching: kind, value: value)
    }
    func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] {
        try await base.confirmedGallery(space: space)
    }
    func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws {
        log.record("store.addEmbeddings")
        try await base.addEmbeddings(embeddings)
    }
    func forget(_ id: PersonID) async throws {
        log.record("store.forget")
        if let gate = forgetGate.withLock({ $0 }) { await gate.wait() }
        if failForget.withLock({ $0 }) { throw EnvStoreFailure() }
        try await base.forget(id)
    }
    func latestDigest() async throws -> InteractionDigest? { try await base.latestDigest() }
    func saveDigest(_ digest: InteractionDigest) async throws {
        log.record("store.saveDigest")
        if let gate = saveDigestGate.withLock({ $0 }) { await gate.wait() }
        try await base.saveDigest(digest)
        log.record("store.saveDigest.done")
    }

    func unassignedEmbeddings(space: EmbeddingSpace) async throws -> [FaceEmbedding] {
        try await base.unassignedEmbeddings(space: space)
    }
    func embeddings(ids: [UUID]) async throws -> [FaceEmbedding] { try await base.embeddings(ids: ids) }
    func replaceClusters(_ clusters: [ClusterRecord]) async throws {
        log.record("store.replaceClusters")
        try await base.replaceClusters(clusters)
    }
    func clusters() async throws -> [ClusterRecord] { try await base.clusters() }
    func confirm(cluster id: String, as person: PersonID) async throws {
        try await base.confirm(cluster: id, as: person)
    }
    func deleteEmbeddings(ids: [UUID]) async throws { try await base.deleteEmbeddings(ids: ids) }
    func removeIdentity(_ identity: Identity) async throws { try await base.removeIdentity(identity) }
    func scanCursor() async throws -> String? {
        let cursor = try await base.scanCursor()
        if let gate = scanCursorGate.withLock({ $0 }) {
            log.record("store.scanCursor.parked")
            await gate.wait()
        }
        return cursor
    }
    func setScanCursor(_ cursor: String?) async throws { try await base.setScanCursor(cursor) }

    func logRecognition(of id: PersonID, at date: Date) async throws {
        try await base.logRecognition(of: id, at: date)
    }
    func recognitionLog(for id: PersonID) async throws -> [Date] { try await base.recognitionLog(for: id) }
    var hasPendingErasure: Bool { base.hasPendingErasure }
    func flushPendingErasure() async -> Bool {
        log.record("store.flush")
        return await base.flushPendingErasure()
    }
    func eraseEverything() async throws {
        log.record("store.erase")
        if failErase.withLock({ $0 }) { throw EnvStoreFailure() }
        try await base.eraseEverything()
    }

    func hooks(for person: PersonID, now: Date) async throws -> [MemoryHook] {
        try await base.hooks(for: person, now: now)
    }
    func addHook(_ hook: MemoryHook) async throws {
        log.record("store.addHook")
        try await base.addHook(hook)
    }
    func replaceHooks(for person: PersonID, source: MemoryHook.Source, with hooks: [MemoryHook])
        async throws
    {
        log.record("store.replaceHooks")
        try await base.replaceHooks(for: person, source: source, with: hooks)
    }
    func deleteHook(id: UUID) async throws { try await base.deleteHook(id: id) }

    /// A confirmed person with one embedding.
    @discardableResult
    func seedConfirmed(_ name: String, vector: [Float]) async throws -> Person {
        let person = Person(displayName: name, confirmed: true)
        try await base.upsert(person)
        try await base.addEmbeddings([
            FaceEmbedding(
                personID: person.id, space: envSpace, vector: vector, source: .liveCapture, quality: 0.9)
        ])
        return person
    }
}

/// Embedder returning whatever vector the test sets, for every face.
final class EnvFakeEmbedder: FaceEmbedder, FrameFaceEmbedding {
    let space = envSpace
    private let vector = Mutex<[Float]>(aliceVector)

    func set(_ vector: [Float]) { self.vector.withLock { $0 = vector } }
    func embed(face: FaceObservation, in image: CGImage) async throws -> [Float] { vector.withLock { $0 } }
    func embed(face: FaceObservation, in frame: VideoFrame) async throws -> [Float] { vector.withLock { $0 } }
}

/// Detector that always sees one synthetic face in the middle of the frame.
struct EnvFakeDetector: FaceDetecting, FrameFaceDetecting {
    static let face = FaceObservation(
        boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), quality: 0.9, timestamp: 0)

    func detectFaces(in image: CGImage, timestamp: TimeInterval) async throws -> [FaceObservation] {
        [Self.face]
    }
    func detectFaces(in frame: VideoFrame) async throws -> [FaceObservation] {
        var face = Self.face
        face.timestamp = frame.timestamp
        return [face]
    }
}

/// Photo library whose listing parks until the scan is cancelled, so a scan is reliably "running".
/// After noticing the cancellation it still writes once, a little later (like `PhotoScanJob`'s
/// best-effort partial-batch save), so tests can check that writes finish before an erase.
struct EnvBlockingLibrary: PhotoLibrarySource {
    let log: EnvEventLog
    let store: EnvRecordingStore

    func assets(after position: PhotoAsset?, limit: Int) async throws -> [PhotoAsset] {
        log.record("scan.list")
        do {
            try await Task.sleep(for: .seconds(3600))
        } catch {
            log.record("scan.cancelled")
            // Not cancellable: the delay must happen even though this task is cancelled.
            await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value
            try? await store.addEmbeddings([
                FaceEmbedding(
                    space: envSpace, vector: [0, 0, 1, 0], source: .photoLibrary,
                    sourceRef: "synthetic-asset-partial", quality: 0.9)
            ])
            log.record("scan.partialWrite")
            throw CancellationError()
        }
        return []
    }

    func loadImage(for asset: PhotoAsset, maxPixelSize: Int) async throws -> PhotoScanImage? { nil }
}

/// One-shot gate: `wait()` parks until `open()`.
final class EnvGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let parked = state.withLock { s in
                guard !s.isOpen else { return false }
                s.waiters.append(continuation)
                return true
            }
            if !parked { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s in
            s.isOpen = true
            defer { s.waiters.removeAll() }
            return s.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// The app's one camera, faked: records start / stop and delivers frames the test pushes to the
/// installed handler (as the capture queue would).
final class EnvFakeCamera: CameraControlling {
    let log: EnvEventLog
    let startGate: EnvGate?
    init(log: EnvEventLog, startGate: EnvGate? = nil) {
        self.log = log
        self.startGate = startGate
    }
    private struct State {
        var running = false
        var handler: (@Sendable (VideoFrame) -> Void)?
    }
    private let state = Mutex(State())
    /// Like the real session: running after a completed start, until the next stop.
    var isRunning: Bool { state.withLock { $0.running } }
    var hasFrameHandler: Bool { state.withLock { $0.handler != nil } }

    func start() async throws {
        log.record("camera.start")
        await startGate?.wait()
        state.withLock { $0.running = true }
    }
    func stop() {
        log.record("camera.stop")
        state.withLock { $0.running = false }
    }
    func setFrameHandler(_ handler: (@Sendable (VideoFrame) -> Void)?) {
        state.withLock { $0.handler = handler }
    }
    /// Delivers a frame to the installed handler, if any and if running.
    func deliver(_ frame: VideoFrame) {
        let handler = state.withLock { $0.running ? $0.handler : nil }
        handler?(frame)
    }
}

/// Contacts source whose fetch parks until the import is cancelled, then (after a short,
/// non-cancellable delay) returns one synthetic contact, so tests can check that the import is
/// awaited and that its writes are refused after cancellation.
struct EnvBlockingContacts: ContactsSource {
    let log: EnvEventLog

    func fetchContacts() async throws -> [ContactRecord] {
        log.record("contacts.fetch")
        do {
            try await Task.sleep(for: .seconds(3600))
        } catch {
            log.record("contacts.cancelled")
            await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value
            log.record("contacts.returned")
        }
        return [
            ContactRecord(identifier: "synthetic-contact-blocked", givenName: "Synthetic", familyName: "Late")
        ]
    }
}

/// Permission fake with a fixed status per permission (status never prompts; request returns it).
final class EnvPermissions: PermissionRequesting {
    private let statuses: [OnboardingPermission: PermissionStatus]
    private let requests = Mutex<[OnboardingPermission]>([])

    init(_ statuses: [OnboardingPermission: PermissionStatus] = [:]) {
        self.statuses = statuses
    }

    var requested: [OnboardingPermission] { requests.withLock { $0 } }

    func status(for permission: OnboardingPermission) async -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }
    func request(_ permission: OnboardingPermission) async -> PermissionStatus {
        requests.withLock { $0.append(permission) }
        return statuses[permission] ?? .denied
    }
}

struct EnvFakeAuthenticator: Authenticating {
    func authenticate(reason: String) async -> Bool { true }
}

struct EnvNoThumbnails: FaceThumbnailProvider {
    func thumbnail(for embedding: FaceEmbedding) async -> CGImage? { nil }
}

/// Everything one test needs.
@MainActor
struct EnvHarness {
    let environment: AppEnvironment
    let store: EnvRecordingStore
    let log: EnvEventLog
    let embedder: EnvFakeEmbedder
    let keyStore: MemoryKeyStore
    let permissions: EnvPermissions
    let onboarding: InMemoryOnboardingStore

    init(
        modelMissing: Bool = false, region: String? = "US", contacts: [ContactRecord] = [],
        blockingContacts: Bool = false,
        openStore: (@Sendable () throws -> any AppStoring)? = nil, embedderGate: EnvGate? = nil,
        cameraStartGate: EnvGate? = nil, permissions: [OnboardingPermission: PermissionStatus] = [:],
        onboardingCompleted: Bool = false, lockTimeout: TimeInterval = 30,
        hookGenerator: any MemoryHookGenerating = UnavailableHookGenerator(),
        whisper: EnvWhisper? = nil, log: EnvEventLog = EnvEventLog(),
        authenticator: any Authenticating = EnvFakeAuthenticator(),
        speechTranscriber: (any SpeechTranscribing)? = nil,
        googlePhotos: (any GooglePhotosImporting & EnvGooglePhotosAttaching)? = nil
    ) throws {
        let store = try EnvRecordingStore(log: log)
        let embedder = EnvFakeEmbedder()
        let keyStore = MemoryKeyStore()
        let permissionFake = EnvPermissions(permissions)
        let onboarding = InMemoryOnboardingStore()
        if onboardingCompleted { onboarding.markCompleted() }
        let dependencies = AppDependencies(
            openStore: openStore ?? { store },
            loadEmbedder: {
                await embedderGate?.wait()
                if modelMissing { throw HaloVisionError.modelNotFound(URL(fileURLWithPath: "/nonexistent")) }
                return embedder
            },
            detector: EnvFakeDetector(),
            photoLibrary: EnvBlockingLibrary(log: log, store: store),
            contacts: blockingContacts
                ? EnvBlockingContacts(log: log) as any ContactsSource
                : InMemoryContactsSource(records: contacts),
            thumbnails: EnvNoThumbnails(),
            authenticator: authenticator,
            keyStore: keyStore,
            permissions: permissionFake,
            onboarding: onboarding,
            region: region,
            lockTimeout: lockTimeout,
            galleryDebounce: .milliseconds(1),
            makeCamera: { EnvFakeCamera(log: log, startGate: cameraStartGate) },
            hookGenerator: hookGenerator,
            memoryRefreshInterval: 0,
            makeWhisper: { whisper?.components ?? .silent() },
            speechTranscriber: speechTranscriber,
            makeGooglePhotos: { services in
                guard let googlePhotos else { return NullGooglePhotosImporter() }
                googlePhotos.attach(services)
                return googlePhotos
            })
        environment = AppEnvironment(dependencies: dependencies)
        self.store = store
        self.log = log
        self.embedder = embedder
        self.keyStore = keyStore
        self.permissions = permissionFake
        self.onboarding = onboarding
    }

    /// The app starts locked; the lens only runs once unlocked (the fake authenticator succeeds).
    func unlock() async {
        #expect(await environment.appLock.unlock())
    }

    var camera: EnvFakeCamera {
        // `makeCamera` above always builds one.
        environment.camera as! EnvFakeCamera
    }

    /// A sealed `.halodigest` for this phone's pairing key, written to a temporary file (inside
    /// the importer's deletable roots, so the import deletes it).
    func digestFile(_ digest: InteractionDigest, region: String = "US") throws -> URL {
        let key = try PairingKey.loadOrCreate(in: keyStore)
        let payload = try PairingPayload(encoded: key.pairingPayload)
        let data = try DigestEnvelope.seal(digest, normalizerRegion: region, to: payload).serialized
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "env-\(UUID().uuidString).halodigest")
        try data.write(to: url)
        return url
    }

    /// Delivers synthetic frames through the camera until `condition` holds.
    func deliverFrames(until condition: @MainActor () -> Bool) async throws {
        let frames = EnvFrames()
        var t = 0.0
        try await waitUntil {
            camera.deliver(frames.frame(at: t))
            t += 0.3
            return condition()
        }
    }

    /// Starts a scan and waits until it is parked inside the photo library listing.
    func startBlockedScan() async throws {
        let before = log.count("scan.list")
        environment.startPhotoScan()
        try await waitUntil { log.count("scan.list") > before }
    }
}

struct EnvTimeout: Error {}
struct EnvStoreFailure: Error {}

/// Polls `condition` (on the main actor) until it holds, failing after `timeout`.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { throw EnvTimeout() }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// Blank synthetic frames.
struct EnvFrames: @unchecked Sendable {
    let buffer: CVPixelBuffer

    init() {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, nil, &out)
        precondition(status == kCVReturnSuccess && out != nil)
        buffer = out!
    }

    func frame(at t: TimeInterval) -> VideoFrame {
        VideoFrame(pixelBuffer: buffer, orientation: .up, timestamp: t)
    }
}

@Test func envFakesAreSynthetic() async throws {
    let log = EnvEventLog()
    let store = try EnvRecordingStore(log: log)
    let alice = try await store.seedConfirmed("Synthetic Alice", vector: aliceVector)
    #expect(try await store.confirmedGallery(space: envSpace).map(\.personID) == [alice.id])
}

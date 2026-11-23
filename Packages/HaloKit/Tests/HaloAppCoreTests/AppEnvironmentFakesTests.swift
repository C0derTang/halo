import CoreGraphics
import CoreVideo
import Foundation
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

    init(log: EnvEventLog) throws {
        base = try PeopleStore.inMemory()
        self.log = log
    }

    func person(_ id: PersonID) async throws -> Person? { try await base.person(id) }
    func allPeople() async throws -> [Person] { try await base.allPeople() }
    func upsert(_ person: Person) async throws { try await base.upsert(person) }
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
        if failForget.withLock({ $0 }) { throw EnvStoreFailure() }
        try await base.forget(id)
    }
    func latestDigest() async throws -> InteractionDigest? { try await base.latestDigest() }
    func saveDigest(_ digest: InteractionDigest) async throws { try await base.saveDigest(digest) }

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
    func scanCursor() async throws -> String? { try await base.scanCursor() }
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
        try await base.eraseEverything()
    }

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
struct EnvBlockingLibrary: PhotoLibrarySource {
    let log: EnvEventLog

    func assets(after position: PhotoAsset?, limit: Int) async throws -> [PhotoAsset] {
        log.record("scan.list")
        do {
            try await Task.sleep(for: .seconds(3600))
        } catch {
            log.record("scan.cancelled")
            throw CancellationError()
        }
        return []
    }

    func loadImage(for asset: PhotoAsset, maxPixelSize: Int) async throws -> PhotoScanImage? { nil }
}

final class EnvFakeCamera: AppCamera {
    let log: EnvEventLog
    init(log: EnvEventLog) { self.log = log }
    func start() async throws { log.record("camera.start") }
    func stop() { log.record("camera.stop") }
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

    init(
        modelMissing: Bool = false, region: String? = "US", contacts: [ContactRecord] = [],
        openStore: (@Sendable () throws -> any AppStoring)? = nil
    ) throws {
        let log = EnvEventLog()
        let store = try EnvRecordingStore(log: log)
        let embedder = EnvFakeEmbedder()
        let dependencies = AppDependencies(
            openStore: openStore ?? { store },
            loadEmbedder: {
                if modelMissing { throw HaloVisionError.modelNotFound(URL(fileURLWithPath: "/nonexistent")) }
                return embedder
            },
            detector: EnvFakeDetector(),
            photoLibrary: EnvBlockingLibrary(log: log),
            contacts: InMemoryContactsSource(records: contacts),
            thumbnails: EnvNoThumbnails(),
            authenticator: EnvFakeAuthenticator(),
            region: region,
            galleryDebounce: .milliseconds(1),
            makeCamera: { _ in EnvFakeCamera(log: log) })
        environment = AppEnvironment(dependencies: dependencies)
        self.store = store
        self.log = log
        self.embedder = embedder
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

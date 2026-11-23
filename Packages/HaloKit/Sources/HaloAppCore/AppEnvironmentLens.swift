import Foundation
import HaloCore
import HaloLens

#if os(iOS)
    import AVFoundation
#endif

#if os(iOS)
    extension AppEnvironment {
        /// The capture session of the app's one camera, for the lens preview layer. nil when there
        /// is no camera.
        public var captureSession: AVCaptureSession? {
            (camera as? LensCameraSource)?.session
        }
    }
#endif

/// The store as the lens's label builder sees it: `identities(for:)` returns the STORE-WIDE
/// identity set. `ContextLabelRanker` attributes a digest entry only to the handles of the person
/// it labels, and uses everyone else's handles to drop a handle two people share (its ambiguity
/// guard). The lens builds labels from `identities(for:)`, so it gets every identity here, exactly
/// like `PersonDetailModel` and `AppEnvironment.label(for:)`: the lens and the detail screen's
/// "label preview" can never disagree. Everything else is forwarded unchanged.
struct LensLabelStore: PeopleStoring, PrivacyStoring {
    let base: any PeopleStoring & PrivacyStoring

    func identities(for id: PersonID) async throws -> [Identity] {
        var all: [Identity] = []
        for person in try await base.allPeople() {
            all += try await base.identities(for: person.id)
        }
        return all
    }

    func person(_ id: PersonID) async throws -> Person? { try await base.person(id) }
    func allPeople() async throws -> [Person] { try await base.allPeople() }
    func upsert(_ person: Person) async throws { try await base.upsert(person) }
    func addIdentity(_ identity: Identity) async throws { try await base.addIdentity(identity) }
    func person(matching kind: Identity.Kind, value: String) async throws -> Person? {
        try await base.person(matching: kind, value: value)
    }
    func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] {
        try await base.confirmedGallery(space: space)
    }
    func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws {
        try await base.addEmbeddings(embeddings)
    }
    func forget(_ id: PersonID) async throws { try await base.forget(id) }
    func latestDigest() async throws -> InteractionDigest? { try await base.latestDigest() }
    func saveDigest(_ digest: InteractionDigest) async throws { try await base.saveDigest(digest) }

    func logRecognition(of id: PersonID, at date: Date) async throws {
        try await base.logRecognition(of: id, at: date)
    }
    func recognitionLog(for id: PersonID) async throws -> [Date] { try await base.recognitionLog(for: id) }
    var hasPendingErasure: Bool { base.hasPendingErasure }
    func flushPendingErasure() async -> Bool { await base.flushPendingErasure() }
    func eraseEverything() async throws { try await base.eraseEverything() }
}

/// Track source for a build without the face model: the preview runs, nothing is recognized.
/// Frames are never submitted (`LensScreenModel` installs no frame handler without recognition),
/// and the stream never yields.
final class UnavailableLensTrackSource: LensTrackSource {
    let tracks: AsyncStream<[LensTrack]>
    private let continuation: AsyncStream<[LensTrack]>.Continuation

    init() {
        (tracks, continuation) = AsyncStream.makeStream(of: [LensTrack].self)
    }

    deinit {
        continuation.finish()
    }

    @discardableResult
    func submit(_ frame: VideoFrame) -> Bool { false }

    var metrics: LensMetrics { LensMetrics() }
}

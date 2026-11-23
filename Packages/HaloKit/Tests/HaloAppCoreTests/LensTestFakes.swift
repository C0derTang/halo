import CoreGraphics
import CoreVideo
import Foundation
import HaloCore
import HaloLens
import ImageIO
import Synchronization

@testable import HaloAppCore

// Synthetic fixtures only: made-up people, hand-placed boxes, blank pixel buffers. Names are
// prefixed `Lens` so they don't collide with other HaloAppCore test files.

func lensPersonID(_ k: Int) -> PersonID {
    PersonID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", k))!)
}

func lensTrack(
    _ id: UInt64, _ identity: MatchResult, x: Double = 0.3, state: LensTrack.State = .stable
) -> LensTrack {
    LensTrack(
        trackID: TrackID(id), smoothedBox: CGRect(x: x, y: 0.3, width: 0.2, height: 0.15), identity: identity,
        state: state)
}

func lensKnown(_ k: Int) -> MatchResult {
    .known(lensPersonID(k), similarity: 0.9, margin: 0.3)
}

/// Pipeline stand-in: the test pushes track lists; records submitted frames.
final class LensFakeTrackSource: LensTrackSource {
    let tracks: AsyncStream<[LensTrack]>
    let continuation: AsyncStream<[LensTrack]>.Continuation
    private let submitted = Mutex(0)

    init() {
        (tracks, continuation) = AsyncStream.makeStream(of: [LensTrack].self)
    }

    var submittedCount: Int { submitted.withLock { $0 } }

    func submit(_ frame: VideoFrame) -> Bool {
        submitted.withLock { $0 += 1 }
        return true
    }

    var metrics: LensMetrics { LensMetrics() }
}

final class LensFakeCamera: CameraControlling {
    private struct State {
        var handler: (@Sendable (VideoFrame) -> Void)?
        var starts = 0
        var stops = 0
        var startError: (any Error)?
    }
    private let state = Mutex(State())

    var startError: (any Error)? {
        get { state.withLock { $0.startError } }
        set { state.withLock { $0.startError = newValue } }
    }
    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }
    var hasHandler: Bool { state.withLock { $0.handler != nil } }

    func start() async throws {
        let error = state.withLock { s -> (any Error)? in
            s.starts += 1
            return s.startError
        }
        if let error { throw error }
    }

    func stop() { state.withLock { $0.stops += 1 } }

    func setFrameHandler(_ handler: (@Sendable (VideoFrame) -> Void)?) {
        state.withLock { $0.handler = handler }
    }

    /// Simulates the capture queue delivering a frame.
    func deliver(_ frame: VideoFrame) {
        let handler = state.withLock { $0.handler }
        handler?(frame)
    }
}

struct LensFakeError: Error {}

/// In-memory store recording every lookup, so tests can assert who was (not) looked up.
final class LensFakeStore: PeopleStoring, PrivacyStoring {
    struct State {
        var people: [PersonID: Person] = [:]
        var identities: [PersonID: [Identity]] = [:]
        var digest: InteractionDigest?
        var personLookups: [PersonID] = []
        var identityLookups: [PersonID] = []
        var logged: [(PersonID, Date)] = []
        var failLookups = false
    }
    let state = Mutex(State())

    func add(_ person: Person, identities: [Identity] = []) {
        state.withLock {
            $0.people[person.id] = person
            $0.identities[person.id] = identities
        }
    }

    var personLookups: [PersonID] { state.withLock { $0.personLookups } }
    var identityLookups: [PersonID] { state.withLock { $0.identityLookups } }
    var logged: [PersonID] { state.withLock { $0.logged.map(\.0) } }
    var loggedDates: [Date] { state.withLock { $0.logged.map(\.1) } }

    func setDigest(_ digest: InteractionDigest?) { state.withLock { $0.digest = digest } }
    func setFailLookups(_ fail: Bool) { state.withLock { $0.failLookups = fail } }

    func person(_ id: PersonID) async throws -> Person? {
        try state.withLock {
            $0.personLookups.append(id)
            if $0.failLookups { throw LensFakeError() }
            return $0.people[id]
        }
    }
    func allPeople() async throws -> [Person] { state.withLock { Array($0.people.values) } }
    func upsert(_ person: Person) async throws { state.withLock { $0.people[person.id] = person } }
    func identities(for id: PersonID) async throws -> [Identity] {
        state.withLock {
            $0.identityLookups.append(id)
            return $0.identities[id] ?? []
        }
    }
    func addIdentity(_ identity: Identity) async throws {
        state.withLock { $0.identities[identity.personID, default: []].append(identity) }
    }
    func person(matching kind: Identity.Kind, value: String) async throws -> Person? { nil }
    func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] { [] }
    func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws {}
    func forget(_ id: PersonID) async throws {
        state.withLock {
            $0.people[id] = nil
            $0.identities[id] = nil
        }
    }
    func latestDigest() async throws -> InteractionDigest? { state.withLock { $0.digest } }
    func saveDigest(_ digest: InteractionDigest) async throws { state.withLock { $0.digest = digest } }

    func logRecognition(of id: PersonID, at date: Date) async throws {
        state.withLock { $0.logged.append((id, date)) }
    }
    func recognitionLog(for id: PersonID) async throws -> [Date] {
        state.withLock { $0.logged.filter { $0.0 == id }.map(\.1) }
    }
    var hasPendingErasure: Bool { false }
    func flushPendingErasure() async -> Bool { true }
    func eraseEverything() async throws {}
}

/// Ranker whose subtitle reveals the digest it was given, so cache refreshes are observable.
struct LensDigestEchoRanker: LabelRanking {
    func label(for person: Person, identities: [Identity], digest: InteractionDigest?, now: Date)
        -> LabelData
    {
        LabelData(
            personID: person.id, title: person.displayName,
            subtitle: "digest:\(digest?.entries.count ?? -1) ids:\(identities.count)")
    }
}

func lensDigest(entries: Int) -> InteractionDigest {
    InteractionDigest(
        generatedAt: Date(timeIntervalSince1970: 1_000),
        entries: (0..<entries).map {
            InteractionDigest.Entry(
                handle: "+1555000\($0)", lastMessageAt: nil, lastFromMeAt: nil, lastFromThemAt: nil,
                messagesLast30Days: 0, messagesAllTime: 0, awaitingMyReply: false)
        })
}

func lensBlankFrame(width: Int = 1280, height: Int = 720, orientation: CGImagePropertyOrientation = .right)
    -> VideoFrame
{
    var out: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &out)
    precondition(status == kCVReturnSuccess && out != nil)
    return VideoFrame(pixelBuffer: out!, orientation: orientation, timestamp: 0)
}

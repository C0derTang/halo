// HaloCore seams. MASTER-OWNED: builders must not edit this file.
//
// Cross-issue couplings go through these protocols so issues in the same wave can build in
// parallel. Each issue implements the protocol for its module and consumes the others only through
// the protocol, with the safe defaults below standing in until the real implementation merges.

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

// MARK: - Vision

public protocol FaceDetecting: Sendable {
    /// Detect faces in an image. Geometry normalized, origin top-left.
    func detectFaces(in image: CGImage, timestamp: TimeInterval) async throws -> [FaceObservation]
}

public protocol FaceEmbedder: Sendable {
    var space: EmbeddingSpace { get }
    /// Align + embed one face. Returns an L2-normalized vector of `space.dimension` floats.
    func embed(face: FaceObservation, in image: CGImage) async throws -> [Float]
}

// MARK: - Live video frames

/// One camera frame. `orientation` tells Vision how to make the buffer upright; every
/// `FaceObservation` produced from a frame is normalized in the UPRIGHT (oriented) image space,
/// origin top-left.
///
/// `@unchecked Sendable`: the pixel buffer is IOSurface-backed, produced once by the capture
/// session and only ever read afterwards (never mutated), so sharing it across tasks is safe.
public struct VideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let orientation: CGImagePropertyOrientation
    public let timestamp: TimeInterval

    public init(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, timestamp: TimeInterval)
    {
        self.pixelBuffer = pixelBuffer
        self.orientation = orientation
        self.timestamp = timestamp
    }
}

public protocol FrameFaceDetecting: Sendable {
    func detectFaces(in frame: VideoFrame) async throws -> [FaceObservation]
}

public protocol FrameFaceEmbedding: Sendable {
    var space: EmbeddingSpace { get }
    /// Align + embed one face from a frame. Returns an L2-normalized vector of `space.dimension`.
    func embed(face: FaceObservation, in frame: VideoFrame) async throws -> [Float]
}

// MARK: - Matching / tracking

public protocol FaceMatching: Sendable {
    /// Match one embedding against the confirmed gallery. Unconfirmed embeddings never match.
    func match(_ vector: [Float], policy: MatchPolicy) -> MatchResult
}

public protocol FaceTracking {
    /// Feed one frame's observations; returns current live tracks.
    mutating func update(observations: [FaceObservation], timestamp: TimeInterval) -> [FaceTrack]
}

// MARK: - Store

public protocol PeopleStoring: Sendable {
    func person(_ id: PersonID) async throws -> Person?
    func allPeople() async throws -> [Person]
    func upsert(_ person: Person) async throws
    func identities(for id: PersonID) async throws -> [Identity]
    /// Throws if (kind, value) already belongs to a DIFFERENT person (never silently moves a handle).
    /// Callers importing bulk data catch the conflict and skip that identity.
    func addIdentity(_ identity: Identity) async throws
    func person(matching kind: Identity.Kind, value: String) async throws -> Person?
    /// Embeddings attached to confirmed people only, for the matcher gallery.
    func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding]
    func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws
    /// Irreversibly delete the person and every embedding, identity and derived record (invariant 3).
    func forget(_ id: PersonID) async throws
    func latestDigest() async throws -> InteractionDigest?
    func saveDigest(_ digest: InteractionDigest) async throws
}

// MARK: - Enrollment

/// A persisted clustering suggestion awaiting user triage. Suggestion only (invariant 3).
public struct ClusterRecord: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    /// Unassigned embedding IDs (personID == nil) in this cluster.
    public var memberIDs: [UUID]
    public var representativeID: UUID
    /// Closest confirmed person, if any. Never applied without user confirmation.
    public var suggestedPersonID: PersonID?
    public var cohesion: Float

    public init(
        id: String, memberIDs: [UUID], representativeID: UUID, suggestedPersonID: PersonID? = nil,
        cohesion: Float
    ) {
        self.id = id
        self.memberIDs = memberIDs
        self.representativeID = representativeID
        self.suggestedPersonID = suggestedPersonID
        self.cohesion = cohesion
    }
}

/// Store operations for the photo scan + "Who is this?" triage. Implemented by HaloStore.
public protocol EnrollmentStoring: Sendable {
    /// Embeddings with `personID == nil` in exactly this space.
    func unassignedEmbeddings(space: EmbeddingSpace) async throws -> [FaceEmbedding]
    func embeddings(ids: [UUID]) async throws -> [FaceEmbedding]
    /// Replace ALL stored (unconfirmed) cluster records with these.
    func replaceClusters(_ clusters: [ClusterRecord]) async throws
    func clusters() async throws -> [ClusterRecord]
    /// User confirmed `cluster` is `person`: assign its members to the person, mark the person
    /// confirmed, add a `.photoCluster` identity, delete the cluster record. One transaction.
    func confirm(cluster id: String, as person: PersonID) async throws
    /// User said these faces are NOT the cluster's person: delete the embeddings outright.
    func deleteEmbeddings(ids: [UUID]) async throws
    func removeIdentity(_ identity: Identity) async throws
    /// Opaque resumable photo-scan cursor.
    func scanCursor() async throws -> String?
    func setScanCursor(_ cursor: String?) async throws
}
// Forget contract addition (HaloStore): `forget` also deletes every cluster record whose
// `suggestedPersonID` is the forgotten person, together with those clusters' member embeddings.

/// Store operations for the privacy screens. Implemented by HaloStore.
public protocol PrivacyStoring: Sendable {
    func logRecognition(of id: PersonID, at date: Date) async throws
    func recognitionLog(for id: PersonID) async throws -> [Date]
    var hasPendingErasure: Bool { get }
    /// Retry any pending WAL erasure; returns true when nothing is pending. Call on backgrounding.
    func flushPendingErasure() async -> Bool
    /// Kill switch: delete every person, identity, embedding, cluster, digest and log row.
    func eraseEverything() async throws
}

// MARK: - Memory hooks

/// Store operations for memory hooks. Implemented by HaloStore. `forget(person)` and
/// `eraseEverything()` MUST delete the person's hooks too (invariant 3).
public protocol MemoryStoring: Sendable {
    func hooks(for person: PersonID, now: Date) async throws -> [MemoryHook]  // unexpired, newest first
    func addHook(_ hook: MemoryHook) async throws
    /// Replace all hooks of `source` for the person (used by the on-device summarizer).
    func replaceHooks(for person: PersonID, source: MemoryHook.Source, with hooks: [MemoryHook])
        async throws
    func deleteHook(id: UUID) async throws
}

/// Turns a person's recent message excerpts into <= 3 short memory hooks, ON DEVICE ONLY.
public protocol MemoryHookGenerating: Sendable {
    /// False when the on-device model is unavailable (unsupported device, Apple Intelligence off).
    var isAvailable: Bool { get async }
    func hooks(for person: Person, messages: [InteractionDigest.DigestMessage], now: Date)
        async throws -> [MemoryHook]
}

// MARK: - Labels

public protocol LabelRanking: Sendable {
    func label(for person: Person, identities: [Identity], digest: InteractionDigest?, now: Date)
        -> LabelData
    /// Same as above plus the person's memory hooks. Default ignores hooks; rankers that show
    /// `.memoryHook` chips implement this one.
    func label(
        for person: Person, identities: [Identity], digest: InteractionDigest?, hooks: [MemoryHook],
        now: Date
    ) -> LabelData
}

extension LabelRanking {
    public func label(
        for person: Person, identities: [Identity], digest: InteractionDigest?, hooks: [MemoryHook],
        now: Date
    ) -> LabelData {
        label(for: person, identities: identities, digest: digest, now: now)
    }
}

/// Safe default: name + relationship only, no chips.
public struct MinimalLabelRanker: LabelRanking {
    public init() {}
    public func label(for person: Person, identities: [Identity], digest: InteractionDigest?, now: Date)
        -> LabelData
    {
        LabelData(personID: person.id, title: person.displayName, subtitle: person.relationship)
    }
}

/// Safe default matcher: recognizes no one.
public struct NullMatcher: FaceMatching {
    public init() {}
    public func match(_ vector: [Float], policy: MatchPolicy) -> MatchResult { .unknown }
}

// MARK: - Google Photos (Photos Picker API)

/// Progress of one Google Photos import. Counts only: no ids, URLs, filenames or pixels.
public struct GooglePhotosImportProgress: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case signingIn, waitingForPicker, downloading, scanning, clustering, finished
    }

    public var phase: Phase
    /// Items the user picked (photos only; videos are ignored and counted in `skipped`).
    public var picked: Int
    public var downloaded: Int
    public var facesEmbedded: Int
    /// Picked items not scanned: videos, already-imported photos, undecodable or failed downloads.
    public var skipped: Int

    public init(
        phase: Phase, picked: Int = 0, downloaded: Int = 0, facesEmbedded: Int = 0, skipped: Int = 0
    ) {
        self.phase = phase
        self.picked = picked
        self.downloaded = downloaded
        self.facesEmbedded = facesEmbedded
        self.skipped = skipped
    }
}

public enum GooglePhotosImportError: Error, Sendable, Equatable {
    /// This build has no Google OAuth client ID (`HALO_GOOGLE_CLIENT_ID` in App/Local.xcconfig).
    case notConfigured
    /// The user closed Google sign-in or the picker without choosing anything.
    case cancelled
    /// The stored grant is gone (revoked, or the 7-day refresh-token limit of a Testing-mode
    /// consent screen). Tokens were deleted; the next import signs in again.
    case reauthenticationRequired
    /// The picker session expired before the user finished choosing.
    case pickerTimedOut
    /// Network or Google API failure. Carries no response bodies (they may contain URLs).
    case network
    /// Another import or the photo scan is already running.
    case busy
}

/// Imports photos the user explicitly picks in Google's own Photos Picker, then finds and embeds
/// faces ON DEVICE exactly like the Apple Photos scan (new embeddings are unconfirmed suggestions;
/// invariant 3). Implemented by HaloImport.
///
/// - Downloads only picked items, through the Picker API. Never uploads anything, never sends
///   faces, crops or embeddings anywhere (invariant 2).
/// - OAuth tokens live only in the Keychain (invariant 5).
/// - Downloaded photos are kept in the app's Data-Protection `.complete` container only so the
///   enrollment UI can show face thumbnails; `eraseAll()` deletes them.
public protocol GooglePhotosImporting: Sendable {
    /// False when the build has no client ID: the UI hides or disables the entry point.
    var isConfigured: Bool { get }
    func isSignedIn() async -> Bool
    /// Signs in if needed, opens the picker, waits for the selection, downloads the picked photos,
    /// scans them for faces and refreshes cluster suggestions. Cancellable; partial progress is kept
    /// (already-imported photos are skipped next time).
    func importPicked(progress: @escaping @Sendable (GooglePhotosImportProgress) -> Void) async throws
        -> GooglePhotosImportProgress
    /// The downloaded photo for a `.googlePhotos` embedding's `sourceRef` (upright), or nil.
    func cachedImage(for sourceRef: String) async -> CGImage?
    /// Revokes the grant at Google (best effort) and deletes the tokens. Imported faces stay.
    func signOut() async
    /// Kill switch: cancel any import, delete tokens and every downloaded photo. Embeddings are
    /// erased by the store's `eraseEverything()`.
    func eraseAll() async throws
}

/// Safe default: not configured, imports nothing.
public struct NullGooglePhotosImporter: GooglePhotosImporting {
    public init() {}
    public var isConfigured: Bool { false }
    public func isSignedIn() async -> Bool { false }
    public func importPicked(progress: @escaping @Sendable (GooglePhotosImportProgress) -> Void)
        async throws -> GooglePhotosImportProgress
    {
        throw GooglePhotosImportError.notConfigured
    }
    public func cachedImage(for sourceRef: String) async -> CGImage? { nil }
    public func signOut() async {}
    public func eraseAll() async throws {}
}

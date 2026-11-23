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

// MARK: - Labels

public protocol LabelRanking: Sendable {
    func label(for person: Person, identities: [Identity], digest: InteractionDigest?, now: Date)
        -> LabelData
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

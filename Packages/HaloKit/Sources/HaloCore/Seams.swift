// HaloCore seams. MASTER-OWNED: builders must not edit this file.
//
// Cross-issue couplings go through these protocols so issues in the same wave can build in
// parallel. Each issue implements the protocol for its module and consumes the others only through
// the protocol, with the safe defaults below standing in until the real implementation merges.

import CoreGraphics
import Foundation

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

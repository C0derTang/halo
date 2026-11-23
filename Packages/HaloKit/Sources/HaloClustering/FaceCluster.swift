import Foundation
import HaloCore

/// A group of embeddings that are probably the same person. A cluster is only a *suggestion*:
/// nothing in this module assigns a `personID` or confirms anyone (invariant 3).
public struct FaceCluster: Hashable, Sendable, Identifiable {
    /// Opaque, deterministic id (the smallest member id at creation time). Stable across `assign`.
    public var id: UUID
    public var space: EmbeddingSpace
    /// Member embedding ids, sorted by `uuidString`.
    public var memberIDs: [UUID]
    /// Medoid: the member with the highest mean similarity to the other members.
    public var representativeID: UUID
    /// Mean pairwise cosine similarity among members (1 for a single-member cluster).
    public var cohesion: Float
    /// L2-normalized mean vector. Biometric-derived: keep on device (invariant 2).
    public var centroid: [Float]

    public var size: Int { memberIDs.count }

    /// Rebuilds a cluster from stored parts (e.g. a persisted suggestion). Throws
    /// `ClusteringError.invalidCluster` unless there is at least one member, the representative is a
    /// member and `centroid.count == space.dimension`. Members are sorted by `uuidString` (the
    /// documented order) and duplicates are rejected. Values are otherwise taken as given.
    public init(
        id: UUID, space: EmbeddingSpace, memberIDs: [UUID], representativeID: UUID, cohesion: Float,
        centroid: [Float]
    ) throws {
        guard !memberIDs.isEmpty, Set(memberIDs).count == memberIDs.count,
            memberIDs.contains(representativeID), centroid.count == space.dimension,
            cohesion.isFinite, centroid.allSatisfy(\.isFinite)
        else { throw ClusteringError.invalidCluster(id: id) }
        self.init(
            trusted: id, space: space, memberIDs: memberIDs.sorted { $0.uuidString < $1.uuidString },
            representativeID: representativeID, cohesion: cohesion, centroid: centroid)
    }

    /// Unvalidated; for the clusterer, which constructs these from data it just checked.
    init(
        trusted id: UUID, space: EmbeddingSpace, memberIDs: [UUID], representativeID: UUID,
        cohesion: Float, centroid: [Float]
    ) {
        self.id = id
        self.space = space
        self.memberIDs = memberIDs
        self.representativeID = representativeID
        self.cohesion = cohesion
        self.centroid = centroid
    }
}

/// A suggested identity for a cluster. Never applied automatically.
public struct PersonSuggestion: Hashable, Sendable {
    public var personID: PersonID
    public var similarity: Float
    public var margin: Float
}

public struct ClusteringResult: Sendable {
    /// Sorted by size descending, then id.
    public var clusters: [FaceCluster]
    /// Embedding ids that did not reach `minClusterSize`.
    public var unclustered: [UUID]
    /// Embedding ids dropped for being below `minQuality`.
    public var lowQuality: [UUID]
}

public enum ClusteringError: Error, Equatable {
    case mixedEmbeddingSpaces
    case dimensionMismatch(embeddingID: UUID)
    case invalidVector(embeddingID: UUID)
    case missingMemberEmbedding(id: UUID)
    case invalidCluster(id: UUID)
}

public struct ClusteringConfig: Hashable, Sendable {
    /// Minimum cosine similarity for two faces to be linked (and to attach to an existing cluster).
    public var similarityThreshold: Float
    public var minClusterSize: Int
    public var minQuality: Float
    /// Cap on strongest neighbors kept per face (bounds memory for large inputs).
    public var maxNeighbors: Int
    public var maxIterations: Int
    /// Minimum cosine similarity of a cluster centroid to a confirmed person's face to suggest them.
    public var suggestionThreshold: Float
    /// Minimum gap between best and second-best person for a suggestion.
    public var suggestionMargin: Float

    public init(
        similarityThreshold: Float = 0.6, minClusterSize: Int = 2, minQuality: Float = 0.3,
        maxNeighbors: Int = 40, maxIterations: Int = 20, suggestionThreshold: Float = 0.6,
        suggestionMargin: Float = 0.05
    ) {
        self.similarityThreshold = similarityThreshold
        self.minClusterSize = minClusterSize
        self.minQuality = minQuality
        self.maxNeighbors = maxNeighbors
        self.maxIterations = maxIterations
        self.suggestionThreshold = suggestionThreshold
        self.suggestionMargin = suggestionMargin
    }
}

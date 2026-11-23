// HaloCore contract. MASTER-OWNED: builders must not edit this file.
// Request changes from master with an exact proposed diff.

import CoreGraphics
import Foundation

// MARK: - Identifiers

public struct PersonID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public struct TrackID: Hashable, Codable, Sendable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
}

// MARK: - People graph

/// One human the user knows. Only `confirmed` people may ever be recognized (invariant 3).
public struct Person: Hashable, Codable, Sendable, Identifiable {
    public var id: PersonID
    public var displayName: String
    /// Short relationship line, e.g. "College roommate", "Coworker @ Acme".
    public var relationship: String?
    public var birthday: DateComponents?
    public var notes: String?
    public var confirmed: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: PersonID = PersonID(), displayName: String, relationship: String? = nil,
        birthday: DateComponents? = nil, notes: String? = nil, confirmed: Bool = false,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.relationship = relationship
        self.birthday = birthday
        self.notes = notes
        self.confirmed = confirmed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A way a person appears in some source. Used for identity resolution across sources.
public struct Identity: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case contact  // CNContact.identifier
        case phone  // E.164 normalized
        case email  // lowercased
        case imessageHandle  // chat.db handle.id (phone or email as stored)
        case photoCluster  // HaloClustering cluster id
    }

    public var personID: PersonID
    public var kind: Kind
    public var value: String

    public init(personID: PersonID, kind: Kind, value: String) {
        self.personID = personID
        self.kind = kind
        self.value = value
    }
}

// MARK: - Faces

/// Identifies the embedding model so vectors from different models are never compared.
public struct EmbeddingSpace: Hashable, Codable, Sendable {
    public var modelID: String
    public var dimension: Int
    public init(modelID: String, dimension: Int) {
        self.modelID = modelID
        self.dimension = dimension
    }
}

/// L2-normalized face embedding. BIOMETRIC: never leaves the device (invariant 2).
public struct FaceEmbedding: Hashable, Codable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case photoLibrary, contactPhoto, liveCapture
    }

    public var id: UUID
    /// nil until the user confirms who this is.
    public var personID: PersonID?
    public var space: EmbeddingSpace
    public var vector: [Float]
    public var source: Source
    /// PHAsset.localIdentifier or CNContact.identifier when applicable.
    public var sourceRef: String?
    /// 0...1 capture quality (Vision faceCaptureQuality or equivalent).
    public var quality: Float
    public var createdAt: Date
    /// Where the face was in the source image: normalized, top-left origin, upright orientation.
    /// nil for embeddings stored before this field existed. Used only to crop on-device thumbnails.
    public var faceBox: CGRect?

    public init(
        id: UUID = UUID(), personID: PersonID? = nil, space: EmbeddingSpace, vector: [Float],
        source: Source, sourceRef: String? = nil, quality: Float, createdAt: Date = Date(),
        faceBox: CGRect? = nil
    ) {
        self.id = id
        self.personID = personID
        self.space = space
        self.vector = vector
        self.source = source
        self.sourceRef = sourceRef
        self.quality = quality
        self.createdAt = createdAt
        self.faceBox = faceBox
    }
}

/// A face detected in one frame or image. Geometry is normalized (0...1), origin top-left,
/// in the upright image orientation.
public struct FaceObservation: Sendable {
    public var boundingBox: CGRect
    public var roll: Double?
    public var yaw: Double?
    public var quality: Float
    /// Optional landmark points (normalized, same space as boundingBox) for alignment.
    public var landmarks: [CGPoint]
    public var timestamp: TimeInterval

    public init(
        boundingBox: CGRect, roll: Double? = nil, yaw: Double? = nil, quality: Float,
        landmarks: [CGPoint] = [], timestamp: TimeInterval
    ) {
        self.boundingBox = boundingBox
        self.roll = roll
        self.yaw = yaw
        self.quality = quality
        self.landmarks = landmarks
        self.timestamp = timestamp
    }
}

/// A face followed across frames.
public struct FaceTrack: Sendable {
    public var id: TrackID
    /// Smoothed, normalized box for rendering.
    public var smoothedBox: CGRect
    public var latest: FaceObservation
    public var age: Int
    public var framesSinceSeen: Int
    public var identity: MatchResult

    public init(
        id: TrackID, smoothedBox: CGRect, latest: FaceObservation, age: Int = 0,
        framesSinceSeen: Int = 0, identity: MatchResult = .unknown
    ) {
        self.id = id
        self.smoothedBox = smoothedBox
        self.latest = latest
        self.age = age
        self.framesSinceSeen = framesSinceSeen
        self.identity = identity
    }
}

// MARK: - Matching

/// Open-set match outcome. A wrong name is worse than no name (invariant 4).
public enum MatchResult: Hashable, Sendable {
    case known(PersonID, similarity: Float, margin: Float)
    case ambiguous
    case unknown
}

/// Single source of truth for match thresholds (invariant 4).
public struct MatchPolicy: Hashable, Codable, Sendable {
    /// Minimum cosine similarity to the best candidate person.
    public var minSimilarity: Float
    /// Minimum gap between best and second-best *person* similarity.
    public var minMargin: Float
    /// Consecutive agreeing per-frame matches before a track is labeled.
    public var minVotes: Int

    public init(minSimilarity: Float, minMargin: Float, minVotes: Int) {
        self.minSimilarity = minSimilarity
        self.minMargin = minMargin
        self.minVotes = minVotes
    }

    /// Conservative defaults; recalibrated per model in docs/MODELS.md.
    public static let conservative = MatchPolicy(minSimilarity: 0.55, minMargin: 0.08, minVotes: 3)
}

// MARK: - Interactions (iMessage bridge, later other sources)

/// Per-handle interaction stats produced by the Mac bridge. Metadata only, no message text.
public struct InteractionDigest: Hashable, Codable, Sendable {
    public struct Entry: Hashable, Codable, Sendable {
        public var handle: String
        public var lastMessageAt: Date?
        public var lastFromMeAt: Date?
        public var lastFromThemAt: Date?
        public var messagesLast30Days: Int
        public var messagesAllTime: Int
        /// True when their latest message is newer than our latest reply.
        public var awaitingMyReply: Bool
        /// OPTIONAL recent message excerpts (newest first, bounded), present only when the user
        /// opted in on the Mac (`halo-bridge export --with-messages`). MESSAGE CONTENT (invariant 6):
        /// travels only inside an authenticated DigestEnvelope, is stored only in the encrypted
        /// on-device store, and is processed only by on-device models. Absent in older digests.
        public var recentMessages: [DigestMessage]?

        public init(
            handle: String, lastMessageAt: Date?, lastFromMeAt: Date?, lastFromThemAt: Date?,
            messagesLast30Days: Int, messagesAllTime: Int, awaitingMyReply: Bool,
            recentMessages: [DigestMessage]? = nil
        ) {
            self.handle = handle
            self.lastMessageAt = lastMessageAt
            self.lastFromMeAt = lastFromMeAt
            self.lastFromThemAt = lastFromThemAt
            self.messagesLast30Days = messagesLast30Days
            self.messagesAllTime = messagesAllTime
            self.awaitingMyReply = awaitingMyReply
            self.recentMessages = recentMessages
        }
    }

    /// One message excerpt. See `Entry.recentMessages` for handling rules.
    public struct DigestMessage: Hashable, Codable, Sendable {
        public var date: Date
        public var fromMe: Bool
        /// Plain text, truncated by the bridge (<= 500 characters).
        public var text: String

        public init(date: Date, fromMe: Bool, text: String) {
            self.date = date
            self.fromMe = fromMe
            self.text = text
        }
    }

    /// Unchanged by `recentMessages` (an optional, backward-compatible field).
    public static let currentVersion = 1
    public var version: Int
    public var generatedAt: Date
    public var entries: [Entry]

    public init(version: Int = InteractionDigest.currentVersion, generatedAt: Date, entries: [Entry]) {
        self.version = version
        self.generatedAt = generatedAt
        self.entries = entries
    }
}

// MARK: - Memory hooks

/// A short thing worth remembering about a person ("Just started at Acme", "Training for a
/// marathon"). Shown as `.memoryHook` chips. Private: on-device only.
public struct MemoryHook: Hashable, Codable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        /// Typed by the user (person notes or a Moment).
        case userNote
        /// Captured from the lens as a Moment ("talked about her new job").
        case moment
        /// Generated on-device (Foundation Models) from recent messages.
        case onDeviceSummary
    }

    public var id: UUID
    public var personID: PersonID
    public var text: String
    public var source: Source
    public var createdAt: Date
    /// When this hook should stop being shown (e.g. summaries go stale); nil = never.
    public var expiresAt: Date?

    public init(
        id: UUID = UUID(), personID: PersonID, text: String, source: Source,
        createdAt: Date = Date(), expiresAt: Date? = nil
    ) {
        self.id = id
        self.personID = personID
        self.text = text
        self.source = source
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

// MARK: - Labels

public struct LabelChip: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case lastInteraction, upcoming, memoryHook, openLoop, sharedPhoto
    }

    public var kind: Kind
    public var text: String
    /// Higher shows first; ranker decides.
    public var priority: Double

    public init(kind: Kind, text: String, priority: Double) {
        self.kind = kind
        self.text = text
        self.priority = priority
    }
}

/// Everything the hologram renders for one recognized person.
public struct LabelData: Hashable, Sendable {
    public var personID: PersonID
    public var title: String
    public var subtitle: String?
    /// Already ranked; the lens shows the first 2, the card shows all.
    public var chips: [LabelChip]

    public init(personID: PersonID, title: String, subtitle: String? = nil, chips: [LabelChip] = []) {
        self.personID = personID
        self.title = title
        self.subtitle = subtitle
        self.chips = chips
    }
}

import CoreGraphics
import Foundation
import HaloClustering
import HaloCore

/// Tunables for `PhotoScanJob`.
public struct PhotoScanConfig: Hashable, Sendable {
    /// Assets per batch. Embeddings and the cursor are persisted after every batch.
    public var batchSize: Int
    /// Re-cluster after every this many batches (0 = only when the pass completes).
    public var clusterEveryBatches: Int
    /// Long edge, in pixels, of the image handed to the detector and embedder.
    public var maxPixelSize: Int
    /// Faces below this capture quality (0...1) are not embedded.
    public var minFaceQuality: Float
    /// Faces whose shorter box side is below this many upright pixels are not embedded.
    public var minFacePixels: Double
    /// Abort the run after this many consecutive detector (or embedder) failures: a systemic fault
    /// (e.g. no model) must not silently advance the cursor past the whole library.
    public var maxConsecutiveFailures: Int

    public init(
        batchSize: Int = 25, clusterEveryBatches: Int = 20, maxPixelSize: Int = 1024,
        minFaceQuality: Float = 0.3, minFacePixels: Double = 40, maxConsecutiveFailures: Int = 8
    ) {
        self.batchSize = batchSize
        self.clusterEveryBatches = clusterEveryBatches
        self.maxPixelSize = maxPixelSize
        self.minFaceQuality = minFaceQuality
        self.minFacePixels = minFacePixels
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }
}

/// Snapshot of a scan run. Counters cover this run only.
public struct ScanProgress: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case scanning, clustering, finished
    }

    public var phase: Phase = .scanning
    /// Assets whose faces were detected.
    public var assetsScanned = 0
    /// Assets skipped because they already have embeddings in this space.
    public var assetsSkipped = 0
    /// Assets whose pixels are not on the device (e.g. iCloud-only) or could not be decoded.
    public var assetsUnavailable = 0
    /// Assets the uprighter or detector failed on.
    public var assetsFailed = 0
    public var facesEmbedded = 0
    /// Faces dropped by the quality / size filter.
    public var facesRejected = 0
    /// Faces the embedder failed on.
    public var facesFailed = 0
    public var batchesCompleted = 0
    /// Cluster suggestions stored by the latest clustering, nil until clustering has run.
    public var clusterCount: Int?

    public init() {}
}

public enum PhotoScanError: Error, Equatable, Sendable {
    /// A `PhotoScanJob` runs once; create a new job to scan again.
    case alreadyStarted
    case invalidConfig
    /// The embedder returned a vector of the wrong size or a degenerate one.
    case invalidEmbedding
}

/// Persisted, opaque (to the store) scan position.
///
/// A *pass* walks the library newest-first down to `completedTop`, the newest asset of the
/// previous completed pass, so later runs only visit photos added since. `resumeAfter` is the last
/// asset whose results are persisted in the pass in progress.
struct PhotoScanCursor: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version = PhotoScanCursor.currentVersion
    var space: EmbeddingSpace
    var completedTop: PhotoAsset?
    var passTop: PhotoAsset?
    var resumeAfter: PhotoAsset?

    init(space: EmbeddingSpace) { self.space = space }

    /// The stored cursor, or a fresh one when there is none, it is unreadable, or it belongs to a
    /// different embedding model (a new model rescans everything; dedupe is per space).
    static func decode(_ stored: String?, space: EmbeddingSpace) -> PhotoScanCursor {
        guard let stored, let data = stored.data(using: .utf8),
            let cursor = try? JSONDecoder().decode(PhotoScanCursor.self, from: data),
            cursor.version == currentVersion, cursor.space == space
        else { return PhotoScanCursor(space: space) }
        return cursor
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// Resumable, on-device scan of the photo library into UNASSIGNED face embeddings and cluster
/// suggestions for enrollment triage.
///
/// Invariants 2 + 3: every embedding is written with `personID == nil`; clustering only stores
/// `ClusterRecord` suggestions. This type never assigns a face, confirms or creates a person, or
/// adds an identity. It never uses the network (the source must not download; see
/// `PhotoLibrarySource`).
///
/// Resumability: per batch, embeddings are written first, then the cursor. A kill between the two
/// re-visits that batch on the next run, and dedupe by `sourceRef` (asset `localIdentifier`) skips
/// assets that already have embeddings in this space, so nothing is duplicated.
///
/// Cancellation is checked before each asset; on cancellation the finished part of the batch is
/// persisted (best effort) and `run()` throws `CancellationError`.
///
/// Single use: observe `progress`, call `run()` once (e.g. in a `Task` you can cancel).
public actor PhotoScanJob {
    /// Progress snapshots; finishes when `run()` returns or throws.
    public nonisolated let progress: AsyncStream<ScanProgress>
    private let continuation: AsyncStream<ScanProgress>.Continuation

    private let source: any PhotoLibrarySource
    private let detector: any FaceDetecting
    private let embedder: any FaceEmbedder
    private let store: any PeopleStoring & EnrollmentStoring
    private let clusterer: FaceClusterer
    private let config: PhotoScanConfig
    private let uprighter: any PhotoScanUprighting

    private var started = false
    private var state = ScanProgress()
    /// `sourceRef`s of photo-library assets that already have embeddings in this space.
    private var embeddedRefs: Set<String> = []
    private var detectFailures = 0
    private var embedFailures = 0

    public init(
        source: any PhotoLibrarySource, detector: any FaceDetecting, embedder: any FaceEmbedder,
        store: any PeopleStoring & EnrollmentStoring, clusterer: FaceClusterer,
        config: PhotoScanConfig = PhotoScanConfig(),
        uprighter: any PhotoScanUprighting = CoreImageUprighter()
    ) {
        (progress, continuation) = AsyncStream.makeStream(
            of: ScanProgress.self, bufferingPolicy: .bufferingNewest(256))
        self.source = source
        self.detector = detector
        self.embedder = embedder
        self.store = store
        self.clusterer = clusterer
        self.config = config
        self.uprighter = uprighter
    }

    /// Scans from the stored cursor to the end of the pass, then re-clusters. Returns the final
    /// progress.
    @discardableResult
    public func run() async throws -> ScanProgress {
        guard !started else { throw PhotoScanError.alreadyStarted }
        started = true
        defer { continuation.finish() }
        guard config.batchSize > 0, config.maxPixelSize > 0 else { throw PhotoScanError.invalidConfig }

        let space = embedder.space
        var cursor = PhotoScanCursor.decode(try await store.scanCursor(), space: space)
        embeddedRefs = try await alreadyEmbeddedRefs(space: space)
        publish(.scanning)

        var passComplete = false
        while !passComplete {
            let page = try await source.assets(after: cursor.resumeAfter, limit: config.batchSize)
            passComplete = page.isEmpty
            var pending: [FaceEmbedding] = []
            var lastDone: PhotoAsset?
            for asset in page {
                if let floor = cursor.completedTop, !asset.precedes(floor) {
                    passComplete = true
                    break
                }
                do {
                    try Task.checkCancellation()
                    if cursor.passTop == nil { cursor.passTop = asset }
                    pending += try await process(asset, space: space)
                } catch is CancellationError {
                    if let lastDone {
                        // Best effort: if this fails, the next run redoes the batch (deduped).
                        try? await persist(pending, through: lastDone, cursor: &cursor)
                    }
                    throw CancellationError()
                }
                lastDone = asset
            }
            if let lastDone {
                try await persist(pending, through: lastDone, cursor: &cursor)
                state.facesEmbedded += pending.count
                state.batchesCompleted += 1
                publish(.scanning)
                if !passComplete, config.clusterEveryBatches > 0,
                    state.batchesCompleted % config.clusterEveryBatches == 0
                {
                    try await recluster(space: space)
                }
            }
        }

        cursor.completedTop = cursor.passTop ?? cursor.completedTop
        cursor.passTop = nil
        cursor.resumeAfter = nil
        try await store.setScanCursor(cursor.encoded())

        try Task.checkCancellation()
        try await recluster(space: space)
        publish(.finished)
        return state
    }

    // MARK: - Steps

    private func alreadyEmbeddedRefs(space: EmbeddingSpace) async throws -> Set<String> {
        let existing =
            try await store.unassignedEmbeddings(space: space)
            + store.confirmedGallery(space: space)
        return Set(existing.lazy.filter { $0.source == .photoLibrary }.compactMap(\.sourceRef))
    }

    /// Detect -> filter -> embed one asset. Returns unassigned embeddings (not yet persisted).
    private func process(_ asset: PhotoAsset, space: EmbeddingSpace) async throws -> [FaceEmbedding] {
        let ref = asset.localIdentifier
        if embeddedRefs.contains(ref) {
            state.assetsSkipped += 1
            return []
        }

        let loaded: PhotoScanImage?
        do {
            loaded = try await source.loadImage(for: asset, maxPixelSize: config.maxPixelSize)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            loaded = nil
        }
        guard let loaded else {
            state.assetsUnavailable += 1
            return []
        }

        let image: CGImage
        let faces: [FaceObservation]
        do {
            image = try uprighter.upright(loaded.image, orientation: loaded.orientation)
            faces = try await detector.detectFaces(
                in: image, timestamp: asset.creationDate.timeIntervalSinceReferenceDate)
            detectFailures = 0
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            state.assetsFailed += 1
            detectFailures += 1
            if detectFailures >= max(config.maxConsecutiveFailures, 1) { throw error }
            return []
        }
        state.assetsScanned += 1

        var embeddings: [FaceEmbedding] = []
        for face in faces {
            guard accepts(face, imageWidth: image.width, imageHeight: image.height) else {
                state.facesRejected += 1
                continue
            }
            do {
                let vector = try await embedder.embed(face: face, in: image)
                guard Self.isUsable(vector, space: space) else { throw PhotoScanError.invalidEmbedding }
                embedFailures = 0
                embeddings.append(
                    FaceEmbedding(
                        personID: nil, space: space, vector: vector, source: .photoLibrary, sourceRef: ref,
                        quality: face.quality))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                state.facesFailed += 1
                embedFailures += 1
                if embedFailures >= max(config.maxConsecutiveFailures, 1) { throw error }
            }
        }
        if !embeddings.isEmpty { embeddedRefs.insert(ref) }
        return embeddings
    }

    /// Quality / size filter, in upright pixel space.
    private func accepts(_ face: FaceObservation, imageWidth: Int, imageHeight: Int) -> Bool {
        guard face.quality >= config.minFaceQuality else { return false }
        let width = face.boundingBox.width * CGFloat(imageWidth)
        let height = face.boundingBox.height * CGFloat(imageHeight)
        return Double(min(width, height)) >= config.minFacePixels
    }

    private static func isUsable(_ vector: [Float], space: EmbeddingSpace) -> Bool {
        guard vector.count == space.dimension, vector.allSatisfy(\.isFinite) else { return false }
        return vector.contains { $0 != 0 }
    }

    /// Embeddings first, then the cursor (see type docs for why this order).
    private func persist(
        _ embeddings: [FaceEmbedding], through asset: PhotoAsset, cursor: inout PhotoScanCursor
    ) async throws {
        if !embeddings.isEmpty { try await store.addEmbeddings(embeddings) }
        cursor.resumeAfter = asset
        try await store.setScanCursor(cursor.encoded())
    }

    /// Clusters every unassigned embedding in this space and replaces the stored suggestions.
    /// Suggestions name the closest confirmed person at most; nothing is assigned (invariant 3).
    private func recluster(space: EmbeddingSpace) async throws {
        publish(.clustering)
        let unassigned = try await store.unassignedEmbeddings(space: space)
            .filter { $0.personID == nil && $0.space == space }
        let result = try clusterer.cluster(unassigned)
        let gallery = try await store.confirmedGallery(space: space)
            .filter { $0.personID != nil && $0.space == space }
        var records: [ClusterRecord] = []
        records.reserveCapacity(result.clusters.count)
        for cluster in result.clusters {
            let suggestion = try clusterer.suggest(for: cluster, confirmedGallery: gallery)
            records.append(
                ClusterRecord(
                    id: cluster.id.uuidString, memberIDs: cluster.memberIDs,
                    representativeID: cluster.representativeID, suggestedPersonID: suggestion?.personID,
                    cohesion: cluster.cohesion))
        }
        try await store.replaceClusters(records)
        state.clusterCount = records.count
        publish(.scanning)
    }

    private func publish(_ phase: ScanProgress.Phase) {
        state.phase = phase
        continuation.yield(state)
    }
}

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
    /// Abort the run after this many consecutive *assets* failed entirely (detection failed, or
    /// every eligible face failed to embed). Counted per asset, so one crowd photo counts once;
    /// any embedded face resets it. Only a systemic fault (e.g. no model) fails asset after asset,
    /// and it must not silently advance the cursor past the whole library. Errors the job's
    /// `isSystemicFailure` recognizes abort immediately instead.
    public var maxConsecutiveFailures: Int
    /// Attempts per clustering round (fresh read -> cluster -> replace). A mid-pass round that
    /// exhausts them is skipped with a warning; only the end-of-pass round then throws.
    public var clusteringAttempts: Int

    public init(
        batchSize: Int = 25, clusterEveryBatches: Int = 20, maxPixelSize: Int = 1024,
        minFaceQuality: Float = 0.3, minFacePixels: Double = 40, maxConsecutiveFailures: Int = 8,
        clusteringAttempts: Int = 3
    ) {
        self.batchSize = batchSize
        self.clusterEveryBatches = clusterEveryBatches
        self.maxPixelSize = maxPixelSize
        self.minFaceQuality = minFaceQuality
        self.minFacePixels = minFacePixels
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.clusteringAttempts = clusteringAttempts
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
    /// Clustering rounds this run that failed every attempt (scanning continued regardless).
    public var clusteringFailures = 0
    /// Set while the latest clustering round failed; cleared when a later round succeeds.
    /// Carries no error text, ids or vectors (invariant 2).
    public var warning: Warning?

    public enum Warning: Hashable, Sendable {
        /// Suggestions could not be refreshed (e.g. the user confirmed or forgot someone mid-write);
        /// the next clustering round retries.
        case clusteringFailed
    }

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
/// Failures: `isSystemicFailure` classifies detector/embedder errors that mean the pipeline cannot
/// work at all (the app passes HaloVision's `isRecognitionUnavailable`); those abort the run at
/// once. Any other per-asset or per-face error skips that asset or face (see
/// `PhotoScanConfig.maxConsecutiveFailures` for the fallback).
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
    private let isSystemicFailure: @Sendable (any Error) -> Bool
    /// Assets in a row that failed entirely (see `PhotoScanConfig.maxConsecutiveFailures`).
    private var consecutiveFailedAssets = 0

    public init(
        source: any PhotoLibrarySource, detector: any FaceDetecting, embedder: any FaceEmbedder,
        store: any PeopleStoring & EnrollmentStoring, clusterer: FaceClusterer,
        config: PhotoScanConfig = PhotoScanConfig(),
        uprighter: any PhotoScanUprighting = CoreImageUprighter(),
        isSystemicFailure: @escaping @Sendable (any Error) -> Bool = { _ in false }
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
        self.isSystemicFailure = isSystemicFailure
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
                    try await reclusterWithRetry(space: space, endOfPass: false)
                }
            }
        }

        cursor.completedTop = cursor.passTop ?? cursor.completedTop
        cursor.passTop = nil
        cursor.resumeAfter = nil
        try await store.setScanCursor(cursor.encoded())

        try Task.checkCancellation()
        try await reclusterWithRetry(space: space, endOfPass: true)
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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isSystemicFailure(error) { throw error }
            state.assetsFailed += 1
            try assetFailed(error)
            return []
        }
        state.assetsScanned += 1

        var embeddings: [FaceEmbedding] = []
        var lastFaceError: (any Error)?
        for face in faces {
            guard accepts(face, imageWidth: image.width, imageHeight: image.height) else {
                state.facesRejected += 1
                continue
            }
            do {
                let vector = try await embedder.embed(face: face, in: image)
                guard Self.isUsable(vector, space: space) else { throw PhotoScanError.invalidEmbedding }
                embeddings.append(
                    FaceEmbedding(
                        personID: nil, space: space, vector: vector, source: .photoLibrary, sourceRef: ref,
                        quality: face.quality))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if isSystemicFailure(error) { throw error }
                state.facesFailed += 1
                lastFaceError = error
            }
        }
        if !embeddings.isEmpty {
            embeddedRefs.insert(ref)
            consecutiveFailedAssets = 0
        } else if let lastFaceError {
            try assetFailed(lastFaceError)
        }
        // An asset with no eligible faces says nothing about the pipeline: no count, no reset.
        return embeddings
    }

    /// Counts an asset that failed entirely; rethrows once too many fail in a row.
    private func assetFailed(_ error: any Error) throws {
        consecutiveFailedAssets += 1
        if consecutiveFailedAssets >= max(config.maxConsecutiveFailures, 1) { throw error }
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

    /// Runs a clustering round, retrying it whole: every attempt re-reads unassigned embeddings,
    /// stored clusters and the confirmed gallery, because the user may have confirmed, rejected or
    /// forgotten someone between the read and `replaceClusters`.
    ///
    /// Mid-pass rounds are incremental (`FaceClusterer.assign`: existing cluster ids and members
    /// stay put) and never end the scan: once attempts run out they are recorded in
    /// `ScanProgress` and the next round retries. The end-of-pass round re-clusters everything and
    /// throws its last error if every attempt fails. Cancellation always propagates.
    private func reclusterWithRetry(space: EmbeddingSpace, endOfPass: Bool) async throws {
        var lastError: (any Error)?
        for _ in 0..<max(config.clusteringAttempts, 1) {
            do {
                try await recluster(space: space, full: endOfPass)
                state.warning = nil
                publish(.scanning)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        state.clusteringFailures += 1
        state.warning = .clusteringFailed
        publish(.scanning)
        if endOfPass, let lastError { throw lastError }
    }

    /// One clustering attempt. Stores suggestions only: each names the closest confirmed person at
    /// most and nothing is assigned (invariant 3).
    private func recluster(space: EmbeddingSpace, full: Bool) async throws {
        publish(.clustering)
        let unassigned = try await store.unassignedEmbeddings(space: space)
            .filter { $0.personID == nil && $0.space == space }
        let clusters =
            full
            ? try clusterer.cluster(unassigned).clusters
            : try await incrementalClusters(unassigned: unassigned, space: space)
        let gallery = try await store.confirmedGallery(space: space)
            .filter { $0.personID != nil && $0.space == space }
        var records: [ClusterRecord] = []
        records.reserveCapacity(clusters.count)
        for cluster in clusters {
            let suggestion = try clusterer.suggest(for: cluster, confirmedGallery: gallery)
            records.append(
                ClusterRecord(
                    id: cluster.id.uuidString, memberIDs: cluster.memberIDs,
                    representativeID: cluster.representativeID, suggestedPersonID: suggestion?.personID,
                    cohesion: cluster.cohesion))
        }
        try await store.replaceClusters(records)
        state.clusterCount = records.count
    }

    /// Keeps every stored cluster whose members are all still unassigned, and attaches the other
    /// unassigned faces to them (or clusters them among themselves). A cluster that lost a member
    /// (confirmed, rejected or forgotten in the meantime) is dropped and its remaining faces are
    /// treated as new.
    private func incrementalClusters(unassigned: [FaceEmbedding], space: EmbeddingSpace) async throws
        -> [FaceCluster]
    {
        let byID = Dictionary(unassigned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var existing: [FaceCluster] = []
        var claimed: Set<UUID> = []
        var pool: [FaceEmbedding] = []
        for record in try await store.clusters() {
            let ids = Set(record.memberIDs)
            let members = record.memberIDs.compactMap { byID[$0] }
            guard let id = UUID(uuidString: record.id), !members.isEmpty, ids.count == members.count,
                members.count == record.memberIDs.count, ids.isDisjoint(with: claimed),
                ids.contains(record.representativeID),
                let cluster = restoredCluster(record, id: id, members: members, space: space)
            else { continue }
            existing.append(cluster)
            claimed.formUnion(ids)
            pool += members
        }
        let fresh = unassigned.filter { !claimed.contains($0.id) }
        return try clusterer.assign(newEmbeddings: fresh, to: existing, existingEmbeddings: pool).clusters
    }

    /// Rebuilds a `FaceCluster` for an intact stored record (id, members, representative and
    /// cohesion as stored; centroid recomputed from the members). Nil if the record is invalid.
    private func restoredCluster(
        _ record: ClusterRecord, id: UUID, members: [FaceEmbedding], space: EmbeddingSpace
    ) -> FaceCluster? {
        var sum = [Float](repeating: 0, count: space.dimension)
        for member in members {
            guard member.vector.count == space.dimension else { return nil }
            let unit = Self.normalized(member.vector)
            for d in 0..<space.dimension { sum[d] += unit[d] }
        }
        return try? FaceCluster(
            id: id, space: space, memberIDs: record.memberIDs,
            representativeID: record.representativeID, cohesion: record.cohesion,
            centroid: Self.normalized(sum))
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return v }
        return v.map { $0 / norm }
    }

    private func publish(_ phase: ScanProgress.Phase) {
        state.phase = phase
        continuation.yield(state)
    }
}

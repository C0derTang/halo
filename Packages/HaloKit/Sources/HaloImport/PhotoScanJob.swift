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
    private let embedder: any FaceEmbedder
    private let store: any PeopleStoring & EnrollmentStoring
    private let config: PhotoScanConfig
    private let pipeline: FaceScanPipeline
    private let refresher: ClusterSuggestionRefresher

    private var started = false
    private var state = ScanProgress()
    /// `sourceRef`s of photo-library assets that already have embeddings in this space.
    private var embeddedRefs: Set<String> = []
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
        self.embedder = embedder
        self.store = store
        self.config = config
        pipeline = FaceScanPipeline(
            detector: detector, embedder: embedder, uprighter: uprighter, config: config,
            isSystemicFailure: isSystemicFailure)
        refresher = ClusterSuggestionRefresher(store: store, clusterer: clusterer)
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

        let outcome = try await pipeline.scan(
            loaded, timestamp: asset.creationDate.timeIntervalSinceReferenceDate, source: .photoLibrary,
            sourceRef: ref, space: space)
        let scan: FaceScanPipeline.ImageScan
        switch outcome {
        case .failed(let error):
            state.assetsFailed += 1
            try assetFailed(error)
            return []
        case .scanned(let result):
            scan = result
        }
        state.assetsScanned += 1
        state.facesRejected += scan.facesRejected
        state.facesFailed += scan.facesFailed

        if !scan.embeddings.isEmpty {
            embeddedRefs.insert(ref)
            consecutiveFailedAssets = 0
        } else if let lastFaceError = scan.lastFaceError {
            try assetFailed(lastFaceError)
        }
        // An asset with no eligible faces says nothing about the pipeline: no count, no reset.
        return scan.embeddings
    }

    /// Counts an asset that failed entirely; rethrows once too many fail in a row.
    private func assetFailed(_ error: any Error) throws {
        consecutiveFailedAssets += 1
        if consecutiveFailedAssets >= max(config.maxConsecutiveFailures, 1) { throw error }
    }

    /// Embeddings first, then the cursor (see type docs for why this order).
    private func persist(
        _ embeddings: [FaceEmbedding], through asset: PhotoAsset, cursor: inout PhotoScanCursor
    ) async throws {
        if !embeddings.isEmpty { try await store.addEmbeddings(embeddings) }
        cursor.resumeAfter = asset
        try await store.setScanCursor(cursor.encoded())
    }

    /// Runs a clustering round with retries (see `ClusterSuggestionRefresher.refreshRetrying`).
    ///
    /// Mid-pass rounds are incremental and never end the scan: once attempts run out they are
    /// recorded in `ScanProgress` and the next round retries. The end-of-pass round re-clusters
    /// everything and throws its last error if every attempt fails. Cancellation always propagates.
    private func reclusterWithRetry(space: EmbeddingSpace, endOfPass: Bool) async throws {
        publish(.clustering)
        do {
            state.clusterCount = try await refresher.refreshRetrying(
                space: space, full: endOfPass, attempts: config.clusteringAttempts)
            state.warning = nil
            publish(.scanning)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            state.clusteringFailures += 1
            state.warning = .clusteringFailed
            publish(.scanning)
            if endOfPass { throw error }
        }
    }

    private func publish(_ phase: ScanProgress.Phase) {
        state.phase = phase
        continuation.yield(state)
    }
}

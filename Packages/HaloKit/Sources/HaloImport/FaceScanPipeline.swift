import CoreGraphics
import Foundation
import HaloClustering
import HaloCore

/// The per-image face pipeline shared by `PhotoScanJob` (Apple Photos) and `GooglePhotosImporter`:
/// upright -> detect -> quality / size filter -> embed. On device only; it never persists anything,
/// it only returns UNASSIGNED embeddings (`personID == nil`, invariant 3) for the caller to store.
struct FaceScanPipeline: Sendable {
    let detector: any FaceDetecting
    let embedder: any FaceEmbedder
    let uprighter: any PhotoScanUprighting
    let minFaceQuality: Float
    let minFacePixels: Double
    /// Errors that mean the pipeline cannot work at all; they are rethrown instead of skipped.
    let isSystemicFailure: @Sendable (any Error) -> Bool

    init(
        detector: any FaceDetecting, embedder: any FaceEmbedder, uprighter: any PhotoScanUprighting,
        config: PhotoScanConfig, isSystemicFailure: @escaping @Sendable (any Error) -> Bool
    ) {
        self.detector = detector
        self.embedder = embedder
        self.uprighter = uprighter
        minFaceQuality = config.minFaceQuality
        minFacePixels = config.minFacePixels
        self.isSystemicFailure = isSystemicFailure
    }

    /// What one image produced.
    struct ImageScan: Sendable {
        /// Unassigned, not yet persisted.
        var embeddings: [FaceEmbedding] = []
        /// Faces dropped by the quality / size filter.
        var facesRejected = 0
        /// Faces the embedder failed on.
        var facesFailed = 0
        /// The last per-face embedder error, if any.
        var lastFaceError: (any Error)?
    }

    enum Outcome: Sendable {
        /// The uprighter or detector failed (non-systemic): the image was not scanned.
        case failed(any Error)
        case scanned(ImageScan)
    }

    /// Scans one image. Throws only `CancellationError` or a systemic failure; any other error
    /// skips the image (`.failed`) or the face (counted in `facesFailed`).
    ///
    /// `space` is the embedder's space as the caller read it once for the whole run (the app's
    /// embedder loads lazily); a vector that does not fit it is rejected.
    func scan(
        _ loaded: PhotoScanImage, timestamp: TimeInterval, source: FaceEmbedding.Source, sourceRef: String,
        space: EmbeddingSpace
    ) async throws -> Outcome {
        let image: CGImage
        let faces: [FaceObservation]
        do {
            image = try uprighter.upright(loaded.image, orientation: loaded.orientation)
            faces = try await detector.detectFaces(in: image, timestamp: timestamp)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isSystemicFailure(error) { throw error }
            return .failed(error)
        }

        var result = ImageScan()
        for face in faces {
            guard accepts(face, imageWidth: image.width, imageHeight: image.height) else {
                result.facesRejected += 1
                continue
            }
            do {
                let vector = try await embedder.embed(face: face, in: image)
                guard Self.isUsable(vector, space: space) else { throw PhotoScanError.invalidEmbedding }
                result.embeddings.append(
                    FaceEmbedding(
                        personID: nil, space: space, vector: vector, source: source, sourceRef: sourceRef,
                        quality: face.quality, faceBox: face.boundingBox))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if isSystemicFailure(error) { throw error }
                result.facesFailed += 1
                result.lastFaceError = error
            }
        }
        return .scanned(result)
    }

    /// Quality / size filter, in upright pixel space.
    private func accepts(_ face: FaceObservation, imageWidth: Int, imageHeight: Int) -> Bool {
        guard face.quality >= minFaceQuality else { return false }
        let width = face.boundingBox.width * CGFloat(imageWidth)
        let height = face.boundingBox.height * CGFloat(imageHeight)
        return Double(min(width, height)) >= minFacePixels
    }

    static func isUsable(_ vector: [Float], space: EmbeddingSpace) -> Bool {
        guard vector.count == space.dimension, vector.allSatisfy(\.isFinite) else { return false }
        return vector.contains { $0 != 0 }
    }
}

/// Refreshes the stored cluster SUGGESTIONS from the unassigned embeddings. Shared by the Apple
/// Photos scan and the Google Photos import. Stores `ClusterRecord`s only: each names the closest
/// confirmed person at most and nothing is assigned or confirmed (invariant 3).
struct ClusterSuggestionRefresher: Sendable {
    let store: any PeopleStoring & EnrollmentStoring
    let clusterer: FaceClusterer

    /// Runs up to `attempts` clustering rounds, retrying the whole round: every attempt re-reads
    /// unassigned embeddings, stored clusters and the confirmed gallery, because the user may have
    /// confirmed, rejected or forgotten someone between the read and `replaceClusters`.
    /// Returns the number of stored suggestions; throws the last error once attempts run out.
    /// Cancellation always propagates.
    func refreshRetrying(space: EmbeddingSpace, full: Bool, attempts: Int) async throws -> Int {
        var lastError: (any Error)?
        for _ in 0..<max(attempts, 1) {
            do {
                return try await refresh(space: space, full: full)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError ?? CancellationError()
    }

    /// One clustering attempt. `full` re-clusters everything; otherwise it is incremental
    /// (`FaceClusterer.assign`: existing cluster ids and members stay put).
    func refresh(space: EmbeddingSpace, full: Bool) async throws -> Int {
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
        return records.count
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
}

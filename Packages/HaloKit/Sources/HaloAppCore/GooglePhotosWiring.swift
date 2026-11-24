import CoreGraphics
import Foundation
import HaloClustering
import HaloCore
import HaloUI
import HaloVision
import Synchronization

// MARK: - Configuration

/// Whether this build can talk to Google Photos: the iOS OAuth client ID from the Info.plist key
/// `HaloGoogleClientID`, which App/project.yml fills from `HALO_GOOGLE_CLIENT_ID` (set in the
/// gitignored App/Local.xcconfig; see e2e/google-photos.md). The client ID is not a secret, but it
/// is never hard-coded (invariant 5).
public struct GooglePhotosConfig: Hashable, Sendable {
    public static let infoKey = "HaloGoogleClientID"
    public static let notConfigured = GooglePhotosConfig(clientID: nil)

    /// nil when the build has none.
    public let clientID: String?
    public var isConfigured: Bool { clientID != nil }

    /// Empty, whitespace-only and unexpanded build-setting values (`$(HALO_GOOGLE_CLIENT_ID)`)
    /// mean "not configured".
    public init(clientID: String?) {
        let trimmed = clientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.clientID = trimmed.isEmpty || trimmed.contains("$(") ? nil : trimmed
    }

    public init(infoDictionary: [String: Any]?) {
        self.init(clientID: infoDictionary?[Self.infoKey] as? String)
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> GooglePhotosConfig {
        GooglePhotosConfig(infoDictionary: bundle.infoDictionary)
    }
}

/// What the app hands the Google Photos importer factory: the build's config and the SAME store,
/// detector, embedder and clusterer the Apple Photos scan uses.
public struct GooglePhotosServices: Sendable {
    public let config: GooglePhotosConfig
    /// The app's store, restricted to what an importer needs: reads, `addEmbeddings` and
    /// `replaceClusters`. Every other write (forget, confirm, upsert, identities, the Apple Photos
    /// scan cursor, ...) throws `ImportStoreError.notAllowed`: those go through the app's own paths
    /// (forget ordering, gallery refresh). The allowed writes throw `CancellationError` once the
    /// writing task is cancelled, so a kill switch that cancels the import can never be followed by
    /// a late write.
    public let store: any PeopleStoring & EnrollmentStoring
    public let detector: any FaceDetecting
    /// The app's embedding model. It loads AFTER launch, after the importer is built:
    /// - until then `space` is a PLACEHOLDER (`modelID "unavailable"`, dimension 0) and `embed`
    ///   throws (`isSystemicFailure` is true for that error);
    /// - so read `space` once per import, at the start of the run, never at init and never cached
    ///   across imports. The environment only starts an import once the model has loaded.
    public let embedder: any FaceEmbedder
    public let clusterer: FaceClusterer
    /// True for errors that mean "no face can be embedded at all" (missing / broken model, model
    /// not loaded yet): abort the import instead of skipping photo after photo. The same predicate
    /// the Apple Photos scan uses.
    public let isSystemicFailure: @Sendable (any Error) -> Bool

    public init(
        config: GooglePhotosConfig, store: any PeopleStoring & EnrollmentStoring,
        detector: any FaceDetecting, embedder: any FaceEmbedder, clusterer: FaceClusterer = FaceClusterer(),
        isSystemicFailure: @escaping @Sendable (any Error) -> Bool = GooglePhotosServices
            .isRecognitionUnavailable
    ) {
        self.config = config
        self.store = store
        self.detector = detector
        self.embedder = embedder
        self.clusterer = clusterer
        self.isSystemicFailure = isSystemicFailure
    }

    /// The scan's systemic-failure predicate (`HaloVisionError.isRecognitionUnavailable`), plus
    /// the deferred embedder's "model not loaded yet".
    public static let isRecognitionUnavailable: @Sendable (any Error) -> Bool = { error in
        if error is DeferredFaceEmbedder.NotLoaded { return true }
        return (error as? HaloVisionError)?.isRecognitionUnavailable == true
    }
}

// MARK: - Embedder that loads later

/// The app's face embedder, filled in once the model has loaded (`AppEnvironment.start()`), so the
/// Google Photos importer can be built at launch. Until then `embed` throws `notLoaded` and `space`
/// is a placeholder that matches no stored face.
final class DeferredFaceEmbedder: FaceEmbedder {
    struct NotLoaded: Error, Equatable {}

    static let placeholderSpace = EmbeddingSpace(modelID: "unavailable", dimension: 0)

    private let loaded = Mutex<(any FaceEmbedder)?>(nil)

    var isLoaded: Bool { loaded.withLock { $0 != nil } }

    func resolve(_ embedder: any FaceEmbedder) {
        loaded.withLock { $0 = embedder }
    }

    var space: EmbeddingSpace { loaded.withLock { $0?.space } ?? Self.placeholderSpace }

    func embed(face: FaceObservation, in image: CGImage) async throws -> [Float] {
        guard let embedder = loaded.withLock({ $0 }) else { throw NotLoaded() }
        return try await embedder.embed(face: face, in: image)
    }
}

// MARK: - Cancellable store for the importer

public enum ImportStoreError: Error, Equatable, Sendable {
    /// The importer tried a write only the app's own paths may make (see `GooglePhotosServices`).
    case notAllowed
}

/// The importer's view of the app store.
/// - Reads are forwarded.
/// - `addEmbeddings` and `replaceClusters` (all an importer writes: unconfirmed faces and cluster
///   suggestions) first check the calling task for cancellation and throw `CancellationError`
///   instead of writing. The kill switch and forget cancel the Google import's task, so even an
///   importer that kept going would have its next write refused.
/// - Every other write throws `ImportStoreError.notAllowed` and touches nothing: forget, confirm,
///   identity and person writes would bypass the forget ordering and gallery refresh of
///   `ObservedStore`, and `setScanCursor` would clobber the Apple Photos scan's cursor.
struct CancellableImportStore: PeopleStoring, EnrollmentStoring {
    let base: any PeopleStoring & EnrollmentStoring

    private func checkCancellation() throws { try Task.checkCancellation() }

    // MARK: PeopleStoring

    func person(_ id: PersonID) async throws -> Person? { try await base.person(id) }
    func allPeople() async throws -> [Person] { try await base.allPeople() }
    func upsert(_ person: Person) async throws { throw ImportStoreError.notAllowed }
    func identities(for id: PersonID) async throws -> [Identity] { try await base.identities(for: id) }
    func addIdentity(_ identity: Identity) async throws { throw ImportStoreError.notAllowed }
    func person(matching kind: Identity.Kind, value: String) async throws -> Person? {
        try await base.person(matching: kind, value: value)
    }
    func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] {
        try await base.confirmedGallery(space: space)
    }
    func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws {
        try checkCancellation()
        try await base.addEmbeddings(embeddings)
    }
    func forget(_ id: PersonID) async throws { throw ImportStoreError.notAllowed }
    func latestDigest() async throws -> InteractionDigest? { try await base.latestDigest() }
    func saveDigest(_ digest: InteractionDigest) async throws { throw ImportStoreError.notAllowed }

    // MARK: EnrollmentStoring

    func unassignedEmbeddings(space: EmbeddingSpace) async throws -> [FaceEmbedding] {
        try await base.unassignedEmbeddings(space: space)
    }
    func embeddings(ids: [UUID]) async throws -> [FaceEmbedding] { try await base.embeddings(ids: ids) }
    func replaceClusters(_ clusters: [ClusterRecord]) async throws {
        try checkCancellation()
        try await base.replaceClusters(clusters)
    }
    func clusters() async throws -> [ClusterRecord] { try await base.clusters() }
    func confirm(cluster id: String, as person: PersonID) async throws { throw ImportStoreError.notAllowed }
    func deleteEmbeddings(ids: [UUID]) async throws { throw ImportStoreError.notAllowed }
    func removeIdentity(_ identity: Identity) async throws { throw ImportStoreError.notAllowed }
    func scanCursor() async throws -> String? { try await base.scanCursor() }
    func setScanCursor(_ cursor: String?) async throws { throw ImportStoreError.notAllowed }
}

// MARK: - Thumbnails by source

/// Face thumbnails routed by where the photo came from: `.googlePhotos` faces are cropped from the
/// importer's on-device copy of the picked photo (never fetched from Google), everything else goes
/// to the PhotoKit provider. Images stay in memory (invariant 2).
struct SourceRoutedThumbnails: FaceThumbnailProvider {
    let photoLibrary: any FaceThumbnailProvider
    let googlePhotos: any GooglePhotosImporting
    /// Long edge of a Google Photos face thumbnail (the PhotoKit provider's default target).
    var targetPixelSize: CGFloat = 320

    @concurrent
    func thumbnail(for embedding: FaceEmbedding) async -> CGImage? {
        switch embedding.source {
        case .googlePhotos:
            guard let ref = embedding.sourceRef, let photo = await googlePhotos.cachedImage(for: ref) else {
                return nil
            }
            // Off the main actor (`@concurrent`). The cached photo is already upright, the space
            // the face box is in; the same crop as the PhotoKit path.
            let faceBox = embedding.faceBox.flatMap(FaceThumbnailCrop.validated)
            return FaceThumbnailCrop.scaledDown(
                FaceThumbnailCrop.crop(photo, to: faceBox), maxPixelSize: targetPixelSize)
        case .photoLibrary, .contactPhoto, .liveCapture:
            return await photoLibrary.thumbnail(for: embedding)
        }
    }
}

extension FaceThumbnailCrop {
    /// `image` scaled so its long edge is at most `maxPixelSize` (returned as is when it already
    /// fits, or when it cannot be redrawn).
    static func scaledDown(_ image: CGImage, maxPixelSize: CGFloat) -> CGImage {
        let longEdge = CGFloat(max(image.width, image.height))
        guard maxPixelSize >= 1, longEdge > maxPixelSize else { return image }
        let scale = maxPixelSize / longEdge
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

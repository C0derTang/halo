import CoreGraphics
import Foundation
import HaloCore
import HaloImport
import HaloLens
import HaloStore
import HaloUI
import HaloVision

/// Everything `AppEnvironment` builds on. `live()` is the real app; tests inject fakes.
public struct AppDependencies: Sendable {
    public typealias FrameHandler = @Sendable (VideoFrame) -> Void
    public typealias Embedder = any FaceEmbedder & FrameFaceEmbedding
    public typealias Detector = any FaceDetecting & FrameFaceDetecting

    /// Opens the encrypted store. Retried (launch, `start()`, every `.active`) until it succeeds.
    public var openStore: @Sendable () throws -> any AppStoring
    /// Loads the face embedding model off the main actor. Throwing means "recognition unavailable".
    public var loadEmbedder: @Sendable () async throws -> Embedder
    public var detector: Detector
    public var photoLibrary: any PhotoLibrarySource
    public var contacts: any ContactsSource
    public var thumbnails: any FaceThumbnailProvider
    public var authenticator: any Authenticating
    /// ISO region for phone-number normalization. nil means unknown ("ZZ"), never a guess.
    public var region: String?
    public var policy: MatchPolicy
    public var lensConfig: LensConfig
    public var scanConfig: PhotoScanConfig
    public var lockTimeout: TimeInterval
    /// Coalescing window for gallery rebuilds after identity changes.
    public var galleryDebounce: Duration
    /// Creates the camera; frames must go to the handler. nil when there is no camera (macOS host).
    public var makeCamera: @MainActor @Sendable (@escaping FrameHandler) -> (any AppCamera)?
    /// Runs lifecycle work that must finish after backgrounding (store flush). On iOS this holds a
    /// `UIApplication` background task for the duration.
    public var backgroundWork: @MainActor @Sendable (String, @MainActor () async -> Void) async -> Void

    public init(
        openStore: @escaping @Sendable () throws -> any AppStoring,
        loadEmbedder: @escaping @Sendable () async throws -> Embedder,
        detector: Detector,
        photoLibrary: any PhotoLibrarySource,
        contacts: any ContactsSource,
        thumbnails: any FaceThumbnailProvider,
        authenticator: any Authenticating,
        region: String?,
        policy: MatchPolicy = .conservative,
        lensConfig: LensConfig = LensConfig(),
        scanConfig: PhotoScanConfig = PhotoScanConfig(),
        lockTimeout: TimeInterval = 30,  // AppLock.defaultTimeout (main-actor isolated)
        galleryDebounce: Duration = .milliseconds(250),
        makeCamera: @escaping @MainActor @Sendable (@escaping FrameHandler) -> (any AppCamera)? = { _ in nil
        },
        backgroundWork: @escaping @MainActor @Sendable (String, @MainActor () async -> Void) async -> Void = {
            _, work in await work()
        }
    ) {
        self.openStore = openStore
        self.loadEmbedder = loadEmbedder
        self.detector = detector
        self.photoLibrary = photoLibrary
        self.contacts = contacts
        self.thumbnails = thumbnails
        self.authenticator = authenticator
        self.region = region
        self.policy = policy
        self.lensConfig = lensConfig
        self.scanConfig = scanConfig
        self.lockTimeout = lockTimeout
        self.galleryDebounce = galleryDebounce
        self.makeCamera = makeCamera
        self.backgroundWork = backgroundWork
    }
}

extension AppDependencies {
    /// The real services: `PeopleStore` at its default (Data Protection `.complete`) path, the
    /// bundled CoreML embedder, Vision detection, PhotoKit, Contacts, Face ID, the back camera.
    @MainActor
    public static func live() -> AppDependencies {
        AppDependencies(
            openStore: { try PeopleStore(path: PeopleStore.defaultPath()) },
            loadEmbedder: {
                guard let directory = Bundle.main.resourceURL else {
                    throw HaloVisionError.modelNotFound(Bundle.main.bundleURL)
                }
                return try await CoreMLFaceEmbedder.load(directory: directory)
            },
            detector: VisionFaceDetector(),
            photoLibrary: livePhotoLibrary(),
            contacts: liveContacts(),
            thumbnails: liveThumbnails(),
            authenticator: LocalAuthenticator(),
            region: Locale.current.region?.identifier,
            makeCamera: liveCamera,
            backgroundWork: LifecycleBackgroundWork.run)
    }

    private static func livePhotoLibrary() -> any PhotoLibrarySource {
        #if canImport(Photos)
            PhotoKitLibrarySource()
        #else
            InMemoryPhotoLibrary()
        #endif
    }

    private static func liveContacts() -> any ContactsSource {
        #if canImport(Contacts)
            CNContactsSource()
        #else
            InMemoryContactsSource()
        #endif
    }

    private static func liveThumbnails() -> any FaceThumbnailProvider {
        #if canImport(Photos)
            PhotoKitThumbnailProvider()
        #else
            NoThumbnails()
        #endif
    }

    @MainActor
    private static func liveCamera(_ onFrame: @escaping FrameHandler) -> (any AppCamera)? {
        #if os(iOS)
            CameraSource(onFrame: onFrame)
        #else
            nil
        #endif
    }
}

/// Thumbnail provider that never returns an image.
struct NoThumbnails: FaceThumbnailProvider {
    func thumbnail(for embedding: FaceEmbedding) async -> CGImage? { nil }
}

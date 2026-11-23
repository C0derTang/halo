import CoreGraphics
import Foundation
import HaloBridgeKit
import HaloCore
import HaloImport
import HaloLens
import HaloMemory
import HaloStore
import HaloUI
import HaloVision

/// Everything `AppEnvironment` builds on. `live()` is the real app; tests inject fakes.
public struct AppDependencies: Sendable {
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
    /// Holds the phone's pairing key (Keychain in the app, in-memory in tests). Used by the pairing
    /// screen and the `.halodigest` importer, so both always see the same key (invariant 5).
    public var keyStore: any KeyStore
    /// System permission status / prompts (onboarding, resuming the scan on launch).
    public var permissions: any PermissionRequesting
    /// The non-sensitive "onboarding finished" flag.
    public var onboarding: any OnboardingCompletionStoring
    /// ISO region for phone-number normalization. nil means unknown ("ZZ"), never a guess.
    public var region: String?
    public var policy: MatchPolicy
    public var lensConfig: LensConfig
    public var scanConfig: PhotoScanConfig
    public var lockTimeout: TimeInterval
    /// Coalescing window for gallery rebuilds after identity changes.
    public var galleryDebounce: Duration
    /// Creates the app's one camera (called once, at init). nil when there is no camera (macOS host).
    public var makeCamera: @MainActor @Sendable () -> (any CameraControlling)?
    /// Runs lifecycle work that must finish after backgrounding (store flush). On iOS this holds a
    /// `UIApplication` background task for the duration.
    public var backgroundWork: @MainActor @Sendable (String, @MainActor () async -> Void) async -> Void
    /// The ON-DEVICE memory hook generator (Foundation Models in the app). Invariant 6: never an
    /// off-device model. The default generates nothing.
    public var hookGenerator: any MemoryHookGenerating
    /// Minimum time between two completed memory hook refreshes.
    public var memoryRefreshInterval: TimeInterval
    /// Builds Whisper mode's route reader, trusted-device store, speech, haptics, audio session and
    /// settings store (called once, at init). The default never speaks.
    public var makeWhisper: @MainActor @Sendable () -> WhisperComponents

    public init(
        openStore: @escaping @Sendable () throws -> any AppStoring,
        loadEmbedder: @escaping @Sendable () async throws -> Embedder,
        detector: Detector,
        photoLibrary: any PhotoLibrarySource,
        contacts: any ContactsSource,
        thumbnails: any FaceThumbnailProvider,
        authenticator: any Authenticating,
        keyStore: any KeyStore,
        permissions: any PermissionRequesting,
        onboarding: any OnboardingCompletionStoring,
        region: String?,
        policy: MatchPolicy = .conservative,
        lensConfig: LensConfig = LensConfig(),
        scanConfig: PhotoScanConfig = PhotoScanConfig(),
        lockTimeout: TimeInterval = 30,  // AppLock.defaultTimeout (main-actor isolated)
        galleryDebounce: Duration = .milliseconds(250),
        makeCamera: @escaping @MainActor @Sendable () -> (any CameraControlling)? = { nil },
        backgroundWork: @escaping @MainActor @Sendable (String, @MainActor () async -> Void) async -> Void = {
            _, work in await work()
        },
        hookGenerator: any MemoryHookGenerating = UnavailableHookGenerator(),
        memoryRefreshInterval: TimeInterval = MemoryHookRefresher.defaultMinimumInterval,
        makeWhisper: @escaping @MainActor @Sendable () -> WhisperComponents = { .silent() }
    ) {
        self.openStore = openStore
        self.loadEmbedder = loadEmbedder
        self.detector = detector
        self.photoLibrary = photoLibrary
        self.contacts = contacts
        self.thumbnails = thumbnails
        self.authenticator = authenticator
        self.keyStore = keyStore
        self.permissions = permissions
        self.onboarding = onboarding
        self.region = region
        self.policy = policy
        self.lensConfig = lensConfig
        self.scanConfig = scanConfig
        self.lockTimeout = lockTimeout
        self.galleryDebounce = galleryDebounce
        self.makeCamera = makeCamera
        self.backgroundWork = backgroundWork
        self.hookGenerator = hookGenerator
        self.memoryRefreshInterval = memoryRefreshInterval
        self.makeWhisper = makeWhisper
    }
}

extension AppDependencies {
    /// The real services: `PeopleStore` at its default (Data Protection `.complete`) path, the
    /// bundled CoreML embedder, Vision detection, PhotoKit, Contacts, Face ID, the Keychain pairing
    /// key, the system permission prompts, the back camera, the on-device Foundation Models hook
    /// generator and the system Whisper components.
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
            keyStore: KeychainKeyStore.phone,
            permissions: SystemPermissionRequester(),
            onboarding: UserDefaultsOnboardingStore(),
            region: Locale.current.region?.identifier,
            makeCamera: liveCamera,
            backgroundWork: LifecycleBackgroundWork.run,
            hookGenerator: liveHookGenerator(),
            makeWhisper: { .system() })
    }

    private static func liveHookGenerator() -> any MemoryHookGenerating {
        #if canImport(FoundationModels)
            FoundationModelsHookGenerator()
        #else
            UnavailableHookGenerator()
        #endif
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
    private static func liveCamera() -> (any CameraControlling)? {
        #if os(iOS)
            LensCameraSource()
        #else
            nil
        #endif
    }
}

/// Thumbnail provider that never returns an image.
struct NoThumbnails: FaceThumbnailProvider {
    func thumbnail(for embedding: FaceEmbedding) async -> CGImage? { nil }
}

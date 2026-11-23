import Foundation

/// Permissions onboarding can request.
public enum OnboardingPermission: String, Sendable, CaseIterable {
    case camera, photos, contacts
}

public enum PermissionStatus: Sendable, Equatable {
    case notDetermined
    case granted
    /// Photos and contacts: access to a user-selected subset.
    case limited
    case denied

    public var allowsUse: Bool { self == .granted || self == .limited }
}

/// Reads and requests system permissions. `status` must never prompt.
public protocol PermissionRequesting: Sendable {
    func status(for permission: OnboardingPermission) async -> PermissionStatus
    func request(_ permission: OnboardingPermission) async -> PermissionStatus
}

/// Runs the contacts import; returns the number of contacts imported. Everything stays on device.
public protocol ContactsImporting: Sendable {
    func importContacts() async throws -> Int
}

public struct PhotoScanProgress: Sendable, Equatable {
    public var processed: Int
    public var total: Int?
    public var isFinished: Bool

    public init(processed: Int, total: Int? = nil, isFinished: Bool = false) {
        self.processed = processed
        self.total = total
        self.isFinished = isFinished
    }

    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(processed) / Double(total))
    }
}

/// Starts the on-device photo scan. The scan itself keeps running in the app's background work;
/// the stream only reports progress.
public protocol PhotoScanning: Sendable {
    func start() -> AsyncStream<PhotoScanProgress>
}

/// Persists the non-sensitive "onboarding finished" flag.
public protocol OnboardingCompletionStoring: Sendable {
    var isCompleted: Bool { get }
    func markCompleted()
}

/// `UserDefaults` is documented thread-safe but not annotated `Sendable` in the SDK, hence `@unchecked`.
public struct UserDefaultsOnboardingStore: OnboardingCompletionStoring, @unchecked Sendable {
    public static let key = "halo.onboarding.completed"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isCompleted: Bool { defaults.bool(forKey: Self.key) }
    public func markCompleted() { defaults.set(true, forKey: Self.key) }
}

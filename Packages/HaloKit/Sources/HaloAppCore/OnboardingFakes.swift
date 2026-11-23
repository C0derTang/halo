import Foundation

/// Test/preview fakes. Synthetic only.
public final class FakePermissionRequester: PermissionRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [OnboardingPermission: PermissionStatus]
    private var _requested: [OnboardingPermission] = []

    public init(results: [OnboardingPermission: PermissionStatus] = [:]) { self.results = results }

    public var requested: [OnboardingPermission] { lock.withLock { _requested } }

    public func status(for permission: OnboardingPermission) async -> PermissionStatus {
        .notDetermined
    }

    public func request(_ permission: OnboardingPermission) async -> PermissionStatus {
        lock.withLock {
            _requested.append(permission)
            return results[permission] ?? .granted
        }
    }
}

public final class FakeContactsImporter: ContactsImporting, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private let count: Int
    private let fails: Bool

    public init(count: Int = 12, fails: Bool = false) {
        self.count = count
        self.fails = fails
    }

    public var calls: Int { lock.withLock { _calls } }

    public func importContacts() async throws -> Int {
        lock.withLock { _calls += 1 }
        if fails { throw CocoaError(.fileReadUnknown) }
        return count
    }
}

public final class FakePhotoScanner: PhotoScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var _starts = 0
    private let updates: [PhotoScanProgress]

    public init(
        updates: [PhotoScanProgress] = [
            PhotoScanProgress(processed: 50, total: 100),
            PhotoScanProgress(processed: 100, total: 100, isFinished: true),
        ]
    ) {
        self.updates = updates
    }

    public var starts: Int { lock.withLock { _starts } }

    public func start() -> AsyncStream<PhotoScanProgress> {
        lock.withLock { _starts += 1 }
        let updates = updates
        return AsyncStream { c in
            for u in updates { c.yield(u) }
            c.finish()
        }
    }
}

public final class InMemoryOnboardingStore: OnboardingCompletionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    public init() {}
    public var isCompleted: Bool { lock.withLock { done } }
    public func markCompleted() { lock.withLock { done = true } }
}

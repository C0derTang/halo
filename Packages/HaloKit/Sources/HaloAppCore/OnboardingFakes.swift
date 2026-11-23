import Foundation

/// Test/preview fakes. Synthetic only.
public final class FakePermissionRequester: PermissionRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [OnboardingPermission: PermissionStatus]
    private var _requested: [OnboardingPermission] = []

    private let gated: Bool
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var _waiting = false

    /// `gated`: `request` suspends until `release()` is called, so tests can observe the
    /// in-flight state deterministically.
    public init(results: [OnboardingPermission: PermissionStatus] = [:], gated: Bool = false) {
        self.results = results
        self.gated = gated
    }

    /// True once a request is suspended at the gate.
    public var isWaiting: Bool { lock.withLock { _waiting } }

    public func release() {
        let w: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            defer { waiter = nil }
            return waiter
        }
        w?.resume()
    }

    public var requested: [OnboardingPermission] { lock.withLock { _requested } }

    public func status(for permission: OnboardingPermission) async -> PermissionStatus {
        .notDetermined
    }

    public func request(_ permission: OnboardingPermission) async -> PermissionStatus {
        if gated {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if released { return true }
                    waiter = c
                    _waiting = true
                    return false
                }
                if resumeNow { c.resume() }
            }
        }
        return lock.withLock {
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

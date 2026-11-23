import Foundation

#if os(iOS)
    import UIKit
#endif

/// Keeps the process alive while lifecycle work that must not be cut short (the store's erasure
/// checkpoint on backgrounding) finishes.
enum LifecycleBackgroundWork {
    @MainActor
    static func run(_ name: String, _ work: @MainActor () async -> Void) async {
        #if os(iOS)
            let task = BackgroundTask()
            task.begin(name)
            await work()
            task.end()
        #else
            await work()
        #endif
    }
}

#if os(iOS)
    @MainActor
    private final class BackgroundTask {
        private var identifier = UIBackgroundTaskIdentifier.invalid

        func begin(_ name: String) {
            identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                // Out of time: release it; anything unfinished is retried on the next background.
                MainActor.assumeIsolated { self?.end() }
            }
        }

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
#endif

import Foundation
import HaloCore

#if os(iOS)
    import UIKit
#endif

// MARK: - Google Photos import

/// The Google Photos importer is a WRITER, owned here like the scan and the imports:
/// - **One photo writer at a time.** A Google import and the Apple Photos scan both write faces and
///   re-cluster, so they never overlap: starting a Google import pauses the scan (cancelled and
///   awaited; it resumes from its cursor afterwards), and the scan does not (re)start while a Google
///   import runs (`reconcileScan`). A second Google import is refused with `.busy`.
/// - **Forget** cancels the running import and waits for it before anyone is deleted.
/// - **Kill switch** cancels it, calls `googlePhotos.eraseAll()` (tokens and downloaded photos;
///   the importer cancels and awaits its own work too) and waits for it, all before the store
///   erase. An import requested before a successful kill switch is dropped, never run after it.
/// - Every importer write goes through `CancellableImportStore`: once its task is cancelled, the
///   next write throws instead of landing; writes other than faces and suggestions are refused.
/// - **Cancel** works at any point, also while the run still waits for the model or a forget (it
///   then never starts, so no sign-in sheet opens later).
/// - **Background is fine**: opening Google's picker always sends Halo to the background, and the
///   import survives it (polling resumes on return). It is NOT stopped on `.background`.
/// - **Device lock** (`protectedDataWillBecomeUnavailable`): the store and downloaded photos are
///   Data Protection `.complete`, so writes would fail once the phone locks. The import is
///   cancelled cleanly (and awaited) and the screen says "Import paused (phone locked)"; running it
///   again continues (already-imported photos are skipped).
/// - Imported faces are unconfirmed suggestions (invariant 3); afterwards "Who is this?" reloads.
extension AppEnvironment: GooglePhotosImportDriving {
    func runGooglePhotosImport(progress: @escaping @Sendable (GooglePhotosImportProgress) -> Void)
        async throws -> GooglePhotosImportProgress
    {
        guard googlePhotos.isConfigured else { throw GooglePhotosImportError.notConfigured }
        guard googleTask == nil, !googleRunPending else { throw GooglePhotosImportError.busy }
        // Until the task is registered below, Cancel sets `googleCancelRequested`.
        googleRunPending = true
        googleCancelRequested = false
        googlePausedForLock = false
        defer { googleRunPending = false }
        let requestedIn = eraseGeneration
        // Faces are embedded with the app's model: wait for it to load.
        await start()
        guard !googleCancelRequested else { throw CancellationError() }
        guard recognition == .available else { throw GooglePhotosAppError.recognitionUnavailable }
        await whenNoDestructiveOperation()
        guard eraseGeneration == requestedIn, !googleCancelRequested else { throw CancellationError() }
        // The phone locked while it waited: do not start against unreadable files.
        guard !googlePausedForLock else { throw GooglePhotosAppError.pausedForDeviceLock }
        guard googleTask == nil else { throw GooglePhotosImportError.busy }
        // No suspension between the checks above and registering the task: a forget / erase /
        // cancel / device lock from here on sees `googleTask` and stops it, and `reconcileScan`
        // will not start the scan.
        let importer = googlePhotos
        let task = Task { [weak self] () async throws -> GooglePhotosImportProgress in
            // The Apple Photos scan waits until this import has finished.
            await self?.pauseScan()
            try Task.checkCancellation()
            return try await importer.importPicked(progress: progress)
        }
        googleTask = task
        let outcome = await task.result
        googleImportEnded(task)
        if case .failure = outcome, googlePausedForLock {
            throw GooglePhotosAppError.pausedForDeviceLock
        }
        return try outcome.get()
    }

    func cancelGooglePhotosImport() {
        if let googleTask {
            googleTask.cancel()
        } else if googleRunPending {
            // Still waiting for the model or a forget: it will not start.
            googleCancelRequested = true
        }
    }

    /// The phone is locking: protected data (store, downloaded photos) is about to become
    /// unreadable. Cancels the running import and waits for it, inside a background task. A run
    /// still waiting to start (model load, a forget) will not start.
    func protectedDataWillBecomeUnavailable() async {
        if googleRunPending, googleTask == nil { googlePausedForLock = true }
        guard let task = googleTask else { return }
        googlePausedForLock = true
        task.cancel()
        await dependencies.backgroundWork("halo.google.lock") {
            _ = await task.result
        }
    }

    private func googleImportEnded(_ task: Task<GooglePhotosImportProgress, any Error>) {
        if googleTask == task { googleTask = nil }
        // New suggestions (or none): "Who is this?" and the People list reload.
        peopleRevision += 1
        let enrollment = self.enrollment
        Task { await enrollment.load() }
        // A scan that was paused (or asked for) meanwhile picks up again.
        reconcileScan()
    }

    /// Forget (`eraseData == false`) or kill switch (`true`): cancels the running import and waits
    /// until it has stopped. For the kill switch, `eraseAll()` also runs, before the wait (it stops
    /// the importer's own work even if cancellation has not reached it yet) and again after it
    /// when an import was running (anything it downloaded while stopping is deleted too).
    func stopGooglePhotosImport(eraseData: Bool) async {
        let task = googleTask
        task?.cancel()
        if eraseData { await eraseGooglePhotosData() }
        _ = await task?.result
        // It has stopped: a scan may resume once the forget is over (`storeDidForget`).
        if let task, googleTask == task { googleTask = nil }
        if eraseData, task != nil { await eraseGooglePhotosData() }
    }

    /// Deletes Google tokens and downloaded photos. Remembers a failure so the kill switch retries
    /// once the store erase has run.
    func eraseGooglePhotosData() async {
        do {
            try await googlePhotos.eraseAll()
            googleEraseFailed = false
        } catch {
            googleEraseFailed = true
        }
    }
}

/// Forwards the system's "protected data will become unavailable" (the device is locking) for the
/// app's lifetime. Nothing on macOS.
final class ProtectedDataObserver {
    // Only written in init and read in deinit, never concurrently; NSObjectProtocol is not Sendable.
    nonisolated(unsafe) private var token: (any NSObjectProtocol)?

    init(handler: @escaping @MainActor @Sendable () -> Void) {
        #if os(iOS)
            token = NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { handler() }
            }
        #endif
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

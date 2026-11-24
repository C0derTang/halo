import Foundation
import HaloCore

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
///   next write throws instead of landing.
/// - Imported faces are unconfirmed suggestions (invariant 3); afterwards "Who is this?" reloads.
extension AppEnvironment: GooglePhotosImportDriving {
    func runGooglePhotosImport(progress: @escaping @Sendable (GooglePhotosImportProgress) -> Void)
        async throws -> GooglePhotosImportProgress
    {
        guard googlePhotos.isConfigured else { throw GooglePhotosImportError.notConfigured }
        guard googleTask == nil else { throw GooglePhotosImportError.busy }
        let requestedIn = eraseGeneration
        // Faces are embedded with the app's model: wait for it to load.
        await start()
        guard recognition == .available else { throw GooglePhotosAppError.recognitionUnavailable }
        await whenNoDestructiveOperation()
        guard eraseGeneration == requestedIn else { throw CancellationError() }
        guard googleTask == nil else { throw GooglePhotosImportError.busy }
        // No suspension between the checks above and registering the task: a forget / erase that
        // starts from here on sees `googleTask` and stops it, and `reconcileScan` will not start
        // the scan.
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
        return try outcome.get()
    }

    func cancelGooglePhotosImport() {
        googleTask?.cancel()
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

import Foundation
import HaloImport

/// Onboarding's contacts step over the environment's owned `ContactsImporter` run
/// (`AppEnvironment.importContacts()`). Building it does nothing; only `importContacts()` imports,
/// and `OnboardingModel` calls that only after the user tapped allow and the system granted access.
public struct EnvironmentContactsImporting: ContactsImporting {
    let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Contacts now in the people graph (created, updated or already there); skipped ones are not
    /// counted.
    public func importContacts() async throws -> Int {
        let result = try await environment.importContacts()
        return result.created + result.updated + result.unchanged
    }
}

/// Onboarding's photos step over the environment's owned `PhotoScanJob` run
/// (`AppEnvironment.startPhotoScan()`), so backgrounding, forget and the kill switch control the
/// scan exactly as they do any other. Building it does nothing; only `start()` starts the scan, and
/// `OnboardingModel` calls that only after the user tapped allow and the system granted access.
public struct EnvironmentPhotoScanning: PhotoScanning {
    let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public func start() -> AsyncStream<PhotoScanProgress> {
        let (stream, continuation) = AsyncStream.makeStream(of: PhotoScanProgress.self)
        let environment = self.environment
        let task = Task { @MainActor in
            environment.startPhotoScan()
            for await progress in environment.photoScanUpdates() {
                continuation.yield(Self.progress(progress))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Onboarding's coarse view of a scan: photos looked at so far. The library size is not known
    /// up front (the scan pages through it), so there is no total.
    static func progress(_ p: ScanProgress) -> PhotoScanProgress {
        PhotoScanProgress(
            processed: p.assetsScanned + p.assetsSkipped + p.assetsUnavailable + p.assetsFailed,
            total: nil, isFinished: p.phase == .finished)
    }
}

extension AppEnvironment {
    /// First launch: onboarding has not been completed yet.
    public var needsOnboarding: Bool { !dependencies.onboarding.isCompleted }

    /// The first-run flow over the real permission prompts, contacts import and photo scan.
    public func makeOnboardingModel() -> OnboardingModel {
        OnboardingModel(
            permissions: dependencies.permissions,
            contacts: EnvironmentContactsImporting(environment: self),
            scanner: EnvironmentPhotoScanning(environment: self),
            store: dependencies.onboarding)
    }

    /// Settings "Import contacts": asks for Contacts access (prompts only if undecided) and imports
    /// only when it is granted. Returns the imported count, nil when access is off.
    public func importContactsWithConsent() async throws -> Int? {
        guard await dependencies.permissions.request(.contacts).allowsUse else { return nil }
        return try await EnvironmentContactsImporting(environment: self).importContacts()
    }

    /// Settings "Scan photos": asks for Photos access (prompts only if undecided) and starts the
    /// scan only when it is granted. Returns whether the scan was started.
    @discardableResult
    public func scanPhotosWithConsent() async -> Bool {
        guard await dependencies.permissions.request(.photos).allowsUse else { return false }
        startPhotoScan()
        return scanStatus != .unavailable
    }

    /// On launch: picks the photo scan back up (from its persisted cursor, or for photos added
    /// since the last pass) only when
    /// - the user already consented: onboarding is complete and Photos access is granted (full or
    ///   limited); this never prompts;
    /// - a scan has run before: the store has a scan cursor. The kill switch deletes the cursor, so
    ///   an erase is never undone by rescanning the library on the next launch; after it, only an
    ///   explicit "Scan photos" starts a scan again;
    /// - no forget / erase is in flight.
    func resumePhotoScanIfConsented() async {
        guard dependencies.onboarding.isCompleted, recognition != .unavailable else { return }
        guard await dependencies.permissions.status(for: .photos).allowsUse else { return }
        // `try?` flattens: nil when unreadable or when there is no cursor.
        guard (try? await store.scanCursor()) != nil else { return }
        guard destructiveOperations == 0 else { return }
        startPhotoScan()
    }
}

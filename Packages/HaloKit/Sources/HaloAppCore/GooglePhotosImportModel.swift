import Foundation
import HaloCore
import Observation

/// Runs Google Photos imports for `GooglePhotosImportModel`. Implemented by `AppEnvironment`, which
/// owns the import task so forget and the kill switch can stop it.
@MainActor
protocol GooglePhotosImportDriving: AnyObject {
    func runGooglePhotosImport(progress: @escaping @Sendable (GooglePhotosImportProgress) -> Void)
        async throws -> GooglePhotosImportProgress
    func cancelGooglePhotosImport()
}

/// Errors the app adds on top of `GooglePhotosImportError`.
enum GooglePhotosAppError: Error, Equatable {
    /// The face model is missing: nothing could be scanned, so nothing is imported.
    case recognitionUnavailable
    /// The phone locked (protected data became unavailable): the import was stopped.
    case pausedForDeviceLock
}

/// Screen model for "Add from Google Photos" (People tab) and the Google Photos section (Settings).
///
/// Everything it shows is a fixed, user-facing string or a count: never a Google URL, token, media
/// item id or file name (invariant 2). Signed-in state is asked of the importer (Keychain) and only
/// kept in memory, never in UserDefaults (invariant 5).
@MainActor @Observable
public final class GooglePhotosImportModel {
    public enum State: Equatable, Sendable {
        case idle
        case signingIn
        case waitingForPicker
        case downloading(done: Int, total: Int)
        case scanning
        case done(Summary)
        case error(String)
    }

    public struct Summary: Equatable, Sendable {
        public var photosPicked: Int
        public var facesFound: Int
        public var skipped: Int

        init(_ progress: GooglePhotosImportProgress) {
            photosPicked = progress.picked
            facesFound = progress.facesEmbedded
            skipped = progress.skipped
        }

        /// e.g. "Picked 12 photos, found 5 faces (2 skipped). Review new faces in Who is this?"
        public var text: String {
            var sentence =
                "Picked \(photosPicked) \(photosPicked == 1 ? "photo" : "photos"), "
                + "found \(facesFound) \(facesFound == 1 ? "face" : "faces")"
            if skipped > 0 { sentence += " (\(skipped) skipped)" }
            sentence += "."
            return facesFound > 0 ? sentence + " Review new faces in Who is this?" : sentence
        }
    }

    public static let reauthenticationMessage = "Google sign-in expired. Import again to sign in."
    public static let busyMessage = "A photo scan is already running."
    public static let pausedMessage = "Import paused (phone locked). Run it again to continue."
    public static let notConfiguredMessage =
        "Google Photos isn't set up in this build. Put your Google OAuth client ID in "
        + "App/Local.xcconfig as HALO_GOOGLE_CLIENT_ID and rebuild. Steps: e2e/google-photos.md."
    public static let explanation =
        "Only photos you pick are downloaded. Faces are found on this device and never uploaded."

    public private(set) var state: State = .idle
    public private(set) var isSignedIn = false
    /// False when the build has no Google client ID: the entry points are hidden.
    public let isConfigured: Bool

    @ObservationIgnored weak var driver: (any GooglePhotosImportDriving)?
    @ObservationIgnored private let importer: any GooglePhotosImporting
    /// Bumped per run and by `reset()`; results and progress of an older run are ignored.
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var userCancelled = false

    init(importer: any GooglePhotosImporting) {
        self.importer = importer
        isConfigured = importer.isConfigured
    }

    public var isRunning: Bool {
        switch state {
        case .signingIn, .waitingForPicker, .downloading, .scanning: true
        case .idle, .done, .error: false
        }
    }

    /// Progress line while running, nil otherwise.
    public var progressText: String? {
        switch state {
        case .signingIn: "Signing in to Google…"
        case .waitingForPicker: "Pick photos in Google Photos, then come back to Halo."
        case .downloading(let done, let total): "Downloading \(done) of \(total) photos…"
        case .scanning: "Finding faces on this device…"
        case .idle, .done, .error: nil
        }
    }

    /// Result line after a run, nil otherwise.
    public var message: String? {
        switch state {
        case .done(let summary): summary.text
        case .error(let text): text
        default: nil
        }
    }

    /// Signs in if needed, lets the user pick photos in Google Photos, then imports them. New faces
    /// are suggestions only; they show up in "Who is this?" (invariant 3).
    public func start() async {
        guard !isRunning, let driver else { return }
        runID += 1
        let id = runID
        userCancelled = false
        state = .signingIn
        // Progress arrives on the importer's actor; this keeps it in order on the main actor.
        let (updates, continuation) = AsyncStream.makeStream(
            of: GooglePhotosImportProgress.self, bufferingPolicy: .bufferingNewest(8))
        let consumer = Task { [weak self] in
            for await progress in updates { self?.apply(progress, runID: id) }
        }
        let outcome: Result<GooglePhotosImportProgress, any Error>
        do {
            outcome = .success(
                try await driver.runGooglePhotosImport { progress in continuation.yield(progress) })
        } catch {
            outcome = .failure(error)
        }
        continuation.finish()
        await consumer.value
        guard id == runID else { return }
        switch outcome {
        case .success(let progress): state = .done(Summary(progress))
        case .failure(let error): state = Self.state(after: error, userCancelled: userCancelled)
        }
        await refreshSignInState()
    }

    /// Stops the running import. Photos already imported are kept.
    public func cancel() {
        guard isRunning else { return }
        userCancelled = true
        driver?.cancelGooglePhotosImport()
    }

    /// Revokes the Google grant and deletes the tokens. Imported faces stay.
    public func signOut() async {
        guard !isRunning else { return }
        await importer.signOut()
        await refreshSignInState()
    }

    public func refreshSignInState() async {
        let signedIn = isConfigured ? await importer.isSignedIn() : false
        isSignedIn = signedIn
    }

    /// The kill switch: forget every run in flight and show a fresh, signed-out screen.
    func reset() {
        runID += 1
        userCancelled = false
        state = .idle
        isSignedIn = false
    }

    private func apply(_ progress: GooglePhotosImportProgress, runID id: Int) {
        guard id == runID, isRunning else { return }
        switch progress.phase {
        case .signingIn: state = .signingIn
        case .waitingForPicker: state = .waitingForPicker
        case .downloading: state = .downloading(done: progress.downloaded, total: progress.picked)
        case .scanning, .clustering: state = .scanning
        case .finished: break  // the returned result decides
        }
    }

    /// What the screen shows after a failed run. Fixed strings only.
    static func state(after error: any Error, userCancelled: Bool) -> State {
        if let message = message(for: error, userCancelled: userCancelled) { return .error(message) }
        return .idle
    }

    /// nil when there is nothing to report (the user cancelled).
    static func message(for error: any Error, userCancelled: Bool) -> String? {
        if error is CancellationError {
            return userCancelled
                ? nil
                : "The import was interrupted. Photos already imported were kept; import again to continue."
        }
        switch error {
        case GooglePhotosImportError.notConfigured: return notConfiguredMessage
        case GooglePhotosImportError.cancelled: return nil
        case GooglePhotosImportError.reauthenticationRequired: return reauthenticationMessage
        case GooglePhotosImportError.pickerTimedOut:
            return "Google Photos stopped waiting for your selection. Import again to pick photos."
        case GooglePhotosImportError.network:
            return "Couldn't reach Google Photos. Check your connection and try again."
        case GooglePhotosImportError.busy: return busyMessage
        case GooglePhotosAppError.pausedForDeviceLock: return pausedMessage
        case GooglePhotosAppError.recognitionUnavailable:
            return "The face model isn't installed, so photos can't be scanned. Nothing was imported."
        default: return "Google Photos import failed. Photos already imported were kept."
        }
    }
}

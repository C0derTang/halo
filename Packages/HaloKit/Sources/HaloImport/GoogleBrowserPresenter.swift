import Foundation
import HaloCore
import Synchronization

#if os(iOS)
    import AuthenticationServices
    import UIKit
#endif

/// The two steps of the Google import that leave the app: the sign-in page and the Photos Picker.
/// Injected so the importer is testable without a browser.
public protocol GoogleBrowserPresenting: Sendable {
    /// Shows Google sign-in at `url` and returns the redirect URL (scheme `callbackScheme`).
    /// Throws `GooglePhotosImportError.cancelled` when the user closes the page.
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
    /// Opens the Photos Picker outside the app (Safari or the Google Photos app) and returns once
    /// it is handed off. Completion is decided by polling the session, not by this call.
    func openPicker(_ url: URL) async throws
}

/// Used where no browser exists (macOS host): every step fails as not configured.
struct UnavailableBrowserPresenter: GoogleBrowserPresenting {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        throw GooglePhotosImportError.notConfigured
    }
    func openPicker(_ url: URL) async throws { throw GooglePhotosImportError.notConfigured }
}

/// Resumes a continuation at most once, from any thread.
final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, any Error>?>

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ result: Result<Value, any Error>) {
        let pending = continuation.withLock { stored -> CheckedContinuation<Value, any Error>? in
            defer { stored = nil }
            return stored
        }
        pending?.resume(with: result)
    }
}

#if os(iOS)
    /// iOS presenter: sign-in in `ASWebAuthenticationSession` (shared Safari cookies, so an
    /// already signed-in Google account is reused: `prefersEphemeralWebBrowserSession = false`);
    /// the picker via `UIApplication.open`, which may hand off to the Google Photos app.
    @MainActor
    public final class WebAuthenticationPresenter: NSObject, GoogleBrowserPresenting,
        ASWebAuthenticationPresentationContextProviding
    {
        private var session: ASWebAuthenticationSession?
        private var anchor: UIWindow?

        public nonisolated override init() { super.init() }

        public func authenticate(url: URL, callbackScheme: String) async throws -> URL {
            guard let window = Self.presentationWindow() else { throw GooglePhotosImportError.cancelled }
            anchor = window
            defer {
                session = nil
                anchor = nil
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<URL, any Error>) in
                    let once = ResumeOnce(continuation)
                    let session = ASWebAuthenticationSession(
                        url: url, callback: .customScheme(callbackScheme)
                    ) { callbackURL, _ in
                        // Any error (closed by the user, cancelled, failed to load) ends sign-in.
                        once.resume(
                            callbackURL.map { .success($0) } ?? .failure(GooglePhotosImportError.cancelled))
                    }
                    session.presentationContextProvider = self
                    session.prefersEphemeralWebBrowserSession = false
                    self.session = session
                    if !session.start() { once.resume(.failure(GooglePhotosImportError.cancelled)) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.session?.cancel() }
            }
        }

        public func openPicker(_ url: URL) async throws {
            guard await UIApplication.shared.open(url) else { throw GooglePhotosImportError.network }
        }

        public nonisolated func presentationAnchor(for session: ASWebAuthenticationSession)
            -> ASPresentationAnchor
        {
            MainActor.assumeIsolated {
                if let anchor { return anchor }
                // Only reached if Apple asks again after `authenticate` returned; reuse any window.
                if let window = Self.presentationWindow() { return window }
                guard let scene = Self.windowScenes().first else {
                    preconditionFailure("ASWebAuthenticationSession needs a window scene")
                }
                return UIWindow(windowScene: scene)
            }
        }

        private static func windowScenes() -> [UIWindowScene] {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        }

        private static func presentationWindow() -> UIWindow? {
            let windows = windowScenes().flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first
        }
    }
#endif

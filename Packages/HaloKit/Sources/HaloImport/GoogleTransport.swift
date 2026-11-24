import Foundation
import HaloCore

/// HTTP seam for the Google import, so the client is testable with canned responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The only hosts the Google import ever talks to (invariant 2): Google sign-in, the OAuth token
/// endpoints, the Photos Picker API and the picked items' `baseUrl` content hosts. Every outbound
/// request and every redirect is checked against this list; anything else is refused.
enum GoogleHosts {
    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        if ["accounts.google.com", "oauth2.googleapis.com", "photospicker.googleapis.com"].contains(host) {
            return true
        }
        return host == "googleusercontent.com" || host.hasSuffix(".googleusercontent.com")
    }
}

/// `HTTPTransport` over an ephemeral `URLSession`: no cookie jar, no credential store and no
/// on-disk URL cache, so neither tokens nor downloaded photos are persisted by the networking layer.
/// Requests (and redirects) to hosts outside `GoogleHosts` are refused.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard GoogleHosts.isAllowed(request.url) else { throw GooglePhotosImportError.network }
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard.shared)
        guard let http = response as? HTTPURLResponse else { throw GooglePhotosImportError.network }
        return (data, http)
    }
}

/// Follows a redirect only to an allowed (Google) host; any other redirect is not followed and the
/// 3xx response fails the request, so the bearer token is never sent outside `GoogleHosts`.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectGuard()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        GoogleHosts.isAllowed(request.url) ? request : nil
    }
}

/// Cleanup calls (session DELETE, token revoke) that must neither block the kill switch on a slow
/// network nor be cancelled along with the import they clean up after.
enum BestEffort {
    /// Runs `operation` in a fresh task (not cancelled with the caller) and returns once it finishes
    /// or `timeout` (real time) passes, whichever is first; the operation is then cancelled.
    static func run(timeout: Duration, _ operation: @escaping @Sendable () async -> Void) async {
        await Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await operation() }
                group.addTask { try? await Task.sleep(for: timeout) }
                await group.next()
                group.cancelAll()
            }
        }.value
    }
}

/// Monotonic time + sleep for the picker poll loop and baseUrl expiry, injectable for tests.
public protocol GoogleImportClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemGoogleImportClock: GoogleImportClock {
    public init() {}
    public var now: ContinuousClock.Instant { ContinuousClock.now }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

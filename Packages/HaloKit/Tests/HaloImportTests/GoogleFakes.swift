// Synthetic fakes for the Google Photos import tests. No network, no real Keychain, no real photos:
// every "photo" is a solid-gray image generated in memory.

import CoreGraphics
import Foundation
import HaloBridgeKit
import HaloCore
import ImageIO
import Synchronization
import UniformTypeIdentifiers

@testable import HaloImport

// MARK: - Keychain stand-in

/// In-memory `KeyStore`: tests never touch the real Keychain.
final class InMemoryKeyStore: KeyStore, Sendable {
    private let items = Mutex<[String: Data]>([:])
    func read(account: String) throws -> Data? { items.withLock { $0[account] } }
    func write(_ data: Data, account: String) throws { items.withLock { $0[account] = data } }
    func delete(account: String) throws { _ = items.withLock { $0.removeValue(forKey: account) } }
    var isEmpty: Bool { items.withLock { $0.isEmpty } }
}

enum GoogleFixture {
    static let clientID = "1234567890-abcdef.apps.googleusercontent.com"
    static let callbackScheme = "com.googleusercontent.apps.1234567890-abcdef"
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func validTokens(expiresIn: TimeInterval = 3600) -> GoogleTokens {
        GoogleTokens(
            accessToken: "access-0", expiresAt: now.addingTimeInterval(expiresIn), refreshToken: "refresh-0")
    }

    static func tokenStore(_ tokens: GoogleTokens? = validTokens()) -> (
        KeychainGoogleTokenStore, InMemoryKeyStore
    ) {
        let keys = InMemoryKeyStore()
        let store = KeychainGoogleTokenStore(keyStore: keys)
        if let tokens { try! store.save(tokens) }
        return (store, keys)
    }

    static func png(width: Int, height: Int, orientation: Int? = nil) -> Data {
        let image = PhotoScanFixture.image(width: width, height: height)
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "halo-gphotos-tests-\(UUID().uuidString)")
    }

    static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static func formFields(_ request: URLRequest) -> [String: String] {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0]] = parts[1].removingPercentEncoding
        }
        return fields
    }
}

// MARK: - Transport

/// Scripted transport: every request goes to `handler`, and is recorded.
final class ScriptedTransport: HTTPTransport, Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)
    private let handler: Handler
    let requests = Recorder<URLRequest>()

    init(_ handler: @escaping Handler) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, data) = try await handler(request)
        return (data, GoogleFixture.response(request.url!, status))
    }
}

/// A fake Google: OAuth token endpoint, Photos Picker API and baseUrl content host, all in memory.
final class FakeGoogle: HTTPTransport, Sendable {
    struct Item: Sendable {
        var id: String
        var type: String  // PHOTO | VIDEO
        var width: Int
        var height: Int = 800
    }

    struct State {
        var items: [Item] = []
        /// Polls answered with `mediaItemsSet == false` before it turns true.
        var pollsBeforeSet = 1
        var polls = 0
        var timeoutIn = "1800s"
        /// Incremented on every `mediaItems.list` call; baseUrls embed it.
        var listGeneration = 0
        /// baseUrls from generations below this answer 403 (expired).
        var firstValidGeneration = 0
        /// Item ids whose download hangs until the requesting task is cancelled.
        var hangingDownloads: Set<String> = []
        /// Called (once) when a download for this id starts.
        var onDownload: [String: @Sendable () -> Void] = [:]
        var refreshResponse: (Int, Data)?
        var deletedSessions: [String] = []
        var createdSessions = 0
        var downloads: [String] = []
        var downloadURLs: [URL] = []
    }

    let state = Mutex(State())
    let requests = Recorder<URLRequest>()

    init(items: [Item] = [], pollsBeforeSet: Int = 1) {
        state.withLock {
            $0.items = items
            $0.pollsBeforeSet = pollsBeforeSet
        }
    }

    func with<T>(_ body: (inout State) -> T) -> T { state.withLock { body(&$0) } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        let (status, data) = try await route(request, url: url)
        return (data, GoogleFixture.response(url, status))
    }

    private func route(_ request: URLRequest, url: URL) async throws -> (Int, Data) {
        let host = url.host ?? ""
        let method = request.httpMethod ?? "GET"
        switch (host, method, url.path) {
        case ("oauth2.googleapis.com", "POST", "/token"):
            let fields = GoogleFixture.formFields(request)
            if fields["grant_type"] == "refresh_token", let scripted = with({ $0.refreshResponse }) {
                return scripted
            }
            return (
                200,
                GoogleFixture.json([
                    "access_token": "access-new", "expires_in": 3599, "refresh_token": "refresh-new",
                    "scope": GoogleOAuth.scope, "token_type": "Bearer",
                ])
            )
        case ("oauth2.googleapis.com", "POST", "/revoke"):
            return (200, Data())
        case ("photospicker.googleapis.com", "POST", "/v1/sessions"):
            with { $0.createdSessions += 1 }
            return (200, sessionJSON(set: false))
        case ("photospicker.googleapis.com", "GET", "/v1/sessions/s1"):
            let set = with { s -> Bool in
                s.polls += 1
                return s.polls > s.pollsBeforeSet
            }
            return (200, sessionJSON(set: set))
        case ("photospicker.googleapis.com", "DELETE", "/v1/sessions/s1"):
            with { $0.deletedSessions.append("s1") }
            return (200, Data("{}".utf8))
        case ("photospicker.googleapis.com", "GET", "/v1/mediaItems"):
            return (200, listPage(url))
        case ("lh3.googleusercontent.com", "GET", _):
            return try await download(url)
        default:
            return (404, Data())
        }
    }

    private func sessionJSON(set: Bool) -> Data {
        let timeout = with { $0.timeoutIn }
        return GoogleFixture.json([
            "id": "s1", "pickerUri": "https://photos.google.com/picker/s1",
            "pollingConfig": ["pollInterval": "5s", "timeoutIn": timeout],
            "expireTime": "2026-11-24T12:00:00Z", "mediaItemsSet": set,
        ])
    }

    private func listPage(_ url: URL) -> Data {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pageSize = Int(query.first { $0.name == "pageSize" }?.value ?? "") ?? 100
        let offset = Int(query.first { $0.name == "pageToken" }?.value ?? "0") ?? 0
        let (items, generation) = with { s -> ([Item], Int) in
            if offset == 0 { s.listGeneration += 1 }
            return (s.items, s.listGeneration)
        }
        let page = items.dropFirst(offset).prefix(pageSize)
        var body: [String: Any] = [
            "mediaItems": page.map { item in
                [
                    "id": item.id, "createTime": "2026-01-01T00:00:00Z", "type": item.type,
                    "mediaFile": [
                        "baseUrl": "https://lh3.googleusercontent.com/ppa/\(item.id)-g\(generation)",
                        "mimeType": item.type == "PHOTO" ? "image/png" : "video/mp4",
                        "filename": "IMG_\(item.id).PNG",
                    ],
                ] as [String: Any]
            }
        ]
        if offset + pageSize < items.count { body["nextPageToken"] = String(offset + pageSize) }
        return GoogleFixture.json(body)
    }

    private func download(_ url: URL) async throws -> (Int, Data) {
        // /ppa/<id>-g<generation>=w2048-h2048
        let last = url.lastPathComponent
        let stem = String(last.split(separator: "=").first ?? "")
        guard let dash = stem.lastIndex(of: "-") else { return (404, Data()) }
        let id = String(stem[..<dash])
        let generation = Int(stem[stem.index(dash, offsetBy: 2)...]) ?? -1
        let (item, valid, hang, hook) = with { s -> (Item?, Bool, Bool, (@Sendable () -> Void)?) in
            s.downloadURLs.append(url)
            let hook = s.onDownload.removeValue(forKey: id)
            return (
                s.items.first { $0.id == id }, generation >= s.firstValidGeneration,
                s.hangingDownloads.contains(id),
                hook
            )
        }
        hook?()
        if hang {
            try await Task.sleep(for: .seconds(30))
        }
        guard let item, valid else { return (403, Data()) }
        with { $0.downloads.append(id) }
        return (200, GoogleFixture.png(width: item.width, height: item.height))
    }
}

// MARK: - Browser + clock

/// Answers sign-in like Google would (echoing `state`), or with a scripted callback.
final class FakePresenter: GoogleBrowserPresenting, Sendable {
    enum Mode: Sendable {
        case approve
        case wrongState
        case deny
        case userClosed
    }

    let mode: Mode
    let authURLs = Recorder<URL>()
    let pickerURLs = Recorder<URL>()

    init(_ mode: Mode = .approve) { self.mode = mode }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        authURLs.append(url)
        let state =
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?
            .value ?? ""
        switch mode {
        case .approve: return URL(string: "\(callbackScheme):/oauthredirect?state=\(state)&code=auth-code")!
        case .wrongState: return URL(string: "\(callbackScheme):/oauthredirect?state=forged&code=auth-code")!
        case .deny: return URL(string: "\(callbackScheme):/oauthredirect?state=\(state)&error=access_denied")!
        case .userClosed: throw GooglePhotosImportError.cancelled
        }
    }

    func openPicker(_ url: URL) async throws { pickerURLs.append(url) }
}

/// Fake monotonic clock: `sleep` advances time instantly.
final class FakeClock: GoogleImportClock, Sendable {
    private let origin = ContinuousClock.now
    private let offset = Mutex<Duration>(.zero)
    let sleeps = Recorder<Duration>()

    var now: ContinuousClock.Instant { origin.advanced(by: offset.withLock { $0 }) }

    func advance(by duration: Duration) { offset.withLock { $0 += duration } }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        sleeps.append(duration)
        advance(by: duration)
        await Task.yield()
    }
}

/// Fixed-access-token provider for client tests; records refresh requests.
final class StaticTokens: GoogleAccessTokenProviding, Sendable {
    let refreshes = Recorder<Bool>()
    func accessToken(forceRefresh: Bool) async throws -> String {
        if forceRefresh { refreshes.append(true) }
        return forceRefresh ? "access-refreshed" : "access-0"
    }
}

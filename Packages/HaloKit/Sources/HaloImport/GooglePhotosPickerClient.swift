import Foundation
import HaloCore

/// One item the user picked in Google's Photos Picker. Only what the import needs: the Google
/// filename is deliberately not decoded (it is never stored or used).
public struct PickedMediaItem: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case photo, video, other
    }

    /// Stable across sessions; stored as `"gphotos:" + id` in `FaceEmbedding.sourceRef`.
    public var id: String
    public var kind: Kind
    /// Valid for about 60 minutes after listing; needs the bearer token.
    public var baseURL: URL?
    public var createTime: Date?

    public init(id: String, kind: Kind, baseURL: URL?, createTime: Date? = nil) {
        self.id = id
        self.kind = kind
        self.baseURL = baseURL
        self.createTime = createTime
    }

    public var sourceRef: String { GooglePhotosCache.sourceRefPrefix + id }
}

/// A Photos Picker session as the import sees it.
public struct PickerSession: Hashable, Sendable {
    public var id: String
    public var pickerURI: URL?
    /// How often to poll (`pollingConfig.pollInterval`).
    public var pollInterval: Duration
    /// Time left to pick (`pollingConfig.timeoutIn`); nil when absent.
    public var timeoutIn: Duration?
    public var mediaItemsSet: Bool

    public init(
        id: String, pickerURI: URL?, pollInterval: Duration, timeoutIn: Duration?, mediaItemsSet: Bool
    ) {
        self.id = id
        self.pickerURI = pickerURI
        self.pollInterval = pollInterval
        self.timeoutIn = timeoutIn
        self.mediaItemsSet = mediaItemsSet
    }

    /// The picker page to open: `pickerUri` + `/autoclose`, so it closes itself when done.
    public var autocloseURL: URL? {
        // Opened in Safari / Google Photos, never fetched by us; still only ever a Google https page.
        guard let pickerURI, pickerURI.scheme?.lowercased() == "https",
            let host = pickerURI.host?.lowercased(), host == "google.com" || host.hasSuffix(".google.com")
        else { return nil }
        return URL(string: pickerURI.absoluteString + "/autoclose")
    }
}

/// Supplies bearer tokens to the client; `GoogleAuthorizer` in production.
protocol GoogleAccessTokenProviding: Sendable {
    /// A valid access token, refreshed first when expired or when `forceRefresh` is set.
    func accessToken(forceRefresh: Bool) async throws -> String
}

/// Internal client errors the importer acts on; everything else is a `GooglePhotosImportError`.
enum GooglePickerClientError: Error, Equatable, Sendable {
    /// The baseUrl was rejected (403 / 404): it expired, so list the items again.
    case baseURLExpired
}

/// Photos Picker API client: create, poll, list (paged), download, delete. Errors are mapped to
/// `GooglePhotosImportError` and never carry response bodies or URLs (they may contain ids).
/// Nothing here logs. The only requests it makes are Picker API calls and baseUrl GETs (invariant 2).
struct GooglePhotosPickerClient: Sendable {
    static let apiBase = URL(string: "https://photospicker.googleapis.com/v1/")!

    let transport: any HTTPTransport
    let tokens: any GoogleAccessTokenProviding
    var pageSize = 100

    // MARK: Sessions

    func createSession(maxItemCount: Int) async throws -> PickerSession {
        var request = URLRequest(url: Self.apiBase.appending(path: "sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // int64 fields are JSON strings in the proto3 JSON mapping.
        request.httpBody = Data(#"{"pickingConfig":{"maxItemCount":"\#(maxItemCount)"}}"#.utf8)
        return try Self.session(from: try await authorizedJSON(request))
    }

    func session(id: String) async throws -> PickerSession {
        let request = URLRequest(url: Self.apiBase.appending(path: "sessions").appending(path: id))
        do {
            return try Self.session(from: try await authorizedJSON(request))
        } catch GooglePickerClientError.baseURLExpired {
            // 403/404 on the session itself: it expired or was deleted.
            throw GooglePhotosImportError.pickerTimedOut
        }
    }

    /// Best effort is up to the caller; this throws like any other call.
    func deleteSession(id: String) async throws {
        var request = URLRequest(url: Self.apiBase.appending(path: "sessions").appending(path: id))
        request.httpMethod = "DELETE"
        _ = try await authorized(request)
    }

    /// Polls every `pollInterval` until the user finished picking. Throws `.pickerTimedOut` when
    /// Google reports no time left (`timeoutIn` 0) or the initial `timeoutIn` has elapsed.
    func waitForSelection(_ initial: PickerSession, clock: any GoogleImportClock) async throws
        -> PickerSession
    {
        let deadline = clock.now.advanced(by: initial.timeoutIn ?? .seconds(1800))
        var current = initial
        while !current.mediaItemsSet {
            if let left = current.timeoutIn, left <= .zero { throw GooglePhotosImportError.pickerTimedOut }
            if clock.now >= deadline { throw GooglePhotosImportError.pickerTimedOut }
            try await clock.sleep(for: Self.clampedPollInterval(current.pollInterval))
            current = try await session(id: initial.id)
        }
        return current
    }

    // MARK: Media items

    /// Every picked item, following `nextPageToken`.
    func listMediaItems(sessionID: String) async throws -> [PickedMediaItem] {
        var items: [PickedMediaItem] = []
        var pageToken: String?
        var pages = 0
        repeat {
            var components = URLComponents(
                url: Self.apiBase.appending(path: "mediaItems"), resolvingAgainstBaseURL: false)!
            var query = [
                URLQueryItem(name: "sessionId", value: sessionID),
                URLQueryItem(name: "pageSize", value: String(pageSize)),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = query
            let data = try await authorizedJSON(URLRequest(url: components.url!))
            guard let page = try? JSONDecoder().decode(MediaItemsPage.self, from: data) else {
                throw GooglePhotosImportError.network
            }
            items += (page.mediaItems ?? []).map(\.item)
            pageToken = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            pages += 1
        } while pageToken != nil && pages < 1000
        return items
    }

    /// Downloads one picked photo, bounded to `maxPixelSize` on each side (`=w<n>-h<n>`).
    /// Throws `GooglePickerClientError.baseURLExpired` on 403 / 404.
    func download(_ item: PickedMediaItem, maxPixelSize: Int) async throws -> Data {
        guard let base = item.baseURL, GoogleHosts.isAllowed(base),
            let url = URL(string: base.absoluteString + "=w\(maxPixelSize)-h\(maxPixelSize)")
        else { throw GooglePhotosImportError.network }
        return try await authorized(URLRequest(url: url))
    }

    // MARK: - Plumbing

    private func authorizedJSON(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await authorized(request)
    }

    /// Sends with the bearer token; on 401 refreshes once and retries.
    private func authorized(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            var signed = request
            signed.cachePolicy = .reloadIgnoringLocalCacheData
            let token = try await tokens.accessToken(forceRefresh: attempt > 0)
            signed.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await transport.send(signed)
            } catch {
                throw Self.mapTransportError(error)
            }
            switch response.statusCode {
            case 200..<300: return data
            case 401 where attempt == 0: attempt += 1
            case 403, 404: throw GooglePickerClientError.baseURLExpired
            default: throw GooglePhotosImportError.network
            }
        }
    }

    static func mapTransportError(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let importError = error as? GooglePhotosImportError { return importError }
        return GooglePhotosImportError.network
    }

    static func clampedPollInterval(_ interval: Duration) -> Duration {
        min(max(interval, .seconds(1)), .seconds(30))
    }

    /// Parses a protobuf JSON duration such as `"5s"` or `"1.5s"`.
    static func duration(_ text: String?) -> Duration? {
        guard let text, text.hasSuffix("s"), let seconds = Double(text.dropLast()), seconds.isFinite,
            seconds >= 0
        else { return nil }
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }

    static func session(from data: Data) throws -> PickerSession {
        guard let body = try? JSONDecoder().decode(SessionBody.self, from: data), !body.id.isEmpty else {
            throw GooglePhotosImportError.network
        }
        return PickerSession(
            id: body.id, pickerURI: body.pickerUri.flatMap(URL.init(string:)),
            pollInterval: duration(body.pollingConfig?.pollInterval) ?? .seconds(5),
            timeoutIn: duration(body.pollingConfig?.timeoutIn),
            mediaItemsSet: body.mediaItemsSet ?? false)
    }

    // MARK: - Wire format (only the fields we use)

    private struct SessionBody: Decodable {
        struct PollingConfig: Decodable {
            var pollInterval: String?
            var timeoutIn: String?
        }
        var id: String
        var pickerUri: String?
        var pollingConfig: PollingConfig?
        var mediaItemsSet: Bool?
    }

    private struct MediaItemsPage: Decodable {
        var mediaItems: [MediaItemBody]?
        var nextPageToken: String?
    }

    private struct MediaItemBody: Decodable {
        struct MediaFile: Decodable {
            var baseUrl: String?
        }
        var id: String
        var type: String?
        var createTime: String?
        var mediaFile: MediaFile?

        var item: PickedMediaItem {
            let kind: PickedMediaItem.Kind =
                switch type {
                case "PHOTO": .photo
                case "VIDEO": .video
                default: .other
                }
            return PickedMediaItem(
                id: id, kind: kind, baseURL: mediaFile?.baseUrl.flatMap(URL.init(string:)),
                createTime: createTime.flatMap { try? Date($0, strategy: .iso8601) })
        }
    }
}

import Foundation
import HaloCore
import Testing

@testable import HaloImport

private typealias G = GoogleFixture

private func client(_ google: FakeGoogle, pageSize: Int = 100) -> GooglePhotosPickerClient {
    GooglePhotosPickerClient(transport: google, tokens: StaticTokens(), pageSize: pageSize)
}

@Suite struct GooglePickerClientTests {
    // MARK: Sessions

    @Test func createSessionRequestsAtMost200ItemsAndParsesPolling() async throws {
        let google = FakeGoogle()
        let session = try await client(google).createSession(maxItemCount: 200)
        #expect(session.id == "s1")
        #expect(session.pollInterval == .seconds(5))
        #expect(session.timeoutIn == .seconds(1800))
        #expect(!session.mediaItemsSet)
        #expect(session.autocloseURL?.absoluteString == "https://photos.google.com/picker/s1/autoclose")

        let request = try #require(google.requests.all.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://photospicker.googleapis.com/v1/sessions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-0")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let picking = body?["pickingConfig"] as? [String: Any]
        #expect(picking?["maxItemCount"] as? String == "200")
    }

    @Test func pickerURIOutsideGoogleIsNeverOpened() {
        let foreign = PickerSession(
            id: "s", pickerURI: URL(string: "https://evil.example/picker"), pollInterval: .seconds(5),
            timeoutIn: nil, mediaItemsSet: false)
        #expect(foreign.autocloseURL == nil)
        let plain = PickerSession(
            id: "s", pickerURI: URL(string: "http://photos.google.com/picker/s"), pollInterval: .seconds(5),
            timeoutIn: nil, mediaItemsSet: false)
        #expect(plain.autocloseURL == nil)
    }

    @Test func durationsAreParsed() {
        #expect(GooglePhotosPickerClient.duration("5s") == .seconds(5))
        #expect(GooglePhotosPickerClient.duration("1800s") == .seconds(1800))
        #expect(GooglePhotosPickerClient.duration("0.5s") == .milliseconds(500))
        #expect(GooglePhotosPickerClient.duration("0s") == .zero)
        #expect(GooglePhotosPickerClient.duration("5") == nil)
        #expect(GooglePhotosPickerClient.duration(nil) == nil)
    }

    // MARK: Poll loop (fake clock)

    @Test func pollsEveryIntervalUntilMediaItemsSet() async throws {
        let google = FakeGoogle(pollsBeforeSet: 3)
        let clock = FakeClock()
        let c = client(google)
        let session = try await c.createSession(maxItemCount: 200)
        let done = try await c.waitForSelection(session, clock: clock)
        #expect(done.mediaItemsSet)
        #expect(clock.sleeps.all == Array(repeating: .seconds(5), count: 4))
        #expect(google.with { $0.polls } == 4)
    }

    @Test func pollTimesOutWhenTimeoutInElapses() async throws {
        let google = FakeGoogle(pollsBeforeSet: 10_000)
        google.with { $0.timeoutIn = "12s" }
        let clock = FakeClock()
        let c = client(google)
        let session = try await c.createSession(maxItemCount: 200)
        await #expect(throws: GooglePhotosImportError.pickerTimedOut) {
            _ = try await c.waitForSelection(session, clock: clock)
        }
        // 5s + 5s + 5s passes the 12s deadline: three polls, no more.
        #expect(clock.sleeps.all.count == 3)
        #expect(google.with { $0.polls } == 3)
    }

    @Test func pollStopsWhenGoogleReportsNoTimeLeft() async throws {
        let google = FakeGoogle(pollsBeforeSet: 10_000)
        let clock = FakeClock()
        let c = client(google)
        let session = try await c.createSession(maxItemCount: 200)
        google.with { $0.timeoutIn = "0s" }
        await #expect(throws: GooglePhotosImportError.pickerTimedOut) {
            _ = try await c.waitForSelection(session, clock: clock)
        }
        #expect(google.with { $0.polls } == 1)
    }

    @Test func pollIntervalIsClamped() {
        #expect(GooglePhotosPickerClient.clampedPollInterval(.zero) == .seconds(1))
        #expect(GooglePhotosPickerClient.clampedPollInterval(.seconds(600)) == .seconds(30))
        #expect(GooglePhotosPickerClient.clampedPollInterval(.seconds(5)) == .seconds(5))
    }

    // MARK: Listing

    @Test func listingFollowsPagesAndClassifiesKinds() async throws {
        let items = (0..<7).map {
            FakeGoogle.Item(id: "m\($0)", type: $0 % 3 == 2 ? "VIDEO" : "PHOTO", width: 1000 + $0)
        }
        let google = FakeGoogle(items: items)
        let listed = try await client(google, pageSize: 3).listMediaItems(sessionID: "s1")
        #expect(listed.map(\.id) == items.map(\.id))
        #expect(listed.filter { $0.kind == .video }.map(\.id) == ["m2", "m5"])
        #expect(listed.allSatisfy { $0.baseURL?.host == "lh3.googleusercontent.com" })
        #expect(listed.allSatisfy { $0.sourceRef == "gphotos:" + $0.id })

        let pages = google.requests.all.filter { $0.url?.path == "/v1/mediaItems" }
        #expect(pages.count == 3)
        let tokens = pages.map {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first {
                $0.name == "pageToken"
            }?
            .value
        }
        #expect(tokens == [nil, "3", "6"])
        #expect(pages.allSatisfy { $0.url?.query?.contains("sessionId=s1") == true })
        #expect(pages.allSatisfy { $0.url?.query?.contains("pageSize=3") == true })
    }

    // MARK: Download + errors

    @Test func downloadRequestsA2048BoundWithTheBearerToken() async throws {
        let google = FakeGoogle(items: [.init(id: "m0", type: "PHOTO", width: 1000)])
        let c = client(google)
        let item = try #require(try await c.listMediaItems(sessionID: "s1").first)
        let data = try await c.download(item, maxPixelSize: 2048)
        #expect(!data.isEmpty)
        let request = try #require(google.requests.all.last)
        #expect(request.url?.absoluteString.hasSuffix("=w2048-h2048") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-0")
    }

    @Test func expiredBaseURLIsReportedForReListing() async throws {
        let google = FakeGoogle(items: [.init(id: "m0", type: "PHOTO", width: 1000)])
        google.with { $0.firstValidGeneration = 2 }
        let c = client(google)
        let stale = try #require(try await c.listMediaItems(sessionID: "s1").first)
        await #expect(throws: GooglePickerClientError.baseURLExpired) {
            _ = try await c.download(stale, maxPixelSize: 2048)
        }
        let fresh = try #require(try await c.listMediaItems(sessionID: "s1").first)
        #expect(try await !c.download(fresh, maxPixelSize: 2048).isEmpty)
    }

    @Test func baseURLOutsideGoogleIsNeverFetched() async throws {
        let transport = ScriptedTransport { _ in (200, Data()) }
        let c = GooglePhotosPickerClient(transport: transport, tokens: StaticTokens())
        let item = PickedMediaItem(id: "x", kind: .photo, baseURL: URL(string: "https://evil.example/p"))
        await #expect(throws: GooglePhotosImportError.network) {
            _ = try await c.download(item, maxPixelSize: 2048)
        }
        #expect(transport.requests.all.isEmpty)
    }

    @Test func unauthorizedRefreshesOnceThenRetries() async throws {
        let calls = Recorder<String>()
        let transport = ScriptedTransport { request in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            calls.append(auth)
            return auth == "Bearer access-refreshed" ? (200, G.json(["id": "s1"])) : (401, Data())
        }
        let tokens = StaticTokens()
        let c = GooglePhotosPickerClient(transport: transport, tokens: tokens)
        let session = try await c.session(id: "s1")
        #expect(session.id == "s1")
        #expect(calls.all == ["Bearer access-0", "Bearer access-refreshed"])
        #expect(tokens.refreshes.all.count == 1)
    }

    @Test func serverAndTransportErrorsMapToNetworkWithoutDetails() async throws {
        let transport = ScriptedTransport { request in
            if request.httpMethod == "POST" { throw URLError(.notConnectedToInternet) }
            return (500, Data(#"{"error":{"message":"https://secret.example/?token=abc"}}"#.utf8))
        }
        let c = GooglePhotosPickerClient(transport: transport, tokens: StaticTokens())
        await #expect(throws: GooglePhotosImportError.network) {
            _ = try await c.createSession(maxItemCount: 200)
        }
        await #expect(throws: GooglePhotosImportError.network) {
            _ = try await c.listMediaItems(sessionID: "s1")
        }
    }

    @Test func onlyGoogleHostsAreAllowed() {
        for allowed in [
            "https://accounts.google.com/o/oauth2/v2/auth", "https://oauth2.googleapis.com/token",
            "https://photospicker.googleapis.com/v1/sessions", "https://lh3.googleusercontent.com/ppa/x",
        ] {
            #expect(GoogleHosts.isAllowed(URL(string: allowed)))
        }
        for refused in [
            "http://photospicker.googleapis.com/v1/sessions", "https://evil.example/",
            "https://googleusercontent.com.evil.example/x", "https://notgoogleusercontent.com/x",
            "https://www.googleapis.com/upload/x",
        ] {
            #expect(!GoogleHosts.isAllowed(URL(string: refused)))
        }
    }
}

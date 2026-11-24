import Foundation
import HaloCore
import Testing

@testable import HaloImport

private typealias G = GoogleFixture

private func authorizer(
    _ google: FakeGoogle, tokens: GoogleTokens? = G.validTokens(), presenter: FakePresenter = FakePresenter(),
    now: Date = G.now
) -> (GoogleAuthorizer, KeychainGoogleTokenStore, InMemoryKeyStore) {
    let (store, keys) = G.tokenStore(tokens)
    let auth = GoogleAuthorizer(
        oauth: GoogleOAuth(clientID: G.clientID)!, transport: google, tokenStore: store, presenter: presenter,
        now: { now })
    return (auth, store, keys)
}

@Suite struct GoogleAuthorizerTests {
    @Test func validAccessTokenIsUsedWithoutRefreshing() async throws {
        let google = FakeGoogle()
        let (auth, _, _) = authorizer(google)
        #expect(try await auth.accessToken(forceRefresh: false) == "access-0")
        #expect(google.requests.all.isEmpty)
    }

    @Test func expiredAccessTokenIsRefreshedAndSaved() async throws {
        let google = FakeGoogle()
        let (auth, store, _) = authorizer(google, tokens: G.validTokens(expiresIn: 30))
        #expect(try await auth.accessToken(forceRefresh: false) == "access-new")
        let saved = try #require(try store.load())
        #expect(saved.accessToken == "access-new")
        #expect(saved.refreshToken == "refresh-new")
        #expect(saved.expiresAt == G.now.addingTimeInterval(3599))
        let request = try #require(google.requests.all.first)
        #expect(G.formFields(request)["grant_type"] == "refresh_token")
        #expect(G.formFields(request)["refresh_token"] == "refresh-0")
        #expect(G.formFields(request)["client_secret"] == nil)
    }

    @Test func invalidGrantDeletesTokensAndRequiresReauthentication() async throws {
        let google = FakeGoogle()
        google.with {
            $0.refreshResponse = (
                400, G.json(["error": "invalid_grant", "error_description": "Token has been expired"])
            )
        }
        let (auth, store, keys) = authorizer(google, tokens: G.validTokens(expiresIn: -10))
        await #expect(throws: GooglePhotosImportError.reauthenticationRequired) {
            _ = try await auth.accessToken(forceRefresh: false)
        }
        #expect(try store.load() == nil)
        #expect(keys.isEmpty)
        #expect(await !auth.hasTokens())
    }

    @Test func otherRefreshFailuresKeepTheGrant() async throws {
        let google = FakeGoogle()
        google.with { $0.refreshResponse = (503, Data()) }
        let (auth, store, _) = authorizer(google, tokens: G.validTokens(expiresIn: -10))
        await #expect(throws: GooglePhotosImportError.network) {
            _ = try await auth.accessToken(forceRefresh: false)
        }
        #expect(try store.load() == G.validTokens(expiresIn: -10))
    }

    @Test func noGrantRequiresReauthentication() async throws {
        let (auth, _, _) = authorizer(FakeGoogle(), tokens: nil)
        await #expect(throws: GooglePhotosImportError.reauthenticationRequired) {
            _ = try await auth.accessToken(forceRefresh: false)
        }
    }

    @Test func signInExchangesTheCodeWithTheVerifierAndStoresTokens() async throws {
        let google = FakeGoogle()
        let presenter = FakePresenter(.approve)
        let (auth, store, _) = authorizer(google, tokens: nil, presenter: presenter)
        try await auth.signInIfNeeded()
        #expect(try store.load()?.accessToken == "access-new")

        let authURL = try #require(presenter.authURLs.all.first)
        let challenge = URLComponents(url: authURL, resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "code_challenge"
        }?.value
        let exchange = G.formFields(try #require(google.requests.all.first))
        #expect(exchange["code"] == "auth-code")
        #expect(exchange["grant_type"] == "authorization_code")
        let verifier = try #require(exchange["code_verifier"])
        #expect(PKCE(verifier: verifier).challenge == challenge)

        // Already signed in: no second browser trip.
        try await auth.signInIfNeeded()
        #expect(presenter.authURLs.all.count == 1)
    }

    @Test func stateMismatchIsRejectedAndNothingIsStored() async throws {
        let google = FakeGoogle()
        let (auth, _, keys) = authorizer(google, tokens: nil, presenter: FakePresenter(.wrongState))
        await #expect(throws: GooglePhotosImportError.network) { try await auth.signIn() }
        #expect(keys.isEmpty)
        // The forged code is never exchanged.
        #expect(google.requests.all.isEmpty)
    }

    @Test func declinedOrClosedSignInIsCancelled() async throws {
        for mode in [FakePresenter.Mode.deny, .userClosed] {
            let google = FakeGoogle()
            let (auth, _, keys) = authorizer(google, tokens: nil, presenter: FakePresenter(mode))
            await #expect(throws: GooglePhotosImportError.cancelled) { try await auth.signIn() }
            #expect(keys.isEmpty)
            #expect(google.requests.all.isEmpty)
        }
    }

    @Test func signOutDeletesTokensAndRevokesTheRefreshToken() async throws {
        let google = FakeGoogle()
        let (auth, _, keys) = authorizer(google)
        try await auth.signOut(revokeTimeout: .seconds(3))
        #expect(keys.isEmpty)
        let revoke = try #require(google.requests.all.first)
        #expect(revoke.url?.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(G.formFields(revoke)["token"] == "refresh-0")
    }

    @Test func signOutSucceedsLocallyWhenRevokeFails() async throws {
        let transport = ScriptedTransport { _ in throw URLError(.notConnectedToInternet) }
        let (store, keys) = G.tokenStore()
        let auth = GoogleAuthorizer(
            oauth: GoogleOAuth(clientID: G.clientID)!, transport: transport, tokenStore: store,
            presenter: FakePresenter(), now: { G.now })
        try await auth.signOut(revokeTimeout: .seconds(3))
        #expect(keys.isEmpty)
    }

    @Test func slowRevokeIsBoundedAndTokensAreGoneFirst() async throws {
        let google = FakeGoogle()
        google.with { $0.hangRevoke = true }  // would take 30 s
        let (auth, _, keys) = authorizer(google)
        let begin = ContinuousClock.now
        try await auth.signOut(revokeTimeout: .milliseconds(200))
        #expect(ContinuousClock.now - begin < .seconds(10))
        #expect(keys.isEmpty)
    }

    @Test func cancelledSignInNeverOpensTheBrowser() async throws {
        let presenter = FakePresenter(.approve)
        let (auth, _, keys) = authorizer(FakeGoogle(), tokens: nil, presenter: presenter)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await auth.signIn()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(presenter.authURLs.all.isEmpty)
        #expect(keys.isEmpty)
    }
}

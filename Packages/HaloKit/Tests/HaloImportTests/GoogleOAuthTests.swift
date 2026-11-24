import Foundation
import HaloBridgeKit
import HaloCore
import Testing

@testable import HaloImport

private typealias G = GoogleFixture

private func query(_ url: URL) -> [String: String] {
    Dictionary(
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        },
        uniquingKeysWith: { first, _ in first })
}

@Suite struct GoogleOAuthTests {
    let oauth = GoogleOAuth(clientID: G.clientID)!

    // MARK: Config

    @Test(arguments: [
        nil, "", "   ", "not-a-client-id", ".apps.googleusercontent.com", "a b.apps.googleusercontent.com",
    ])
    func missingOrInvalidClientIDIsNotConfigured(_ clientID: String?) {
        #expect(GoogleOAuth(clientID: clientID) == nil)
    }

    @Test func redirectUsesTheReversedClientID() {
        #expect(oauth.callbackScheme == G.callbackScheme)
        #expect(oauth.redirectURI == G.callbackScheme + ":/oauthredirect")
    }

    // MARK: PKCE

    @Test func pkceVerifierIsUnreservedAndWithinLengthLimits() {
        var seen: Set<String> = []
        for _ in 0..<50 {
            let pkce = PKCE()
            #expect((43...128).contains(pkce.verifier.count))
            #expect(
                pkce.verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) }
            )
            seen.insert(pkce.verifier)
        }
        #expect(seen.count == 50)
    }

    @Test func pkceChallengeIsS256OfTheVerifier() {
        // RFC 7636, Appendix B.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    // MARK: Authorization URL + callback

    @Test func authorizationURLCarriesPKCEStateAndOnlyThePickerScope() {
        let pkce = PKCE()
        let url = oauth.authorizationURL(pkce: pkce, state: "state-123")
        #expect(url.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth?"))
        let q = query(url)
        #expect(q["client_id"] == G.clientID)
        #expect(q["redirect_uri"] == G.callbackScheme + ":/oauthredirect")
        #expect(q["response_type"] == "code")
        #expect(q["scope"] == "https://www.googleapis.com/auth/photospicker.mediaitems.readonly")
        #expect(q["code_challenge"] == pkce.challenge)
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["state"] == "state-123")
        #expect(q["client_secret"] == nil)
        #expect(!url.absoluteString.contains(pkce.verifier))
    }

    @Test func callbackWithMatchingStateYieldsTheCode() throws {
        let url = URL(string: G.callbackScheme + ":/oauthredirect?state=s-1&code=4/abc")!
        #expect(try oauth.authorizationCode(from: url, expectedState: "s-1") == "4/abc")
    }

    @Test func callbackStateMismatchIsRejected() {
        for callback in [
            G.callbackScheme + ":/oauthredirect?state=other&code=4/abc",
            G.callbackScheme + ":/oauthredirect?code=4/abc",
            G.callbackScheme + ":/oauthredirect?state=s-10&code=4/abc",
            G.callbackScheme + ":/oauthredirect?state=other&error=access_denied",
        ] {
            #expect(throws: GoogleOAuthError.stateMismatch) {
                try oauth.authorizationCode(from: URL(string: callback)!, expectedState: "s-1")
            }
        }
    }

    @Test func deniedConsentAndForeignRedirectsAreRejected() {
        #expect(throws: GoogleOAuthError.accessDenied) {
            try oauth.authorizationCode(
                from: URL(string: G.callbackScheme + ":/oauthredirect?state=s&error=access_denied")!,
                expectedState: "s")
        }
        #expect(throws: GoogleOAuthError.malformedCallback) {
            try oauth.authorizationCode(
                from: URL(string: "com.evil.app:/oauthredirect?state=s&code=c")!, expectedState: "s")
        }
        #expect(throws: GoogleOAuthError.malformedCallback) {
            try oauth.authorizationCode(
                from: URL(string: G.callbackScheme + ":/oauthredirect?state=s")!, expectedState: "s")
        }
    }

    // MARK: Token endpoint requests

    @Test func codeExchangeSendsVerifierAndNoClientSecret() {
        let pkce = PKCE()
        let request = oauth.tokenExchangeRequest(code: "4/a+b", pkce: pkce)
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let fields = G.formFields(request)
        #expect(
            fields == [
                "client_id": G.clientID, "code": "4/a+b", "code_verifier": pkce.verifier,
                "grant_type": "authorization_code", "redirect_uri": G.callbackScheme + ":/oauthredirect",
            ])
    }

    @Test func refreshAndRevokeRequests() {
        let refresh = oauth.refreshRequest(refreshToken: "1//r")
        #expect(refresh.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(
            G.formFields(refresh) == [
                "client_id": G.clientID, "grant_type": "refresh_token", "refresh_token": "1//r",
            ])
        let revoke = oauth.revokeRequest(token: "1//r")
        #expect(revoke.url?.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(revoke.httpMethod == "POST")
        #expect(G.formFields(revoke) == ["token": "1//r"])
    }

    // MARK: Token responses

    @Test func tokenResponseIsParsedWithExpiry() throws {
        let data = G.json([
            "access_token": "a", "expires_in": 3599, "refresh_token": "r", "scope": GoogleOAuth.scope,
            "token_type": "Bearer",
        ])
        let tokens = try oauth.parseTokenResponse(data: data, statusCode: 200, now: G.now)
        #expect(
            tokens
                == GoogleTokens(
                    accessToken: "a", expiresAt: G.now.addingTimeInterval(3599), refreshToken: "r"))
    }

    @Test func refreshResponseWithoutRefreshTokenKeepsThePreviousOne() throws {
        let data = G.json(["access_token": "a2", "expires_in": 3599, "token_type": "Bearer"])
        let tokens = try oauth.parseTokenResponse(
            data: data, statusCode: 200, now: G.now, previous: G.validTokens())
        #expect(tokens.refreshToken == "refresh-0")
        #expect(tokens.accessToken == "a2")
    }

    @Test func tokenErrorsAreClassified() {
        #expect(throws: GoogleOAuthError.invalidGrant) {
            try oauth.parseTokenResponse(
                data: G.json([
                    "error": "invalid_grant", "error_description": "Token has been expired or revoked.",
                ]),
                statusCode: 400, now: G.now)
        }
        #expect(throws: GoogleOAuthError.tokenEndpointFailed) {
            try oauth.parseTokenResponse(
                data: G.json(["error": "invalid_client"]), statusCode: 401, now: G.now)
        }
        #expect(throws: GoogleOAuthError.malformedTokenResponse) {
            try oauth.parseTokenResponse(data: G.json(["access_token": "a"]), statusCode: 200, now: G.now)
        }
        // Granular consent: the Photos Picker permission was unticked.
        #expect(throws: GoogleOAuthError.accessDenied) {
            try oauth.parseTokenResponse(
                data: G.json(["access_token": "a", "expires_in": 10, "refresh_token": "r", "scope": "openid"]
                ),
                statusCode: 200, now: G.now)
        }
        #expect(GoogleOAuthError.invalidGrant.importError == .reauthenticationRequired)
        #expect(GoogleOAuthError.accessDenied.importError == .cancelled)
        #expect(GoogleOAuthError.stateMismatch.importError == .network)
    }

    // MARK: Token store

    @Test func tokenStoreRoundTripsThroughTheKeyStoreOnly() throws {
        let keys = InMemoryKeyStore()
        let store = KeychainGoogleTokenStore(keyStore: keys)
        #expect(try store.load() == nil)
        try store.save(G.validTokens())
        #expect(try store.load() == G.validTokens())
        #expect(try keys.read(account: KeychainGoogleTokenStore.account) != nil)
        try store.delete()
        #expect(try store.load() == nil)
        #expect(keys.isEmpty)
        try store.delete()  // deleting nothing is fine
    }

    @Test func corruptTokenItemIsDeletedAndTreatedAsSignedOut() throws {
        let keys = InMemoryKeyStore()
        try keys.write(Data("garbage".utf8), account: KeychainGoogleTokenStore.account)
        #expect(try KeychainGoogleTokenStore(keyStore: keys).load() == nil)
        #expect(keys.isEmpty)
    }

    @Test func liveTokenStoreUsesTheThisDeviceOnlyKeychain() {
        let keychain = KeychainGoogleTokenStore.defaultKeyStore
        #expect(keychain.useDataProtectionKeychain)
        #expect(keychain.service == "study.paradigm.halo.google")
    }
}

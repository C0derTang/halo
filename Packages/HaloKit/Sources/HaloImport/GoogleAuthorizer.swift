import Foundation
import HaloCore

/// Owns the Google grant: interactive sign-in (PKCE), access-token refresh and sign-out.
/// The Keychain (`GoogleTokenStoring`) is the only place tokens are kept (invariant 5); this actor
/// re-reads it on every use, so a sign-out or erase takes effect immediately.
actor GoogleAuthorizer: GoogleAccessTokenProviding {
    let oauth: GoogleOAuth
    private let transport: any HTTPTransport
    private let tokenStore: any GoogleTokenStoring
    private let presenter: any GoogleBrowserPresenting
    private let now: @Sendable () -> Date

    init(
        oauth: GoogleOAuth, transport: any HTTPTransport, tokenStore: any GoogleTokenStoring,
        presenter: any GoogleBrowserPresenting, now: @escaping @Sendable () -> Date
    ) {
        self.oauth = oauth
        self.transport = transport
        self.tokenStore = tokenStore
        self.presenter = presenter
        self.now = now
    }

    func hasTokens() -> Bool {
        ((try? tokenStore.load()) ?? nil) != nil
    }

    func signInIfNeeded() async throws {
        if try tokenStore.load() == nil { try await signIn() }
    }

    /// Browser sign-in, `state` check, code exchange; saves the tokens unless cancelled meanwhile.
    func signIn() async throws {
        let pkce = PKCE()
        let state = PKCE.randomURLSafe(byteCount: 32)
        let callback: URL
        do {
            callback = try await presenter.authenticate(
                url: oauth.authorizationURL(pkce: pkce, state: state), callbackScheme: oauth.callbackScheme)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        let code: String
        do throws(GoogleOAuthError) {
            code = try oauth.authorizationCode(from: callback, expectedState: state)
        } catch {
            throw error.importError
        }
        let (data, response) = try await send(oauth.tokenExchangeRequest(code: code, pkce: pkce))
        let tokens: GoogleTokens
        do throws(GoogleOAuthError) {
            tokens = try oauth.parseTokenResponse(data: data, statusCode: response.statusCode, now: now())
        } catch {
            throw error.importError
        }
        try Task.checkCancellation()
        try tokenStore.save(tokens)
    }

    /// A valid access token; refreshes first when expired (or `forceRefresh`). Throws
    /// `.reauthenticationRequired` when there is no grant, and deletes the tokens on `invalid_grant`.
    func accessToken(forceRefresh: Bool) async throws -> String {
        guard let tokens = try tokenStore.load() else {
            throw GooglePhotosImportError.reauthenticationRequired
        }
        if !forceRefresh, !tokens.isExpired(at: now()) { return tokens.accessToken }
        return try await refresh(tokens).accessToken
    }

    private func refresh(_ tokens: GoogleTokens) async throws -> GoogleTokens {
        let (data, response) = try await send(oauth.refreshRequest(refreshToken: tokens.refreshToken))
        let refreshed: GoogleTokens
        do throws(GoogleOAuthError) {
            refreshed = try oauth.parseTokenResponse(
                data: data, statusCode: response.statusCode, now: now(), previous: tokens)
        } catch .invalidGrant {
            // Revoked, or the 7-day refresh-token limit of a Testing-mode consent screen.
            try? tokenStore.delete()
            throw GooglePhotosImportError.reauthenticationRequired
        } catch {
            throw error.importError
        }
        try Task.checkCancellation()
        // Signed out meanwhile: do not resurrect the grant.
        guard try tokenStore.load() != nil else { throw GooglePhotosImportError.reauthenticationRequired }
        try tokenStore.save(refreshed)
        return refreshed
    }

    /// Deletes the tokens, then revokes the grant at Google (best effort; never throws).
    func signOut() async {
        let tokens = (try? tokenStore.load()) ?? nil
        try? tokenStore.delete()
        guard let tokens else { return }
        _ = try? await transport.send(oauth.revokeRequest(token: tokens.refreshToken))
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            throw GooglePhotosPickerClient.mapTransportError(error)
        }
    }
}

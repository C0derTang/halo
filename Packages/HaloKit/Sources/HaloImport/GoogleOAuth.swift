import CryptoKit
import Foundation
import HaloCore

// Google OAuth 2.0 for an iOS client: authorization code + PKCE (S256), no client secret.
// Pure request building and response parsing; the browser step and HTTP are injected.
//
// Invariant 5: the client ID is configuration (never hard-coded here) and is not a secret; tokens
// are handed only to `GoogleTokenStoring` (Keychain). Nothing in this file logs.

/// OAuth tokens for the Photos Picker scope. SECRET: stored only by `GoogleTokenStoring`.
public struct GoogleTokens: Codable, Hashable, Sendable {
    public var accessToken: String
    /// When `accessToken` stops working (from `expires_in`).
    public var expiresAt: Date
    public var refreshToken: String

    public init(accessToken: String, expiresAt: Date, refreshToken: String) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
    }

    /// True when the access token is expired or expires within `leeway`.
    public func isExpired(at now: Date, leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }
}

/// A PKCE verifier and its S256 challenge (RFC 7636).
public struct PKCE: Hashable, Sendable {
    /// 43...128 characters of `[A-Za-z0-9-._~]`.
    public let verifier: String
    /// `BASE64URL(SHA256(ASCII(verifier)))`, no padding.
    public let challenge: String

    /// A fresh verifier from 32 random bytes (43 base64url characters).
    public init() {
        self.init(verifier: Self.randomURLSafe(byteCount: 32))
    }

    public init(verifier: String) {
        self.verifier = verifier
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomURLSafe(byteCount: Int) -> String {
        var rng = SystemRandomNumberGenerator()  // cryptographically secure on Apple platforms
        return base64URL(Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &rng) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Failures inside the OAuth flow. Carry no response bodies, codes or tokens.
enum GoogleOAuthError: Error, Equatable, Sendable {
    /// The redirect's `state` did not match the one we sent (possible CSRF / injected redirect).
    case stateMismatch
    /// The redirect carried neither a code nor a recognizable error, or a different redirect URI.
    case malformedCallback
    /// The user declined consent (`error=access_denied`) or did not grant the Photos Picker scope.
    case accessDenied
    /// `invalid_grant`: the refresh token is revoked or expired.
    case invalidGrant
    /// Any other non-success token endpoint response.
    case tokenEndpointFailed
    /// A success response without the fields we need.
    case malformedTokenResponse

    /// The seam-level error the importer surfaces.
    var importError: GooglePhotosImportError {
        switch self {
        case .accessDenied: .cancelled
        case .invalidGrant: .reauthenticationRequired
        case .stateMismatch, .malformedCallback, .tokenEndpointFailed, .malformedTokenResponse: .network
        }
    }
}

/// Request builders and response parsers for Google's OAuth endpoints.
public struct GoogleOAuth: Sendable {
    public static let scope = "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let googleClientIDSuffix = ".apps.googleusercontent.com"

    public let clientID: String

    /// nil when `clientID` is nil, blank, or not an iOS client ID (`*.apps.googleusercontent.com`).
    public init?(clientID: String?) {
        guard let trimmed = clientID?.trimmingCharacters(in: .whitespacesAndNewlines),
            trimmed.hasSuffix(Self.googleClientIDSuffix), trimmed.count > Self.googleClientIDSuffix.count,
            trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        else { return nil }
        self.clientID = trimmed
    }

    /// The reversed client ID, e.g. `com.googleusercontent.apps.1234-abc`: the redirect scheme
    /// Google assigns an iOS client.
    public var callbackScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    public var redirectURI: String { callbackScheme + ":/oauthredirect" }

    /// The consent page URL. `state` must be random per attempt and checked on the way back.
    public func authorizationURL(pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// Extracts the authorization code from the redirect, after checking it is our redirect URI and
    /// carries exactly the `state` we sent.
    func authorizationCode(from callback: URL, expectedState: String) throws(GoogleOAuthError) -> String {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == callbackScheme.lowercased()
        else { throw .malformedCallback }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        // State first: an unsolicited redirect is rejected whatever else it carries.
        guard let state = value("state"), Self.constantTimeEqual(state, expectedState) else {
            throw .stateMismatch
        }
        if let error = value("error") {
            throw error == "access_denied" ? .accessDenied : .malformedCallback
        }
        guard let code = value("code"), !code.isEmpty else { throw .malformedCallback }
        return code
    }

    /// `authorization_code` exchange (no client secret for an iOS client).
    func tokenExchangeRequest(code: String, pkce: PKCE) -> URLRequest {
        formRequest(
            Self.tokenEndpoint,
            [
                ("client_id", clientID),
                ("code", code),
                ("code_verifier", pkce.verifier),
                ("grant_type", "authorization_code"),
                ("redirect_uri", redirectURI),
            ])
    }

    func refreshRequest(refreshToken: String) -> URLRequest {
        formRequest(
            Self.tokenEndpoint,
            [("client_id", clientID), ("grant_type", "refresh_token"), ("refresh_token", refreshToken)])
    }

    /// Revoking the refresh token also revokes its access tokens.
    func revokeRequest(token: String) -> URLRequest {
        formRequest(Self.revokeEndpoint, [("token", token)])
    }

    /// Parses a token endpoint response. `previous` supplies the refresh token when a refresh
    /// response omits it.
    func parseTokenResponse(
        data: Data, statusCode: Int, now: Date, previous: GoogleTokens? = nil
    ) throws(GoogleOAuthError) -> GoogleTokens {
        guard (200..<300).contains(statusCode) else {
            let error = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw error?.error == "invalid_grant" ? .invalidGrant : .tokenEndpointFailed
        }
        guard let body = try? JSONDecoder().decode(TokenBody.self, from: data),
            !body.accessToken.isEmpty, body.expiresIn > 0
        else { throw .malformedTokenResponse }
        if let tokenType = body.tokenType, tokenType.lowercased() != "bearer" {
            throw .malformedTokenResponse
        }
        // Granular consent: the user can untick the Photos Picker permission.
        if let granted = body.scope, !granted.split(separator: " ").contains(Substring(Self.scope)) {
            throw .accessDenied
        }
        guard let refresh = body.refreshToken ?? previous?.refreshToken, !refresh.isEmpty else {
            throw .malformedTokenResponse
        }
        return GoogleTokens(
            accessToken: body.accessToken, expiresAt: now.addingTimeInterval(TimeInterval(body.expiresIn)),
            refreshToken: refresh)
    }

    // MARK: - Helpers

    private func formRequest(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            fields.map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }.joined(separator: "&").utf8)
        return request
    }

    /// `application/x-www-form-urlencoded` value encoding (unreserved characters only).
    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private struct TokenBody: Decodable {
        var accessToken: String
        var expiresIn: Int
        var refreshToken: String?
        var scope: String?
        var tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
            case tokenType = "token_type"
        }
    }

    private struct ErrorBody: Decodable {
        var error: String?
    }
}

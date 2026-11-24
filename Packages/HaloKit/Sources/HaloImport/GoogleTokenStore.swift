import Foundation
import HaloBridgeKit

/// Where the Google OAuth tokens live. Invariant 5: the production store is the Keychain only
/// (never UserDefaults, files or the bundle). Tests inject an in-memory `KeyStore`.
public protocol GoogleTokenStoring: Sendable {
    func load() throws -> GoogleTokens?
    func save(_ tokens: GoogleTokens) throws
    /// Deleting when nothing is stored is not an error.
    func delete() throws
}

/// `GoogleTokenStoring` over a `KeyStore` (HaloBridgeKit). The default is the data-protection
/// Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, non-synchronizable: tokens are never
/// synced to iCloud, never restored to another device and unreadable while the device is locked.
public struct KeychainGoogleTokenStore: GoogleTokenStoring {
    static let account = "google-photos.oauth-tokens"
    /// Data-protection Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
    public static let defaultKeyStore = KeychainKeyStore(service: "study.paradigm.halo.google")

    private let keyStore: any KeyStore

    public init(keyStore: any KeyStore = KeychainGoogleTokenStore.defaultKeyStore) {
        self.keyStore = keyStore
    }

    /// An unreadable item is deleted and treated as signed out (the next import signs in again).
    public func load() throws -> GoogleTokens? {
        guard let data = try keyStore.read(account: Self.account) else { return nil }
        guard let tokens = try? JSONDecoder().decode(GoogleTokens.self, from: data) else {
            try keyStore.delete(account: Self.account)
            return nil
        }
        return tokens
    }

    public func save(_ tokens: GoogleTokens) throws {
        try keyStore.write(JSONEncoder().encode(tokens), account: Self.account)
    }

    public func delete() throws {
        try keyStore.delete(account: Self.account)
    }
}

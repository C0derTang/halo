import Foundation
import Security

/// Small secret/key storage seam. Production code uses `KeychainKeyStore`; tests inject an
/// in-memory fake so they never touch the real Keychain (invariant 5: keys live only in the
/// Keychain, never in files, defaults or the bundle).
public protocol KeyStore: Sendable {
    /// The stored bytes for `account`, or nil when nothing is stored.
    func read(account: String) throws -> Data?
    /// Stores `data` for `account`, replacing any existing value.
    func write(_ data: Data, account: String) throws
    /// Removes `account`. Removing a missing account is not an error.
    func delete(account: String) throws
}

public enum KeyStoreError: Error, Equatable, CustomStringConvertible {
    case unexpectedStatus(OSStatus)
    /// Stored bytes exist but are not a valid key.
    case corruptItem(account: String)

    public var description: String {
        switch self {
        case .unexpectedStatus(let s):
            let msg = SecCopyErrorMessageString(s, nil).map { $0 as String } ?? "unknown"
            return "Keychain error \(s): \(msg)"
        case .corruptItem(let account): return "Keychain item \(account) is not a valid key."
        }
    }
}

/// Generic-password Keychain storage.
///
/// With `useDataProtectionKeychain` (always the case on iOS) items are stored
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: never synced to iCloud, never migrated to a
/// new device by a backup restore, unreadable while the device is locked.
///
/// The macOS data protection keychain requires a signed binary with a keychain-access-group
/// entitlement, which a SwiftPM command-line tool does not have. `halo-bridge` therefore uses
/// the login keychain (`useDataProtectionKeychain: false`), where the accessibility attribute
/// does not apply; items are still non-synchronizable. The bridge only stores the phone's
/// PUBLIC key there.
public struct KeychainKeyStore: KeyStore {
    public var service: String
    public var useDataProtectionKeychain: Bool

    public init(service: String, useDataProtectionKeychain: Bool = true) {
        self.service = service
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    /// Phone side: holds the pairing private key.
    public static let phone = KeychainKeyStore(service: "study.paradigm.halo.pairing")
    /// Mac side (`halo-bridge`): holds the paired phone's public key.
    public static let bridge = KeychainKeyStore(
        service: "study.paradigm.halo.bridge", useDataProtectionKeychain: false)

    /// Identifies one item. Never contains secret data.
    func itemQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if useDataProtectionKeychain { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// Attributes for a new item (`itemQuery` + protection class + value).
    func addAttributes(account: String, data: Data) -> [String: Any] {
        var q = itemQuery(account: account)
        if useDataProtectionKeychain {
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        q[kSecValueData as String] = data
        return q
    }

    public func read(account: String) throws -> Data? {
        var q = itemQuery(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else { throw KeyStoreError.corruptItem(account: account) }
            return data
        case errSecItemNotFound: return nil
        default: throw KeyStoreError.unexpectedStatus(status)
        }
    }

    /// Attributes changed when overwriting an existing item: the value and, where it applies,
    /// the protection class (so an older item is upgraded to the current one).
    func updateAttributes(data: Data) -> [String: Any] {
        var u: [String: Any] = [kSecValueData as String: data]
        if useDataProtectionKeychain {
            u[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return u
    }

    public func write(_ data: Data, account: String) throws {
        // Add first; update in place if it exists. No delete-then-add window in which a crash
        // or a concurrent reader would find the key missing.
        var status = SecItemAdd(addAttributes(account: account, data: data) as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(
                itemQuery(account: account) as CFDictionary, updateAttributes(data: data) as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeyStoreError.unexpectedStatus(status) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(itemQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.unexpectedStatus(status)
        }
    }
}

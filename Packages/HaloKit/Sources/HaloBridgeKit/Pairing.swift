import CryptoKit
import Foundation

public enum PairingError: Error, Equatable, CustomStringConvertible {
    /// Not base64url, or the wrong length for its version.
    case malformedPayload
    case unsupportedVersion(UInt8)
    /// The key id does not match the public key (corrupted or mistyped payload).
    case keyIDMismatch
    /// `halo-bridge` has no paired phone yet.
    case notPaired

    public var description: String {
        switch self {
        case .malformedPayload: return "Pairing payload is malformed."
        case .unsupportedVersion(let v):
            return
                "Pairing payload version \(v) is not supported (expected \(PairingPayload.currentVersion))."
        case .keyIDMismatch: return "Pairing payload is corrupted (key id does not match the key)."
        case .notPaired:
            return "No phone paired. Show the pairing QR code in Halo, then run: halo-bridge pair <payload>"
        }
    }
}

/// Short public identifier of a pairing key: the first 8 bytes of SHA-256(raw public key).
/// Lets the phone reject an envelope sealed to a different key before attempting decryption.
public struct PairingKeyID: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 8
    public let bytes: Data

    public init(publicKey: Curve25519.KeyAgreement.PublicKey) {
        bytes = Data(SHA256.hash(data: publicKey.rawRepresentation).prefix(Self.byteCount))
    }

    init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = Data(bytes)
    }

    public var description: String { bytes.map { String(format: "%02x", $0) }.joined() }
}

/// What the phone shows as a QR code and the Mac consumes with `halo-bridge pair <payload>`.
///
/// Wire format (v1), base64url without padding:
/// `[version: 1 byte = 1][X25519 public key: 32 bytes][key id: 8 bytes]` = 41 bytes, 55 chars.
/// The key id doubles as a checksum: it must equal the id derived from the key.
public struct PairingPayload: Hashable, Sendable {
    public static let currentVersion: UInt8 = 1
    static let keyByteCount = 32

    public let publicKey: Curve25519.KeyAgreement.PublicKey
    public let keyID: PairingKeyID

    public init(publicKey: Curve25519.KeyAgreement.PublicKey) {
        self.publicKey = publicKey
        keyID = PairingKeyID(publicKey: publicKey)
    }

    public var publicKeyData: Data { publicKey.rawRepresentation }

    public static func == (a: PairingPayload, b: PairingPayload) -> Bool {
        a.publicKeyData == b.publicKeyData
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(publicKeyData) }

    public var encoded: String {
        var bytes = Data([Self.currentVersion])
        bytes.append(publicKeyData)
        bytes.append(keyID.bytes)
        return Base64URL.encode(bytes)
    }

    public init(encoded: String) throws(PairingError) {
        let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bytes = Base64URL.decode(trimmed), let version = bytes.first else {
            throw .malformedPayload
        }
        guard version == Self.currentVersion else { throw .unsupportedVersion(version) }
        guard bytes.count == 1 + Self.keyByteCount + PairingKeyID.byteCount else {
            throw .malformedPayload
        }
        let keyData = bytes.dropFirst().prefix(Self.keyByteCount)
        guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(keyData)) else {
            throw .malformedPayload
        }
        let derived = PairingKeyID(publicKey: key)
        guard PairingKeyID(bytes: Data(bytes.suffix(PairingKeyID.byteCount))) == derived else {
            throw .keyIDMismatch
        }
        publicKey = key
        keyID = derived
    }
}

/// Phone side: the X25519 key-agreement key digests are sealed to.
///
/// The private key exists only in the Keychain (`KeychainKeyStore.phone`, stored
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) and in memory. It is deliberately not public
/// API: callers get the public `payload` and open envelopes through `DigestEnvelope.open(with:)`.
public struct PairingKey: Sendable {
    public static let keychainAccount = "pairing-private-key"

    let privateKey: Curve25519.KeyAgreement.PrivateKey
    public let payload: PairingPayload

    init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
        payload = PairingPayload(publicKey: privateKey.publicKey)
    }

    public var keyID: PairingKeyID { payload.keyID }
    /// The string to render as a QR code.
    public var pairingPayload: String { payload.encoded }

    /// The stored key, or nil when none exists. Throws if the stored item is corrupt.
    public static func load(from store: any KeyStore) throws -> PairingKey? {
        guard let raw = try store.read(account: keychainAccount) else { return nil }
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
            throw KeyStoreError.corruptItem(account: keychainAccount)
        }
        return PairingKey(privateKey: key)
    }

    /// The stored key, creating and storing a new one on first use.
    public static func loadOrCreate(in store: any KeyStore) throws -> PairingKey {
        if let existing = try load(from: store) { return existing }
        return try rotate(in: store)
    }

    /// Replaces the stored key with a fresh one. Digests sealed to the old key become unreadable,
    /// so the Mac has to be paired again.
    @discardableResult
    public static func rotate(in store: any KeyStore) throws -> PairingKey {
        let key = PairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey())
        try store.write(key.privateKey.rawRepresentation, account: keychainAccount)
        return key
    }

    /// Forgets the pairing key.
    public static func delete(from store: any KeyStore) throws {
        try store.delete(account: keychainAccount)
    }
}

/// Mac side: the paired phone's public key, kept in `KeychainKeyStore.bridge`.
public enum PairedPhone {
    public static let keychainAccount = "paired-phone-public-key"

    public static func save(_ payload: PairingPayload, in store: any KeyStore) throws {
        try store.write(Data(payload.encoded.utf8), account: keychainAccount)
    }

    public static func load(from store: any KeyStore) throws -> PairingPayload? {
        guard let raw = try store.read(account: keychainAccount) else { return nil }
        guard let payload = try? PairingPayload(encoded: String(decoding: raw, as: UTF8.self)) else {
            throw KeyStoreError.corruptItem(account: keychainAccount)
        }
        return payload
    }

    public static func delete(from store: any KeyStore) throws {
        try store.delete(account: keychainAccount)
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict: only the base64url alphabet, no padding.
    static func decode(_ string: String) -> Data? {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !string.isEmpty, string.allSatisfy(allowed.contains), string.count % 4 != 1 else {
            return nil
        }
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }
}

import CryptoKit
import Foundation
import HaloCore

public enum DigestEnvelopeError: Error, Equatable, CustomStringConvertible {
    /// Not a `.halodigest` file, or truncated.
    case malformed
    case unsupportedVersion(UInt8)
    /// Sealed to a different pairing key (the Mac is paired with another phone/key).
    case wrongKey(expected: PairingKeyID, found: PairingKeyID)
    /// HPKE authentication failed: the header or ciphertext was modified, or the key is wrong.
    case authenticationFailed
    /// Decrypted fine but is not a valid digest.
    case invalidDigest
    /// The normalizer region is not 1-8 uppercase ASCII letters/digits.
    case invalidRegion

    public var description: String {
        switch self {
        case .malformed: return "Not a valid .halodigest file."
        case .unsupportedVersion(let v): return "Unsupported .halodigest version \(v)."
        case .wrongKey(let expected, let found):
            return "Digest was sealed to key \(found), this device's key is \(expected). Pair the Mac again."
        case .authenticationFailed: return "Digest failed authentication (tampered or wrong key)."
        case .invalidDigest: return "Digest content is invalid."
        case .invalidRegion: return "Digest normalizer region is invalid."
        }
    }
}

/// JSON coding for `InteractionDigest`, shared by the plaintext debug output and the envelope.
public enum DigestCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// A successfully opened envelope: the digest plus the region the bridge normalized phone
/// handles with, so the app can normalize its contacts the same way.
public struct OpenedDigest: Hashable, Sendable {
    public var digest: InteractionDigest
    /// ISO region (e.g. "US", "GB") the Mac passed to `HandleNormalizer(region:)`. Authenticated.
    public var normalizerRegion: String
}

/// An `InteractionDigest` sealed to the phone's pairing key: the `.halodigest` file format.
///
/// Crypto: RFC 9180 HPKE, base mode, ciphersuite `Curve25519_SHA256_ChachaPoly`
/// (DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305). X25519 was chosen because the
/// pairing key is a `Curve25519.KeyAgreement` key (compact 32-byte public key for the QR code);
/// ChaCha20-Poly1305 is constant-time in software on every device. The version byte pins the
/// ciphersuite, so it is not repeated in the file.
///
/// Layout (v1):
/// ```
/// magic      8 bytes  "HALODGST"
/// version    1 byte   1
/// keyID      8 bytes  PairingKeyID of the recipient
/// regionLen  1 byte   n, 1...8
/// region     n bytes  ASCII normalizer region (HandleNormalizer(region:)), e.g. "US"
/// enc       32 bytes  HPKE encapsulated key
/// ciphertext   rest   HPKE seal of the digest JSON (includes the 16-byte tag)
/// ```
/// The whole header is the AEAD associated data, so changing any header byte (including the
/// region) makes `open` fail. `open` either returns the complete digest or throws; it never
/// returns partial data.
public struct DigestEnvelope: Hashable, Sendable {
    public static let fileExtension = "halodigest"
    public static let currentVersion: UInt8 = 1
    public static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    static let magic = Data("HALODGST".utf8)
    static let encapsulatedKeyByteCount = 32
    static let maxRegionByteCount = 8
    static let tagByteCount = 16
    /// HPKE `info`: domain separation so these keys are never valid for another protocol.
    static let info = Data("halo-bridge InteractionDigest v1".utf8)

    public let version: UInt8
    public let keyID: PairingKeyID
    /// Not authenticated until `open` succeeds; read `OpenedDigest.normalizerRegion` instead.
    public let normalizerRegion: String
    public let encapsulatedKey: Data
    public let ciphertext: Data

    /// Seals `digest` to the paired phone's public key. `normalizerRegion` is the region the
    /// digest's handles were normalized with; it is authenticated as part of the header.
    public static func seal(
        _ digest: InteractionDigest, normalizerRegion: String, to recipient: PairingPayload
    ) throws -> DigestEnvelope {
        let region = normalizerRegion.uppercased()
        guard isValidRegion(region) else { throw DigestEnvelopeError.invalidRegion }
        let plaintext = try DigestCoding.encoder().encode(digest)
        var sender = try HPKE.Sender(
            recipientKey: recipient.publicKey, ciphersuite: ciphersuite, info: info)
        let header = Self.header(
            version: currentVersion, keyID: recipient.keyID, region: region,
            encapsulatedKey: sender.encapsulatedKey)
        let ciphertext = try sender.seal(plaintext, authenticating: header)
        return DigestEnvelope(
            version: currentVersion, keyID: recipient.keyID, normalizerRegion: region,
            encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext)
    }

    init(
        version: UInt8, keyID: PairingKeyID, normalizerRegion: String, encapsulatedKey: Data,
        ciphertext: Data
    ) {
        self.version = version
        self.keyID = keyID
        self.normalizerRegion = normalizerRegion
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
    }

    static func isValidRegion(_ region: String) -> Bool {
        (1...maxRegionByteCount).contains(region.utf8.count)
            && region.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }
    }

    static func header(version: UInt8, keyID: PairingKeyID, region: String, encapsulatedKey: Data) -> Data {
        var d = magic
        d.append(version)
        d.append(keyID.bytes)
        d.append(UInt8(region.utf8.count))
        d.append(contentsOf: Array(region.utf8))
        d.append(encapsulatedKey)
        return d
    }

    var header: Data {
        Self.header(
            version: version, keyID: keyID, region: normalizerRegion, encapsulatedKey: encapsulatedKey)
    }

    /// The bytes written to a `.halodigest` file.
    public var serialized: Data { header + ciphertext }

    /// Parses a `.halodigest` file. Structural checks only; authenticity is checked by `open`.
    public init(serialized data: Data) throws(DigestEnvelopeError) {
        let bytes = Data(data)  // rebase indices to 0
        guard bytes.count > Self.magic.count, bytes.prefix(Self.magic.count) == Self.magic else {
            throw .malformed
        }
        let version = bytes[Self.magic.count]
        guard version == Self.currentVersion else { throw .unsupportedVersion(version) }
        var offset = Self.magic.count + 1
        func take(_ n: Int) throws(DigestEnvelopeError) -> Data {
            guard bytes.count - offset >= n else { throw .malformed }
            defer { offset += n }
            return Data(bytes[offset..<offset + n])
        }
        guard let keyID = PairingKeyID(bytes: try take(PairingKeyID.byteCount)) else { throw .malformed }
        let regionLength = Int(try take(1)[0])
        let region = String(decoding: try take(regionLength), as: UTF8.self)
        guard Self.isValidRegion(region) else { throw .invalidRegion }
        let enc = try take(Self.encapsulatedKeyByteCount)
        guard bytes.count - offset >= Self.tagByteCount else { throw .malformed }
        self.init(
            version: version, keyID: keyID, normalizerRegion: region, encapsulatedKey: enc,
            ciphertext: Data(bytes[offset...]))
    }

    /// Decrypts and decodes the digest with the phone's pairing key.
    public func open(with key: PairingKey) throws(DigestEnvelopeError) -> OpenedDigest {
        guard version == Self.currentVersion else { throw .unsupportedVersion(version) }
        guard keyID == key.keyID else { throw .wrongKey(expected: key.keyID, found: keyID) }
        let plaintext: Data
        do {
            var recipient = try HPKE.Recipient(
                privateKey: key.privateKey, ciphersuite: Self.ciphersuite, info: Self.info,
                encapsulatedKey: encapsulatedKey)
            plaintext = try recipient.open(ciphertext, authenticating: header)
        } catch {
            throw .authenticationFailed
        }
        let digest: InteractionDigest
        do {
            digest = try DigestCoding.decoder().decode(InteractionDigest.self, from: plaintext)
        } catch {
            throw .invalidDigest
        }
        // The region is trustworthy only now: it was part of the authenticated header.
        return OpenedDigest(digest: digest, normalizerRegion: normalizerRegion)
    }

    /// Convenience: parse + open a `.halodigest` file's bytes.
    public static func open(_ data: Data, with key: PairingKey) throws(DigestEnvelopeError) -> OpenedDigest {
        try DigestEnvelope(serialized: data).open(with: key)
    }
}

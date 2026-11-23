import CryptoKit
import Foundation
import HaloCore
import Testing

@testable import HaloBridgeKit

@Suite struct DigestEnvelopeTests {
    let phone = PairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey())

    static let digest = InteractionDigest(
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        entries: [
            .init(
                handle: "+14155550132", lastMessageAt: Date(timeIntervalSince1970: 1_799_990_000),
                lastFromMeAt: Date(timeIntervalSince1970: 1_799_980_000),
                lastFromThemAt: Date(timeIntervalSince1970: 1_799_990_000), messagesLast30Days: 4,
                messagesAllTime: 40, awaitingMyReply: true),
            .init(
                handle: "bob@example.com", lastMessageAt: nil, lastFromMeAt: nil, lastFromThemAt: nil,
                messagesLast30Days: 0, messagesAllTime: 0, awaitingMyReply: false),
        ])

    func sealed(region: String = "US") throws -> Data {
        try DigestEnvelope.seal(Self.digest, normalizerRegion: region, to: phone.payload).serialized
    }

    @Test func sealOpenRoundTrip() throws {
        let data = try sealed(region: "gb")
        let opened = try DigestEnvelope.open(data, with: phone)
        #expect(opened.digest == Self.digest)
        #expect(opened.normalizerRegion == "GB")
        let envelope = try DigestEnvelope(serialized: data)
        #expect(envelope.version == DigestEnvelope.currentVersion)
        #expect(envelope.keyID == phone.keyID)
        #expect(envelope.serialized == data)
    }

    @Test func ciphertextHidesContent() throws {
        let text = String(decoding: try sealed(), as: UTF8.self)
        #expect(!text.contains("bob@example.com"))
        #expect(!text.contains("4155550132"))
    }

    @Test func freshEncapsulationPerSeal() throws {
        #expect(try sealed() != sealed())
    }

    @Test func wrongKeyIsRejected() throws {
        let other = PairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey())
        #expect(throws: DigestEnvelopeError.wrongKey(expected: other.keyID, found: phone.keyID)) {
            _ = try DigestEnvelope.open(try sealed(), with: other)
        }
    }

    @Test func forgedKeyIDStillFailsAuthentication() throws {
        // Relabel the envelope with the other key's id: decryption with that key must fail.
        let other = PairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey())
        var data = try sealed()
        let start = DigestEnvelope.magic.count + 1
        data.replaceSubrange(start..<start + PairingKeyID.byteCount, with: other.keyID.bytes)
        #expect(throws: DigestEnvelopeError.authenticationFailed) {
            _ = try DigestEnvelope.open(data, with: other)
        }
    }

    @Test func tamperedCiphertextFails() throws {
        let data = try sealed()
        let headerCount = try DigestEnvelope(serialized: data).header.count
        for index in [headerCount, headerCount + 7, data.count / 2, data.count - 1] {
            var tampered = data
            tampered[index] ^= 0x01
            #expect(throws: DigestEnvelopeError.authenticationFailed) {
                _ = try DigestEnvelope.open(tampered, with: phone)
            }
        }
        // Truncation and extension also fail closed.
        #expect(throws: DigestEnvelopeError.authenticationFailed) {
            _ = try DigestEnvelope.open(data.dropLast(), with: phone)
        }
        #expect(throws: DigestEnvelopeError.authenticationFailed) {
            _ = try DigestEnvelope.open(data + Data([0]), with: phone)
        }
    }

    @Test func everyTamperedHeaderByteFails() throws {
        let data = try sealed()
        let headerCount = try DigestEnvelope(serialized: data).header.count
        for index in 0..<headerCount {
            var tampered = data
            tampered[index] ^= 0x01
            // Each flip must surface as an error; never a (partial) digest.
            #expect(throws: DigestEnvelopeError.self, "header byte \(index)") {
                _ = try DigestEnvelope.open(tampered, with: phone)
            }
        }
    }

    @Test func regionIsAuthenticated() throws {
        var data = try sealed(region: "US")
        let regionStart = DigestEnvelope.magic.count + 1 + PairingKeyID.byteCount + 1
        // "US" -> "GB": still a valid region, so only HPKE authentication can catch it.
        data.replaceSubrange(regionStart..<regionStart + 2, with: Data("GB".utf8))
        #expect(try DigestEnvelope(serialized: data).normalizerRegion == "GB")
        #expect(throws: DigestEnvelopeError.authenticationFailed) {
            _ = try DigestEnvelope.open(data, with: phone)
        }
    }

    @Test func unsupportedVersion() throws {
        var data = try sealed()
        data[DigestEnvelope.magic.count] = 2
        #expect(throws: DigestEnvelopeError.unsupportedVersion(2)) {
            _ = try DigestEnvelope.open(data, with: phone)
        }
    }

    @Test func malformedInput() throws {
        let data = try sealed()
        #expect(throws: DigestEnvelopeError.malformed) { _ = try DigestEnvelope(serialized: Data()) }
        #expect(throws: DigestEnvelopeError.malformed) {
            _ = try DigestEnvelope(serialized: Data("{\"version\":1}".utf8))
        }
        let headerCount = try DigestEnvelope(serialized: data).header.count
        for length in [9, 20, headerCount, headerCount + DigestEnvelope.tagByteCount - 1] {
            #expect(throws: DigestEnvelopeError.malformed, "length \(length)") {
                _ = try DigestEnvelope(serialized: data.prefix(length))
            }
        }
        // Works on a slice with non-zero start index too.
        let padded = Data([0xFF]) + data
        #expect(try DigestEnvelope.open(padded.dropFirst(), with: phone).digest == Self.digest)
    }

    @Test func invalidRegionRejected() throws {
        for region in ["", "TOOLONGREGION", "U S", "é"] {
            #expect(throws: DigestEnvelopeError.invalidRegion) {
                _ = try DigestEnvelope.seal(Self.digest, normalizerRegion: region, to: phone.payload)
            }
        }
        // A numeric UN M.49 region is fine.
        #expect(try DigestEnvelope.open(sealed(region: "419"), with: phone).normalizerRegion == "419")
    }

    @Test func nonDigestPlaintextIsInvalidDigest() throws {
        // Correctly sealed and authenticated, but not a digest.
        var sender = try HPKE.Sender(
            recipientKey: phone.payload.publicKey, ciphersuite: DigestEnvelope.ciphersuite,
            info: DigestEnvelope.info)
        let header = DigestEnvelope.header(
            version: 1, keyID: phone.keyID, region: "US", encapsulatedKey: sender.encapsulatedKey)
        let ct = try sender.seal(Data("[1,2,3]".utf8), authenticating: header)
        #expect(throws: DigestEnvelopeError.invalidDigest) {
            _ = try DigestEnvelope.open(header + ct, with: phone)
        }
    }
}

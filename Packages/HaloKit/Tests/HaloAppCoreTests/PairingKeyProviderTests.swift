import Foundation
import HaloBridgeKit
import Testing

@testable import HaloAppCore

@Suite struct PairingKeyProviderTests {
    @Test func payloadIsStableAndPublicOnly() throws {
        let keys = MemoryKeyStore()
        let provider = BridgePairingKeyProvider(keyStore: keys)
        let first = try provider.currentPayload()
        #expect(try provider.currentPayload() == first)
        let parsed = try PairingPayload(encoded: first)
        #expect(parsed.encoded == first)
        // The private key is in the store, but never in the payload.
        let raw = try #require(try keys.read(account: PairingKey.keychainAccount))
        #expect(!first.contains(Base64URLProbe.encode(raw)))
    }

    @Test func rotateReplacesKeyAndInvalidatesOldDigests() async throws {
        let keys = MemoryKeyStore()
        let provider = BridgePairingKeyProvider(keyStore: keys)
        let old = try provider.currentPayload()
        let sealed = try DigestEnvelope.seal(
            .init(generatedAt: Date(), entries: []), normalizerRegion: "US",
            to: PairingPayload(encoded: old)
        ).serialized

        let new = try provider.rotate()
        #expect(new != old)
        #expect(try provider.currentPayload() == new)

        let importer = DigestImporter(keyStore: keys, store: RecordingStore())
        await #expect(throws: DigestImportError.wrongKey) { try await importer.importDigest(data: sealed) }
    }
}

private enum Base64URLProbe {
    static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

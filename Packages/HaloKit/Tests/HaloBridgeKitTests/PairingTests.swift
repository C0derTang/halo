import CryptoKit
import Foundation
import Security
import Testing

@testable import HaloBridgeKit

@Suite struct PairingTests {
    @Test func payloadRoundTrip() throws {
        let key = PairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey())
        let encoded = key.pairingPayload
        #expect(encoded.count == 55)  // 41 bytes, base64url, no padding
        #expect(encoded.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        let decoded = try PairingPayload(encoded: encoded)
        #expect(decoded == key.payload)
        #expect(decoded.keyID == key.keyID)
        #expect(decoded.publicKeyData == key.privateKey.publicKey.rawRepresentation)
        // Whitespace from copy/paste is tolerated.
        #expect(try PairingPayload(encoded: "  \(encoded)\n") == decoded)
    }

    @Test func payloadVersionCheck() throws {
        let key = PairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey())
        var bytes = try #require(Base64URL.decode(key.pairingPayload))
        #expect(bytes[0] == PairingPayload.currentVersion)
        bytes[0] = 2
        #expect(throws: PairingError.unsupportedVersion(2)) {
            _ = try PairingPayload(encoded: Base64URL.encode(bytes))
        }
        // A future version with a different length still reports the version, not "malformed".
        #expect(throws: PairingError.unsupportedVersion(9)) {
            _ = try PairingPayload(encoded: Base64URL.encode(Data([9, 1, 2, 3])))
        }
    }

    @Test func payloadRejectsCorruption() throws {
        let key = PairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey())
        var bytes = try #require(Base64URL.decode(key.pairingPayload))
        bytes[5] ^= 0x01  // flip a public-key bit: key id no longer matches
        #expect(throws: PairingError.keyIDMismatch) {
            _ = try PairingPayload(encoded: Base64URL.encode(bytes))
        }
        for bad in ["", "not base64!", "AQ==", "AQ", String(key.pairingPayload.dropLast(4))] {
            #expect(throws: PairingError.malformedPayload) { _ = try PairingPayload(encoded: bad) }
        }
    }

    @Test func keyIDIsStableAndDistinct() {
        let a = PairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey())
        let b = PairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey())
        #expect(a.keyID != b.keyID)
        #expect(a.keyID == PairingKeyID(publicKey: a.privateKey.publicKey))
        #expect(a.keyID.description.count == 16)
    }

    @Test func loadOrCreatePersistsOnlyToKeyStore() throws {
        let store = InMemoryKeyStore()
        #expect(try PairingKey.load(from: store) == nil)
        let created = try PairingKey.loadOrCreate(in: store)
        #expect(store.accounts == [PairingKey.keychainAccount])
        let again = try PairingKey.loadOrCreate(in: store)
        #expect(again.keyID == created.keyID)
        #expect(try PairingKey.load(from: store)?.keyID == created.keyID)
    }

    @Test func rotateAndDelete() throws {
        let store = InMemoryKeyStore()
        let first = try PairingKey.loadOrCreate(in: store)
        let second = try PairingKey.rotate(in: store)
        #expect(first.keyID != second.keyID)
        #expect(try PairingKey.load(from: store)?.keyID == second.keyID)
        try PairingKey.delete(from: store)
        #expect(try PairingKey.load(from: store) == nil)
        try PairingKey.delete(from: store)  // deleting twice is fine
    }

    @Test func corruptStoredKeyThrowsInsteadOfRegenerating() throws {
        let store = InMemoryKeyStore()
        try store.write(Data([1, 2, 3]), account: PairingKey.keychainAccount)
        #expect(throws: KeyStoreError.corruptItem(account: PairingKey.keychainAccount)) {
            _ = try PairingKey.loadOrCreate(in: store)
        }
    }

    @Test func keyStoreFailuresPropagate() {
        let store = InMemoryKeyStore(failure: .unexpectedStatus(errSecInteractionNotAllowed))
        #expect(throws: KeyStoreError.unexpectedStatus(errSecInteractionNotAllowed)) {
            _ = try PairingKey.loadOrCreate(in: store)
        }
    }

    @Test func pairedPhoneRoundTrip() throws {
        let store = InMemoryKeyStore()
        #expect(try PairedPhone.load(from: store) == nil)
        let phone = PairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey()).payload
        try PairedPhone.save(phone, in: store)
        #expect(try PairedPhone.load(from: store) == phone)
        try store.write(Data("garbage".utf8), account: PairedPhone.keychainAccount)
        #expect(throws: KeyStoreError.self) { _ = try PairedPhone.load(from: store) }
        try PairedPhone.delete(from: store)
        #expect(try PairedPhone.load(from: store) == nil)
    }

    // Query construction only; nothing here calls SecItem*.
    @Test func phoneKeychainAttributesAreDeviceOnly() throws {
        let store = KeychainKeyStore.phone
        let attrs = store.addAttributes(account: "a", data: Data([1]))
        #expect(attrs[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(
            attrs[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(attrs[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attrs[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(attrs[kSecAttrService as String] as? String == store.service)
        // The lookup query never carries the secret.
        #expect(store.itemQuery(account: "a")[kSecValueData as String] == nil)
        // Overwrite (SecItemUpdate on errSecDuplicateItem) keeps the protection class current.
        let update = store.updateAttributes(data: Data([2]))
        #expect(update[kSecValueData as String] as? Data == Data([2]))
        #expect(
            update[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(update[kSecAttrAccount as String] == nil)  // identity attributes are not changed
    }

    @Test func bridgeKeychainUsesLoginKeychainNonSynced() {
        let attrs = KeychainKeyStore.bridge.addAttributes(account: "a", data: Data([1]))
        #expect(attrs[kSecUseDataProtectionKeychain as String] == nil)
        #expect(attrs[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(KeychainKeyStore.bridge.service != KeychainKeyStore.phone.service)
    }
}

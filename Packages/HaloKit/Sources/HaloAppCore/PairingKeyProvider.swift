import HaloBridgeKit
import HaloUI

/// Adapts HaloBridgeKit's Keychain-backed `PairingKey` to the UI's `PairingKeyProviding` seam
/// (HaloUI does not depend on HaloBridgeKit). Only the PUBLIC pairing payload crosses this boundary.
public struct BridgePairingKeyProvider: PairingKeyProviding {
    private let keyStore: any KeyStore

    public init(keyStore: any KeyStore = KeychainKeyStore.phone) { self.keyStore = keyStore }

    public func currentPayload() throws -> String {
        try PairingKey.loadOrCreate(in: keyStore).pairingPayload
    }

    public func rotate() throws -> String {
        try PairingKey.rotate(in: keyStore).pairingPayload
    }
}

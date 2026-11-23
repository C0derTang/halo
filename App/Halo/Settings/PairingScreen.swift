import HaloAppCore
import HaloBridgeKit
import HaloUI
import SwiftUI

/// Settings entry for pairing the Mac bridge. Wiring only; logic lives in HaloKit.
struct PairingScreen: View {
    var body: some View {
        PairingView(
            model: PairingModel(
                provider: BridgePairingKeyProvider(keyStore: KeychainKeyStore.phone),
                authenticator: LocalAuthenticator()))
    }
}

import HaloAppCore
import HaloUI
import SwiftUI

/// Settings entry for pairing the Mac bridge. Wiring only; the model uses the environment's
/// Keychain key store, the same one the digest importer opens envelopes with.
struct PairingScreen: View {
    let environment: AppEnvironment

    var body: some View {
        PairingView(model: environment.makePairingModel())
    }
}

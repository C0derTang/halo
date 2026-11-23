import HaloAppCore
import SwiftUI

/// Lens tab: the Live Lens over the environment's one camera and lens model. While the face model
/// loads (or onboarding is up) it shows a placeholder and the camera stays off.
struct LensTab: View {
    let environment: AppEnvironment
    let isEnabled: Bool

    var body: some View {
        if isEnabled, let model = environment.lens, let session = environment.captureSession {
            LensScreen(
                model: model, session: session,
                onAppear: { await environment.lensAppeared() },
                onDisappear: { environment.lensDisappeared() })
        } else {
            ZStack {
                Color.black.ignoresSafeArea()
                if isEnabled {
                    ProgressView().tint(.white)
                }
            }
        }
    }
}

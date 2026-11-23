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
                momentsAllowed: environment.momentsAllowed,
                makeMomentsModel: { environment.makeMomentsModel() },
                onMomentOpened: { environment.momentSheetOpened($0) },
                onMomentClosed: { environment.momentSheetClosed() },
                onAppear: { await environment.lensAppeared() },
                onDisappear: { environment.lensDisappeared() }
            )
            .whisperDevicePrompt(environment)
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

extension View {
    /// Whisper found a Bluetooth output the user has not confirmed: ask once whether it is
    /// personal headphones (car kits look the same). Nothing is spoken until they confirm.
    fileprivate func whisperDevicePrompt(_ environment: AppEnvironment) -> some View {
        // Only while Whisper is on (the environment withdraws the question when it stops).
        let device = environment.whisperDevicePrompt
        return alert(
            "Whisper through \(device?.name ?? "this device")?",
            isPresented: Binding(get: { device != nil }, set: { _ in }),
            presenting: device
        ) { _ in
            Button("They're my headphones") { environment.confirmWhisperDevice(true) }
            Button("Not private", role: .cancel) { environment.confirmWhisperDevice(false) }
        } message: { _ in
            Text(
                "Whisper speaks names only through personal headphones. Confirm this device isn't a car or a speaker."
            )
        }
    }
}

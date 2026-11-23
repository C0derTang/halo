import HaloAppCore
import SwiftUI

/// Lens tab: the Live Lens over the environment's one camera and lens model. While the face model
/// loads (or onboarding is up) it shows a placeholder and the camera stays off.
struct LensTab: View {
    let environment: AppEnvironment
    let isEnabled: Bool

    /// Builds the Moments sheet for the people on screen. nil hides the "Moment" button.
    /// TODO(#70): `{ people in AnyView(MomentsSheet(model: <MomentsModel over people + store>)) }`
    /// once the Moments PR has merged.
    static let momentSheet: (@MainActor (AppEnvironment, [LensRecognizedPerson]) -> AnyView)? = nil

    var body: some View {
        if isEnabled, let model = environment.lens, let session = environment.captureSession {
            LensScreen(
                model: model, session: session,
                recognizedPeople: environment.recognizedPeople,
                momentSheet: Self.momentSheet.map { make in { people in make(environment, people) } },
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
        let device = environment.whisper.pendingDeviceConfirmation
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

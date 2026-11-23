import HaloAppCore
import HaloUI
import SwiftUI

/// App shell: tabs, window-level privacy cover, scene-phase forwarding.
/// Each tab's screen is owned by its issue; the Lens tab is hooked up in wave 4.
struct RootView: View {
    let environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Lens", systemImage: "camera.viewfinder") {
                LensPlaceholder(environment: environment)
            }
            Tab("People", systemImage: "person.2") {
                NavigationStack {
                    EnrollmentTriageView(model: environment.enrollment)
                        .navigationTitle("Who is this?")
                }
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView(model: environment.privacy)
            }
        }
        // Kill switch / late store open: rebuild every screen from fresh state.
        .id(environment.resetGeneration)
        .lifecyclePrivacyCover(environment.appLock)
        .onChange(of: scenePhase, initial: true) { _, phase in
            environment.scenePhaseChanged(to: phase)
        }
    }
}

/// Stand-in until the Live Lens screen is wired (wave 4).
private struct LensPlaceholder: View {
    let environment: AppEnvironment

    var body: some View {
        VStack(spacing: 8) {
            switch environment.recognition {
            case .loading:
                ProgressView()
            case .available:
                Text("Lens — coming in wave 4").foregroundStyle(.secondary)
            case .unavailable:
                Label("Recognition unavailable", systemImage: "exclamationmark.triangle")
                Text("The face model is not installed in this build.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

import HaloAppCore
import HaloUI
import SwiftUI

/// App shell: tabs, first-run onboarding, `.halodigest` opening, window-level privacy cover and
/// scene-phase forwarding. Wiring only; every rule lives in `AppEnvironment` (HaloAppCore).
struct RootView: View {
    let environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsOnboarding: Bool
    @State private var digestMessage: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        _showsOnboarding = State(initialValue: environment.needsOnboarding)
    }

    var body: some View {
        TabView {
            Tab("Lens", systemImage: "camera.viewfinder") {
                // The camera stays off until onboarding has explained it.
                LensTab(environment: environment, isEnabled: !showsOnboarding)
            }
            Tab("People", systemImage: "person.2") {
                // Kill switch / late store open: rebuild from fresh state.
                PeopleTab(environment: environment)
                    .id(environment.resetGeneration)
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsTab(environment: environment, importDigest: importDigest)
                    .id(environment.resetGeneration)
            }
        }
        .fullScreenCover(isPresented: $showsOnboarding) {
            OnboardingView(model: environment.makeOnboardingModel()) { showsOnboarding = false }
        }
        // `.halodigest` opened from Files / AirDrop: the system hands the app its own Inbox copy,
        // which the importer deletes afterwards.
        .onOpenURL { url in importDigest(url) }
        .alert(
            "iMessage digest",
            isPresented: Binding(
                get: { digestMessage != nil },
                set: { if !$0 { digestMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            // Counts or an error only; never digest content.
            Text(digestMessage ?? "")
        }
        // Above sheets, alerts and the onboarding cover (a separate window).
        .lifecyclePrivacyCover(environment.appLock)
        .onChange(of: scenePhase, initial: true) { _, phase in
            environment.scenePhaseChanged(to: phase)
        }
    }

    private func importDigest(_ url: URL) {
        guard url.isFileURL, url.pathExtension.lowercased() == "halodigest" else { return }
        Task {
            await environment.importDigest(url: url)
            digestMessage = environment.digestImport.message
        }
    }
}

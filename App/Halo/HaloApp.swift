import HaloAppCore
import SwiftUI

@main
struct HaloApp: App {
    /// Built once at launch; owns every service (see `AppEnvironment`).
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
                .task { await environment.start() }
        }
    }
}

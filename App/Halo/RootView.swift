import SwiftUI

/// App shell. Master-owned; each tab's screen is owned by its issue.
struct RootView: View {
    var body: some View {
        TabView {
            Tab("Lens", systemImage: "camera.viewfinder") {
                Text("Lens — wave 3").foregroundStyle(.secondary)
            }
            Tab("People", systemImage: "person.2") {
                Text("People — wave 2").foregroundStyle(.secondary)
            }
            Tab("Settings", systemImage: "gearshape") {
                Text("Settings — wave 2").foregroundStyle(.secondary)
            }
        }
    }
}

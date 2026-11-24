import HaloAppCore
import SwiftUI

/// Settings > Google Photos: sign-in state, import, sign out. Wiring only; every rule lives in
/// `GooglePhotosImportModel` / `AppEnvironment`. Shows fixed strings and counts, never Google URLs,
/// tokens or ids.
struct GooglePhotosSection: View {
    let model: GooglePhotosImportModel

    var body: some View {
        Section {
            if model.isConfigured {
                LabeledContent("Google account", value: model.isSignedIn ? "Signed in" : "Not signed in")
                GooglePhotosImportControls(model: model)
                if model.isSignedIn {
                    Button("Sign out of Google", role: .destructive) {
                        Task { await model.signOut() }
                    }
                    .disabled(model.isRunning)
                }
            } else {
                Text(GooglePhotosImportModel.notConfiguredMessage)
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Google Photos")
        } footer: {
            Text(GooglePhotosImportModel.explanation)
        }
        .task { await model.refreshSignInState() }
    }
}

/// "Add from Google Photos", its progress with Cancel, and the last result. Shared by Settings and
/// the People tab.
struct GooglePhotosImportControls: View {
    let model: GooglePhotosImportModel

    var body: some View {
        if model.isRunning {
            HStack {
                ProgressView()
                Text(model.progressText ?? "").font(.footnote)
                Spacer()
                Button("Cancel") { model.cancel() }
            }
        } else {
            Button("Add from Google Photos", systemImage: "photo.badge.plus") {
                Task { await model.start() }
            }
        }
        if let message = model.message {
            Text(message).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

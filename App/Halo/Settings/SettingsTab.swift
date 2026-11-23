import HaloAppCore
import HaloUI
import SwiftUI

/// Settings tab: Mac bridge (pairing, digest import), data sources (contacts, photo scan), then the
/// privacy screen (people, recognition history, forget, erase everything). Wiring only.
struct SettingsTab: View {
    let environment: AppEnvironment
    let importDigest: (URL) -> Void
    @State private var pickingDigest = false
    @State private var contactsMessage: String?
    @State private var importingContacts = false

    var body: some View {
        SettingsView(model: environment.privacy) {
            Section {
                NavigationLink("Pair with your Mac") {
                    PairingScreen(environment: environment)
                }
                Button("Import iMessage digest") { pickingDigest = true }
                    .disabled(environment.digestImport.status == .importing)
                if let message = environment.digestImport.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("iMessage on your Mac")
            } footer: {
                Text(
                    "Export a digest with halo-bridge on your Mac, then open it here. Messages stay on your devices."
                )
            }
            Section("Sources") {
                Button("Import contacts") {
                    Task { await importContacts() }
                }
                .disabled(importingContacts)
                if let contactsMessage {
                    Text(contactsMessage).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Scan photos") {
                    Task { await environment.scanPhotosWithConsent() }
                }
                .disabled(!canScan)
                LabeledContent("Photo scan", value: scanText)
            }
            Section {
                Toggle("Whisper names", isOn: whisperBinding(\.isEnabled))
                Toggle("Also say one detail", isOn: whisperBinding(\.speaksChip))
                    .disabled(!environment.whisperSettings.isEnabled)
                if let device = environment.whisper.pendingDeviceConfirmation {
                    Button("Use \(device.name) for Whisper") { environment.confirmWhisperDevice(true) }
                }
            } header: {
                Text("Whisper")
            } footer: {
                Text(
                    "Quietly says who's in view through your headphones, never the speaker. Bluetooth devices need your OK once. Off while Halo is locked or in the background."
                )
            }
        }
        .sheet(isPresented: $pickingDigest) {
            DigestDocumentPicker { url in importDigest(url) }
                .ignoresSafeArea()
        }
    }

    /// One Whisper toggle, applied through the environment (persists; turning off stops speech).
    private func whisperBinding(_ keyPath: WritableKeyPath<WhisperSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { environment.whisperSettings[keyPath: keyPath] },
            set: { value in
                var settings = environment.whisperSettings
                settings[keyPath: keyPath] = value
                environment.setWhisperSettings(settings)
            })
    }

    private var canScan: Bool {
        switch environment.scanStatus {
        case .scanning, .unavailable: false
        default: environment.recognition == .available
        }
    }

    private var scanText: String {
        switch environment.scanStatus {
        case .idle: "Not running"
        case .scanning: "Scanning \(processed) photos"
        case .paused: "Paused"
        case .finished: "Done (\(processed) photos)"
        case .failed: "Stopped after an error"
        case .unavailable: "Unavailable: face model not installed"
        }
    }

    private var processed: Int {
        guard let p = environment.scanProgress else { return 0 }
        return p.assetsScanned + p.assetsSkipped + p.assetsUnavailable + p.assetsFailed
    }

    private func importContacts() async {
        importingContacts = true
        defer { importingContacts = false }
        do {
            if let count = try await environment.importContactsWithConsent() {
                contactsMessage = "Imported \(count) contacts."
            } else {
                contactsMessage = "Contacts access is off. Turn it on in Settings > Halo > Contacts."
            }
        } catch {
            contactsMessage = "Contacts could not be imported."
        }
    }
}

import HaloAppCore
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// First-run onboarding flow. Thin view over `OnboardingModel`.
struct OnboardingView: View {
    @State var model: OnboardingModel
    var onFinished: () -> Void = {}

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            content
            Spacer()
            controls
        }
        .padding(24)
        .animation(.default, value: model.step)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome:
            page(
                "person.crop.circle.badge.checkmark", "Welcome to Halo",
                "Halo recognizes people you already know and shows context from your own data. "
                    + "It only labels faces you enrolled and confirmed. It never looks up strangers, "
                    + "and everything stays on this device.")
        case .camera:
            page(
                "camera", "Camera",
                "The lens uses the camera to find faces. Video is processed on device and never uploaded.",
                hint: model.settingsHint(for: .camera), permission: .camera)
        case .contacts:
            page(
                "person.2", "Contacts",
                "Halo imports your contacts on device to name the people you know.",
                hint: model.settingsHint(for: .contacts), permission: .contacts)
            if let count = model.importedContactCount {
                Text("Imported \(count) contacts").font(.headline)
            }
            if let error = model.importError {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
        case .photos:
            page(
                "photo.on.rectangle", "Photos",
                "Halo scans your photos on device to suggest people. Nothing is named until you confirm.",
                hint: model.settingsHint(for: .photos), permission: .photos)
            scanStatus
        case .bridge:
            page(
                "message", "iMessage on your Mac (optional)",
                "Pair the Halo Mac helper later to add conversation context. Messages stay on your devices.")
            scanStatus
        case .done:
            page("checkmark.circle", "You're all set", "The photo scan keeps running in the background.")
        }
    }

    @ViewBuilder private var scanStatus: some View {
        if let p = model.scanProgress {
            if let f = p.fraction {
                ProgressView(value: f) { Text(p.isFinished ? "Scan complete" : "Scanning photos") }
            } else {
                ProgressView("Scanned \(p.processed) photos")
            }
            if model.photosAreLimited {
                Text("Limited access: only selected photos are scanned.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch model.step {
        case .welcome:
            Button("Continue") { model.acceptPrivacyExplanation() }
                .buttonStyle(.borderedProminent)
        case .camera, .contacts, .photos:
            VStack(spacing: 12) {
                Button("Allow") { Task { await model.allowCurrentStep() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
                Button("Not now") { model.skipCurrentStep() }
                    .disabled(model.isWorking)
            }
        case .bridge:
            Button("Continue") { model.continueFromBridge() }
                .buttonStyle(.borderedProminent)
        case .done:
            Button("Start using Halo") {
                model.finish()
                onFinished()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func page(
        _ symbol: String, _ title: String, _ text: String, hint: String? = nil,
        permission: OnboardingPermission? = nil
    )
        -> some View
    {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 56)).accessibilityHidden(true)
            Text(title).font(.title.bold()).accessibilityAddTraits(.isHeader)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let hint { Text(hint).font(.footnote).foregroundStyle(.orange) }
            if let permission, model.canOpenSettings(for: permission),
                let url = URL(string: UIApplication.openSettingsURLString)
            {
                Link("Open Settings", destination: url)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingView(
        model: OnboardingModel(
            permissions: FakePermissionRequester(), contacts: FakeContactsImporter(),
            scanner: FakePhotoScanner(), store: InMemoryOnboardingStore()))
}

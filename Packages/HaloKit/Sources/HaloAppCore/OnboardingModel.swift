import Foundation
import Observation

public enum OnboardingStep: Int, Sendable, CaseIterable, Comparable {
    case welcome, camera, contacts, photos, bridge, done

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// How a permission step ended.
public enum OnboardingOutcome: Sendable, Equatable {
    case granted
    case limited
    case denied
    case skipped
}

/// First-run onboarding. Consent first: the contacts import and photo scan start only when the
/// user is on that step, explicitly taps allow, and the system grants the permission. Nothing
/// leaves the device.
@MainActor @Observable
public final class OnboardingModel {
    public private(set) var step: OnboardingStep = .welcome
    public private(set) var outcomes: [OnboardingPermission: OnboardingOutcome] = [:]
    public private(set) var importedContactCount: Int?
    public private(set) var importError: String?
    public private(set) var scanProgress: PhotoScanProgress?
    public private(set) var isWorking = false

    @ObservationIgnored private let permissions: any PermissionRequesting
    @ObservationIgnored private let contacts: any ContactsImporting
    @ObservationIgnored private let scanner: any PhotoScanning
    @ObservationIgnored private let store: any OnboardingCompletionStoring
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    public init(
        permissions: any PermissionRequesting,
        contacts: any ContactsImporting,
        scanner: any PhotoScanning,
        store: any OnboardingCompletionStoring = UserDefaultsOnboardingStore()
    ) {
        self.permissions = permissions
        self.contacts = contacts
        self.scanner = scanner
        self.store = store
    }

    public var isCompleted: Bool { store.isCompleted }

    /// Text shown when a permission was denied, pointing to the Settings app. Never blocks the app.
    public func settingsHint(for permission: OnboardingPermission) -> String? {
        guard outcomes[permission] == .denied else { return nil }
        let name: String
        switch permission {
        case .camera: name = "Camera"
        case .contacts: name = "Contacts"
        case .photos: name = "Photos"
        }
        return "\(name) access is off. You can turn it on later in Settings > Halo > \(name)."
    }

    public var photosAreLimited: Bool { outcomes[.photos] == .limited }

    // MARK: Actions

    /// Welcome -> camera. Explicit acknowledgement of the privacy explanation.
    public func acceptPrivacyExplanation() {
        guard step == .welcome else { return }
        step = .camera
    }

    /// Ask for the permission of the current step; run that step's work only if granted.
    public func allowCurrentStep() async {
        guard !isWorking else { return }
        switch step {
        case .camera:
            isWorking = true
            let status = await permissions.request(.camera)
            isWorking = false
            outcomes[.camera] = Self.outcome(status)
            step = .contacts
        case .contacts:
            isWorking = true
            let status = await permissions.request(.contacts)
            outcomes[.contacts] = Self.outcome(status)
            if status.allowsUse {
                do {
                    importedContactCount = try await contacts.importContacts()
                } catch {
                    importError = "Contacts could not be imported. You can retry later in Settings."
                }
            }
            isWorking = false
            step = .photos
        case .photos:
            isWorking = true
            let status = await permissions.request(.photos)
            isWorking = false
            outcomes[.photos] = Self.outcome(status)
            if status.allowsUse { startScan() }
            step = .bridge
        case .welcome, .bridge, .done:
            return
        }
    }

    /// Skip the permission step we are on, without prompting or doing any work.
    public func skipCurrentStep() {
        switch step {
        case .camera:
            outcomes[.camera] = .skipped
            step = .contacts
        case .contacts:
            outcomes[.contacts] = .skipped
            step = .photos
        case .photos:
            outcomes[.photos] = .skipped
            step = .bridge
        case .bridge:
            step = .done
        case .welcome, .done:
            return
        }
    }

    /// Bridge explainer -> done.
    public func continueFromBridge() {
        guard step == .bridge else { return }
        step = .done
    }

    /// Persist completion. The scan, if running, continues in the background.
    public func finish() {
        guard step == .done else { return }
        store.markCompleted()
    }

    // MARK: Private

    private func startScan() {
        guard scanTask == nil else { return }
        let stream = scanner.start()
        scanTask = Task { [weak self] in
            for await progress in stream {
                self?.scanProgress = progress
            }
        }
    }

    private static func outcome(_ s: PermissionStatus) -> OnboardingOutcome {
        switch s {
        case .granted: .granted
        case .limited: .limited
        case .denied, .notDetermined: .denied
        }
    }
}

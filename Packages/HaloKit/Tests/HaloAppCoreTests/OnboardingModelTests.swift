import Foundation
import Testing

@testable import HaloAppCore

@MainActor
private struct Rig {
    let perms: FakePermissionRequester
    let contacts: FakeContactsImporter
    let scanner: FakePhotoScanner
    let store: InMemoryOnboardingStore
    let model: OnboardingModel

    init(
        results: [OnboardingPermission: PermissionStatus] = [:], contactsFail: Bool = false
    ) {
        perms = FakePermissionRequester(results: results)
        contacts = FakeContactsImporter(count: 7, fails: contactsFail)
        scanner = FakePhotoScanner()
        store = InMemoryOnboardingStore()
        model = OnboardingModel(permissions: perms, contacts: contacts, scanner: scanner, store: store)
    }
}

@MainActor private func settle() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(30))
}

@MainActor @Test func happyPathStepOrderAndCompletion() async {
    let r = Rig()
    #expect(r.model.step == .welcome)
    r.model.acceptPrivacyExplanation()
    #expect(r.model.step == .camera)
    await r.model.allowCurrentStep()
    #expect(r.model.step == .contacts)
    await r.model.allowCurrentStep()
    #expect(r.model.step == .photos)
    #expect(r.model.importedContactCount == 7)
    await r.model.allowCurrentStep()
    #expect(r.model.step == .bridge)
    await settle()
    #expect(r.model.scanProgress?.isFinished == true)
    r.model.continueFromBridge()
    #expect(r.model.step == .done)
    #expect(!r.store.isCompleted)
    r.model.finish()
    #expect(r.store.isCompleted)
    #expect(r.perms.requested == [.camera, .contacts, .photos])
}

@MainActor @Test func nothingStartsBeforeConsent() async {
    let r = Rig()
    // Allow on the welcome step does nothing: no prompt, no import, no scan.
    await r.model.allowCurrentStep()
    #expect(r.model.step == .welcome)
    r.model.acceptPrivacyExplanation()
    #expect(r.perms.requested.isEmpty)
    #expect(r.contacts.calls == 0)
    #expect(r.scanner.starts == 0)
    await r.model.allowCurrentStep()  // camera
    #expect(r.contacts.calls == 0 && r.scanner.starts == 0)
}

@MainActor @Test func skipDoesNotPromptOrStartWork() async {
    let r = Rig()
    r.model.acceptPrivacyExplanation()
    r.model.skipCurrentStep()
    r.model.skipCurrentStep()
    r.model.skipCurrentStep()
    #expect(r.model.step == .bridge)
    #expect(r.perms.requested.isEmpty)
    #expect(r.contacts.calls == 0)
    #expect(r.scanner.starts == 0)
    r.model.skipCurrentStep()
    #expect(r.model.step == .done)
    r.model.finish()
    #expect(r.store.isCompleted)
}

@MainActor @Test func deniedContactsSkipsImportAndShowsHint() async {
    let r = Rig(results: [.contacts: .denied])
    r.model.acceptPrivacyExplanation()
    await r.model.allowCurrentStep()
    await r.model.allowCurrentStep()
    #expect(r.contacts.calls == 0)
    #expect(r.model.importedContactCount == nil)
    #expect(r.model.step == .photos)
    #expect(r.model.settingsHint(for: .contacts)?.contains("Settings") == true)
    #expect(r.model.settingsHint(for: .camera) == nil)
}

@MainActor @Test func deniedPhotosDoesNotScanAndNeverBlocks() async {
    let r = Rig(results: [.photos: .denied, .camera: .denied])
    r.model.acceptPrivacyExplanation()
    await r.model.allowCurrentStep()
    await r.model.allowCurrentStep()
    await r.model.allowCurrentStep()
    #expect(r.scanner.starts == 0)
    #expect(r.model.scanProgress == nil)
    #expect(r.model.step == .bridge)
    r.model.continueFromBridge()
    r.model.finish()
    #expect(r.store.isCompleted)
}

@MainActor @Test func limitedPhotosStillScans() async {
    let r = Rig(results: [.photos: .limited])
    r.model.acceptPrivacyExplanation()
    r.model.skipCurrentStep()
    r.model.skipCurrentStep()
    await r.model.allowCurrentStep()
    #expect(r.scanner.starts == 1)
    #expect(r.model.photosAreLimited)
}

@MainActor @Test func importFailureDoesNotBlock() async {
    let r = Rig(contactsFail: true)
    r.model.acceptPrivacyExplanation()
    r.model.skipCurrentStep()
    await r.model.allowCurrentStep()
    #expect(r.model.importError != nil)
    #expect(r.model.step == .photos)
}

@MainActor @Test func finishOnlyFromDone() {
    let r = Rig()
    r.model.finish()
    #expect(!r.store.isCompleted)
}

@Test func userDefaultsStorePersists() throws {
    let suite = "halo.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsOnboardingStore(defaults: defaults)
    #expect(!store.isCompleted)
    store.markCompleted()
    #expect(UserDefaultsOnboardingStore(defaults: defaults).isCompleted)
}

@Test func progressFraction() {
    #expect(PhotoScanProgress(processed: 1, total: 4).fraction == 0.25)
    #expect(PhotoScanProgress(processed: 1).fraction == nil)
}

@MainActor @Test func limitedContactsStillImports() async {
    let r = Rig(results: [.contacts: .limited])
    r.model.acceptPrivacyExplanation()
    r.model.skipCurrentStep()
    await r.model.allowCurrentStep()
    #expect(r.contacts.calls == 1)
    #expect(r.model.contactsAreLimited)
    #expect(r.model.settingsHint(for: .contacts)?.contains("Limited") == true)
}

@MainActor @Test func undecidedIsNeutralNotDenied() async {
    let r = Rig(results: [.camera: .notDetermined])
    r.model.acceptPrivacyExplanation()
    await r.model.allowCurrentStep()
    #expect(r.model.outcomes[.camera] == .undecided)
    let hint = r.model.settingsHint(for: .camera) ?? ""
    #expect(hint.contains("not set yet") && !hint.contains("is off"))
    #expect(r.model.canOpenSettings(for: .camera))
    #expect(r.model.step == .contacts)
}

@MainActor @Test func skipIgnoredWhileWorking() async {
    let perms = FakePermissionRequester(gated: true)
    let model = OnboardingModel(
        permissions: perms, contacts: FakeContactsImporter(), scanner: FakePhotoScanner(),
        store: InMemoryOnboardingStore())
    model.acceptPrivacyExplanation()
    let task = Task { await model.allowCurrentStep() }
    while !perms.isWaiting { await Task.yield() }
    #expect(model.isWorking)
    model.skipCurrentStep()
    #expect(model.step == .camera)
    #expect(model.outcomes[.camera] == nil)
    perms.release()
    await task.value
    #expect(model.outcomes[.camera] == .granted)
    #expect(model.step == .contacts)
}

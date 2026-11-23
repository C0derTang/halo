import Foundation
import HaloCore
import SwiftUI
import Testing

@testable import HaloUI

private final class Clock: @unchecked Sendable {
    var date: TimeInterval = 1000
    func advance(_ seconds: TimeInterval) { date += seconds }
}

/// Counts calls and returns a scripted result.
private final class CountingAuth: Authenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool
    private var count = 0
    init(_ result: Bool) { self.result = result }
    var calls: Int { lock.withLock { count } }
    func set(_ value: Bool) { lock.withLock { result = value } }
    func authenticate(reason: String) async -> Bool {
        lock.withLock {
            count += 1
            return result
        }
    }
}

@MainActor
@Suite struct AppLockTests {
    @Test func startsLockedAndCovered() {
        let lock = AppLock(authenticator: CountingAuth(true))
        #expect(lock.isLocked)
        #expect(lock.isCovered)
    }

    @Test func unlockViaFakeAuth() async {
        let lock = AppLock(authenticator: CountingAuth(true))
        #expect(await lock.unlock())
        #expect(!lock.isLocked)
        #expect(!lock.isCovered)
    }

    @Test func failedAuthStaysLocked() async {
        let lock = AppLock(authenticator: CountingAuth(false))
        #expect(await lock.unlock() == false)
        #expect(lock.isLocked)
        #expect(lock.isCovered)
    }

    @Test func failedPromptSuppressesAutoPromptUntilManualUnlock() async {
        let auth = CountingAuth(false)
        let lock = AppLock(authenticator: auth)
        #expect(lock.shouldAutoPrompt)
        await lock.unlock()
        #expect(!lock.shouldAutoPrompt)
        auth.set(true)
        #expect(await lock.unlock())
        #expect(!lock.isLocked)
    }

    @Test func defaultClockIsMonotonic() {
        let a = AppLock.monotonicNow()
        let b = AppLock.monotonicNow()
        #expect(b >= a)
    }

    @Test func locksAfterBackgroundTimeout() async {
        let clock = Clock()
        let lock = AppLock(authenticator: CountingAuth(true), now: { clock.date })
        await lock.unlock()
        lock.scenePhaseChanged(to: .background)
        clock.advance(31)
        lock.scenePhaseChanged(to: .active)
        #expect(lock.isLocked)
    }

    @Test func staysUnlockedForShortBackground() async {
        let clock = Clock()
        let lock = AppLock(authenticator: CountingAuth(true), now: { clock.date })
        await lock.unlock()
        lock.scenePhaseChanged(to: .background)
        clock.advance(30)
        lock.scenePhaseChanged(to: .active)
        #expect(!lock.isLocked)
    }

    @Test func coveredWhileInactiveEvenWhenUnlocked() async {
        let lock = AppLock(authenticator: CountingAuth(true))
        await lock.unlock()
        lock.scenePhaseChanged(to: .inactive)
        #expect(lock.isCovered)  // app switcher snapshot
        lock.scenePhaseChanged(to: .active)
        #expect(!lock.isCovered)
    }
}

@MainActor
@Suite struct PrivacySettingsViewModelTests {
    private func makeModel(
        auth: CountingAuth = CountingAuth(true), pending: Bool = false
    ) -> (PrivacySettingsViewModel, FakePrivacyStore, Person, Person, CountingAuth) {
        let confirmed = Person(displayName: "Zed Sample", confirmed: true)
        let unconfirmed = Person(displayName: "Amy Sample", confirmed: false)
        let store = FakePrivacyStore(
            people: [unconfirmed, confirmed],
            log: [confirmed.id: [Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 2)]],
            pending: pending)
        return (
            PrivacySettingsViewModel(store: store, authenticator: auth), store, confirmed, unconfirmed, auth
        )
    }

    @Test func listsConfirmedFirstWithCounts() async {
        let (model, _, confirmed, unconfirmed, _) = makeModel()
        await model.load()
        #expect(model.items.map(\.id) == [confirmed.id, unconfirmed.id])
        #expect(model.items.map(\.recognitionCount) == [2, 0])
    }

    @Test func forgetNeedsConfirmationThenCallsStoreOnce() async {
        let (model, store, confirmed, _, _) = makeModel()
        await model.load()
        // Without a request, confirm is a no-op.
        #expect(await model.confirmForget() == false)
        #expect(store.forgotten.isEmpty)
        model.requestForget(confirmed.id)
        #expect(model.pendingForget?.id == confirmed.id)
        #expect(store.forgotten.isEmpty)  // request alone never deletes
        #expect(await model.confirmForget())
        #expect(store.forgotten == [confirmed.id])
        #expect(await model.confirmForget() == false)
        #expect(store.forgotten.count == 1)
        #expect(!model.items.contains { $0.id == confirmed.id })
    }

    @Test func dismissalBeforeConfirmStillForgets() async {
        let (model, store, confirmed, _, _) = makeModel()
        await model.load()
        model.requestForget(confirmed.id)
        let captured = model.pendingForget!  // dialog `presenting:` value
        model.cancelForget()  // dismissal setter runs before the deferred Task
        #expect(await model.confirmForget(captured))
        #expect(store.forgotten == [confirmed.id])
    }

    @Test func cancelForgetDoesNotCallStore() async {
        let (model, store, confirmed, _, _) = makeModel()
        await model.load()
        model.requestForget(confirmed.id)
        model.cancelForget()
        #expect(await model.confirmForget() == false)
        #expect(store.forgotten.isEmpty)
    }

    @Test func eraseRequiresTypedKeyword() async {
        let (model, store, _, _, auth) = makeModel()
        #expect(await model.eraseEverything(typed: "erase") == false)
        #expect(await model.eraseEverything(typed: "") == false)
        #expect(store.eraseCount == 0)
        #expect(auth.calls == 0)
    }

    @Test func eraseRequiresAuth() async {
        let (model, store, _, _, auth) = makeModel(auth: CountingAuth(false))
        #expect(await model.eraseEverything(typed: "ERASE") == false)
        #expect(auth.calls == 1)
        #expect(store.eraseCount == 0)
        auth.set(true)
        #expect(await model.eraseEverything(typed: "ERASE"))
        #expect(store.eraseCount == 1)
        #expect(model.items.isEmpty)
    }

    @Test func flushesOnBackgroundOnly() async {
        let (model, store, _, _, _) = makeModel(pending: true)
        #expect(model.hasPendingErasure)
        await model.scenePhaseChanged(to: .active)
        await model.scenePhaseChanged(to: .inactive)
        #expect(store.flushCount == 0)
        await model.scenePhaseChanged(to: .background)
        #expect(store.flushCount == 1)
        #expect(!model.hasPendingErasure)
    }
}

@Suite struct HaloUIFollowUpTests {
    @Test func accessibilityTextIncludesSubtitleAndVisibleChips() {
        let chips = (1...3).map { LabelChip(kind: .memoryHook, text: "chip\($0)", priority: Double(4 - $0)) }
        let data = LabelData(personID: PersonID(), title: "Sample", subtitle: "Friend", chips: chips)
        let text = HologramLabel.accessibilityText(for: data)
        #expect(text.hasPrefix("Sample, Friend"))
        for chip in HologramLayout.visibleChips(data) { #expect(text.contains(chip.text)) }
        #expect(!text.contains("chip3"))
    }

    @Test func accessibilityTextTitleOnly() {
        let data = LabelData(personID: PersonID(), title: "Sample")
        #expect(HologramLabel.accessibilityText(for: data) == "Sample")
    }
}

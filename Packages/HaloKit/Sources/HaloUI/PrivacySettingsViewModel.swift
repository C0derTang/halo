import HaloCore
import Observation
import SwiftUI

/// One row of the privacy list.
public struct PersonPrivacyItem: Identifiable, Hashable, Sendable {
    public var person: Person
    public var recognitionCount: Int
    public var id: PersonID { person.id }
}

@Observable @MainActor
public final class PrivacySettingsViewModel {
    /// The exact phrase the user must type to arm the kill switch.
    public static let eraseKeyword = "ERASE"

    public private(set) var items: [PersonPrivacyItem] = []
    public private(set) var hasPendingErasure = false
    public private(set) var errorMessage: String?
    /// Person awaiting the destructive confirmation dialog; nil when none.
    public private(set) var pendingForget: Person?

    @ObservationIgnored private let store: any PrivacyStoring & PeopleStoring
    @ObservationIgnored private let authenticator: any Authenticating

    public init(store: any PrivacyStoring & PeopleStoring, authenticator: any Authenticating) {
        self.store = store
        self.authenticator = authenticator
        self.hasPendingErasure = store.hasPendingErasure
    }

    /// Confirmed people first, then by name.
    public func load() async {
        do {
            let people = try await store.allPeople()
            var result: [PersonPrivacyItem] = []
            for person in people {
                let count = try await store.recognitionLog(for: person.id).count
                result.append(PersonPrivacyItem(person: person, recognitionCount: count))
            }
            items = result.sorted {
                if $0.person.confirmed != $1.person.confirmed { return $0.person.confirmed }
                return $0.person.displayName.localizedCaseInsensitiveCompare($1.person.displayName)
                    == .orderedAscending
            }
            hasPendingErasure = store.hasPendingErasure
            errorMessage = nil
        } catch {
            errorMessage = "Could not load people."
        }
    }

    public func recognitionDates(for id: PersonID) async -> [Date] {
        ((try? await store.recognitionLog(for: id)) ?? []).sorted(by: >)
    }

    // MARK: Forget (invariant 3): request, then explicit confirmation, then the store call.

    public func requestForget(_ id: PersonID) {
        pendingForget = items.first { $0.id == id }?.person
    }

    public func cancelForget() { pendingForget = nil }

    /// Irreversibly forgets the pending person. No-op unless `requestForget` was called first.
    @discardableResult
    public func confirmForget() async -> Bool {
        guard let person = pendingForget else { return false }
        pendingForget = nil
        do {
            try await store.forget(person.id)
            await load()
            return true
        } catch {
            errorMessage = "Could not forget \(person.displayName)."
            return false
        }
    }

    // MARK: Kill switch

    public func canErase(typed: String) -> Bool { typed == Self.eraseKeyword }

    /// Erases everything. Requires the typed keyword AND device authentication.
    @discardableResult
    public func eraseEverything(typed: String) async -> Bool {
        guard canErase(typed: typed) else { return false }
        guard await authenticator.authenticate(reason: "Erase all Halo data") else {
            errorMessage = "Authentication failed. Nothing was erased."
            return false
        }
        do {
            try await store.eraseEverything()
            await load()
            hasPendingErasure = store.hasPendingErasure
            return true
        } catch {
            errorMessage = "Erase failed."
            hasPendingErasure = store.hasPendingErasure
            return false
        }
    }

    // MARK: Background flush

    public func scenePhaseChanged(to phase: ScenePhase) async {
        guard phase == .background else { return }
        _ = await store.flushPendingErasure()
        hasPendingErasure = store.hasPendingErasure
    }
}

import Foundation
import HaloCore
import HaloUI

/// Moments from the Lens: a quick note about the people labeled on screen (#70's `MomentsModel`).
///
/// - Known people only (invariants 1 + 3): only `recognizedPeople` (confirmed, labeled people) can
///   be tagged, and each one is re-checked against the store at save time, so a person forgotten or
///   unconfirmed while the sheet is open is never written.
/// - Hooks go through `store` (`ObservedStore`), so the lens and People labels rebuild at once.
/// - Notes pass the HaloMemory sensitive-content / contact / link policy (`MomentsPolicy`).
/// - Dictation is on-device only (`OnDeviceSpeechTranscriber` in the app); the sheet stops it when
///   the scene leaves `.active`, and the Lens screen dismisses the sheet once `momentsAllowed` is
///   false (lock, background, kill switch, lens stopped).
extension AppEnvironment {
    /// A Moment may be started or stay open: the lens runs, unlocked, in the foreground, no erase.
    public var momentsAllowed: Bool {
        isLensRunning && !appLock.isLocked && phase != .background && !isErasing
    }

    /// The "Moment" button is enabled: Moments are allowed and at least one confirmed person is
    /// recognized.
    public var canStartMoment: Bool {
        momentsAllowed && (lens?.hasRecognizedPeople ?? false)
    }

    /// The sheet model for the people labeled on screen right now (read at tap time).
    public func makeMomentsModel() -> MomentsModel {
        makeMomentsModel(for: recognizedPeople)
    }

    /// The sheet model for the people on screen when the button was tapped.
    public func makeMomentsModel(for people: [LensRecognizedPerson]) -> MomentsModel {
        let store = self.store
        return MomentsModel(
            people: people.map { MomentsPerson(id: $0.id, displayName: $0.displayName, isConfirmed: true) },
            store: store,
            speech: dependencies.speechTranscriber,
            sanitize: MomentsPolicy.sanitize,
            verifyConfirmed: { id in await Self.isConfirmed(id, in: store) })
    }

    /// Live check against the store: the person still exists and is confirmed.
    nonisolated static func isConfirmed(_ id: PersonID, in store: any PeopleStoring) async -> Bool {
        guard let person = try? await store.person(id) else { return false }
        return person.id == id && person.confirmed
    }
}

import Foundation
import HaloCore
import HaloUI

/// Screen models built from the environment's shared services, so every screen uses the same
/// store (forget / erase ordering), normalizer, ranker, thumbnails and pairing key.
extension AppEnvironment {
    /// People tab list. Last-interaction matching uses the app's one `HandleNormalizer`.
    public func makePeopleListModel() -> PeopleListModel {
        let normalizer = handleNormalizer
        return PeopleListModel(store: store, normalize: { normalizer.normalize($0) })
    }

    /// Person detail. Its label preview uses the lens's ranker; "Forget" goes through the single
    /// forget path, `PrivacySettingsViewModel.confirmForget(_:)` -> `store.forget` (writers stopped,
    /// lens gallery and label cleared).
    public func makePersonDetailModel(for id: PersonID) -> PersonDetailModel {
        let privacy = self.privacy
        return PersonDetailModel(
            personID: id, store: store, thumbnails: thumbnails, ranker: labelRanker,
            space: embeddingSpace ?? Self.placeholderSpace,
            forget: { person in await privacy.confirmForget(person) })
    }

    /// Mac bridge pairing over the same Keychain key the digest importer opens envelopes with.
    public func makePairingModel() -> PairingModel {
        PairingModel(
            provider: BridgePairingKeyProvider(keyStore: dependencies.keyStore),
            authenticator: dependencies.authenticator)
    }

    /// Used only before the model has loaded or when it is missing: matches no stored face, so the
    /// detail screen shows no thumbnails rather than faces from another model.
    static let placeholderSpace = EmbeddingSpace(modelID: "unavailable", dimension: 0)
}

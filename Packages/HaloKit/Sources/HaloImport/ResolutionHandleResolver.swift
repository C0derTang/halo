import Foundation
import HaloCore

/// Maps an iMessage/digest handle (phone or email) to a known person via stored identities.
/// Attribution is strict: if candidate kinds resolve to different people the handle is ambiguous
/// and resolves to nil (a wrong name is worse than no name).
public struct HandleResolver: Sendable {
    private let store: any PeopleStoring
    private let normalization: HandleNormalization

    public init(store: any PeopleStoring, normalization: HandleNormalization = HandleNormalization()) {
        self.store = store
        self.normalization = normalization
    }

    public func resolve(handle: String) async throws -> PersonID? {
        var candidates: [(Identity.Kind, String)] = []
        if let email = normalization.email(handle) {
            candidates.append((.email, email))
        } else if let phone = normalization.e164(handle) {
            candidates.append((.phone, phone))
        }
        candidates.append((.imessageHandle, handle))
        let normalized = normalization.normalizer.normalize(handle)
        if normalized != handle { candidates.append((.imessageHandle, normalized)) }

        var owners = Set<PersonID>()
        for (kind, value) in candidates {
            if let p = try await store.person(matching: kind, value: value) { owners.insert(p.id) }
        }
        return owners.count == 1 ? owners.first : nil
    }

    public func resolve(_ entry: InteractionDigest.Entry) async throws -> PersonID? {
        try await resolve(handle: entry.handle)
    }
}

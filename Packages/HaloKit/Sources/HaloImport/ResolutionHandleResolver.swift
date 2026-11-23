import Foundation
import HaloCore

/// Maps an iMessage/digest handle (phone or email) to a known person via stored identities.
public struct HandleResolver: Sendable {
    private let store: any PeopleStoring

    public init(store: any PeopleStoring) { self.store = store }

    public func resolve(handle: String) async throws -> PersonID? {
        let candidates: [(Identity.Kind, String)]
        if let email = HandleNormalization.email(handle) {
            candidates = [(.email, email), (.imessageHandle, handle)]
        } else if let phone = HandleNormalization.e164(handle) {
            candidates = [(.phone, phone), (.imessageHandle, handle)]
        } else {
            candidates = [(.imessageHandle, handle)]
        }
        for (kind, value) in candidates {
            if let p = try await store.person(matching: kind, value: value) { return p.id }
        }
        return nil
    }

    public func resolve(_ entry: InteractionDigest.Entry) async throws -> PersonID? {
        try await resolve(handle: entry.handle)
    }
}

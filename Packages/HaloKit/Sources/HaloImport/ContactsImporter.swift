import Foundation
import HaloBridgeKit
import HaloCore

public struct ContactsImportResult: Sendable {
    public var created = 0
    public var updated = 0
    public var unchanged = 0
    public var skipped = 0
    /// Identities skipped because (kind, value) already belongs to a different person.
    public var conflicts = 0
    /// Contact photos as enrollment candidates. No face processing here, and nobody is
    /// recognizable until the user confirms them (invariant 3).
    public var thumbnails: [(PersonID, Data)] = []
}

/// Idempotent contacts -> people graph importer. Never sets `confirmed = true`.
public struct ContactsImporter: Sendable {
    private let store: any PeopleStoring
    private let source: any ContactsSource
    private let normalization: HandleNormalization

    public init(
        store: any PeopleStoring, source: any ContactsSource,
        normalization: HandleNormalization = HandleNormalization()
    ) {
        self.store = store
        self.source = source
        self.normalization = normalization
    }

    public func importContacts(now: Date = Date()) async throws -> ContactsImportResult {
        var result = ContactsImportResult()
        for record in try await source.fetchContacts() {
            guard let name = Self.displayName(record) else {
                result.skipped += 1
                continue
            }
            let relationship = Self.relationship(record)
            var person: Person
            var personTouched = false
            var personCreated = false
            if let existing = try await store.person(matching: .contact, value: record.identifier) {
                person = existing
                if person.displayName != name {
                    person.displayName = name
                    personTouched = true
                }
                // Stale data: a relationship/birthday that vanished from the contact is cleared.
                if person.relationship != relationship {
                    person.relationship = relationship
                    personTouched = true
                }
                if person.birthday != record.birthday {
                    person.birthday = record.birthday
                    personTouched = true
                }
                if personTouched {
                    person.updatedAt = now
                    try await store.upsert(person)
                }
            } else {
                // New people are never confirmed: contacts are not recognizable until faces are.
                person = Person(
                    displayName: name, relationship: relationship, birthday: record.birthday,
                    confirmed: false, createdAt: now, updatedAt: now)
                try await store.upsert(person)
                personCreated = true
            }

            // TODO: remove identities that disappeared from the contact once the store conforms to
            // `EnrollmentStoring.removeIdentity` (store issue); until then they are left in place.
            var seen = Set(try await store.identities(for: person.id))
            var wanted = [Identity(personID: person.id, kind: .contact, value: record.identifier)]
            for p in record.phones {
                if let v = normalization.e164(p) {
                    wanted.append(Identity(personID: person.id, kind: .phone, value: v))
                }
            }
            for e in record.emails {
                if let v = normalization.email(e) {
                    wanted.append(Identity(personID: person.id, kind: .email, value: v))
                }
            }
            var addedIdentity = false
            for identity in wanted where !seen.contains(identity) {
                seen.insert(identity)
                do {
                    try await store.addIdentity(identity)
                    addedIdentity = true
                } catch {
                    // Store-agnostic conflict detection: if another person owns this handle, skip it
                    // (never move a handle, never abort the import). Any other failure propagates.
                    if let owner = try? await store.person(matching: identity.kind, value: identity.value),
                        owner.id != person.id
                    {
                        result.conflicts += 1
                    } else {
                        throw error
                    }
                }
            }
            if personCreated {
                result.created += 1
            } else if personTouched || addedIdentity {
                result.updated += 1
            } else {
                result.unchanged += 1
            }

            if let data = record.thumbnail, !data.isEmpty {
                result.thumbnails.append((person.id, data))
            }
        }
        return result
    }

    static func displayName(_ r: ContactRecord) -> String? {
        let full = [r.givenName, r.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        for candidate in [full, r.nickname, r.organization] {
            let t = candidate.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return nil
    }

    static func relationship(_ r: ContactRecord) -> String? {
        switch (r.jobTitle.isEmpty, r.organization.isEmpty) {
        case (false, false): return "\(r.jobTitle) @ \(r.organization)"
        case (false, true): return r.jobTitle
        case (true, false): return r.organization
        case (true, true): return nil
        }
    }
}

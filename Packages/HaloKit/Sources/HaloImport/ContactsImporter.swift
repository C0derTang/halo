import Foundation
import HaloCore

public struct ContactsImportResult: Sendable {
    public var created = 0
    public var updated = 0
    public var unchanged = 0
    public var skipped = 0
    /// Contact photos as enrollment candidates. No face processing here, and nobody is
    /// recognizable until the user confirms them (invariant 3).
    public var thumbnails: [(PersonID, Data)] = []
}

/// Idempotent contacts -> people graph importer. Never sets `confirmed = true`.
public struct ContactsImporter: Sendable {
    private let store: any PeopleStoring
    private let source: any ContactsSource

    public init(store: any PeopleStoring, source: any ContactsSource) {
        self.store = store
        self.source = source
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
                if let relationship, person.relationship != relationship {
                    person.relationship = relationship
                    personTouched = true
                }
                if let b = record.birthday, person.birthday != b {
                    person.birthday = b
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

            var seen = Set(try await store.identities(for: person.id))
            var wanted = [Identity(personID: person.id, kind: .contact, value: record.identifier)]
            for p in record.phones {
                if let v = HandleNormalization.e164(p) {
                    wanted.append(Identity(personID: person.id, kind: .phone, value: v))
                }
            }
            for e in record.emails {
                if let v = HandleNormalization.email(e) {
                    wanted.append(Identity(personID: person.id, kind: .email, value: v))
                }
            }
            var addedIdentity = false
            for identity in wanted where !seen.contains(identity) {
                seen.insert(identity)
                try await store.addIdentity(identity)
                addedIdentity = true
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

import Foundation
import HaloBridgeKit
import HaloCore
import Testing

@testable import HaloImport

private let us = HandleNormalization(region: "US")

private func ada(name: String = "Ada", org: String = "Acme") -> ContactRecord {
    ContactRecord(
        identifier: "C1", givenName: name, familyName: "Lovelace", organization: org,
        jobTitle: "Engineer", birthday: DateComponents(month: 12, day: 10),
        phones: ["(415) 555-0100"], emails: ["Ada@Example.COM"], thumbnail: Data([1, 2, 3]))
}

@Suite struct ContactsImporterTests {
    @Test func firstImportCreatesPeopleAndIdentities() async throws {
        let store = FakePeopleStore()
        let src = InMemoryContactsSource(records: [
            ada(), ContactRecord(identifier: "C2", givenName: "Bob"),
        ])
        let r = try await ContactsImporter(store: store, source: src).importContacts()
        #expect(r.created == 2)
        #expect(try await store.allPeople().count == 2)
        let a = try #require(try await store.person(matching: .contact, value: "C1"))
        #expect(a.displayName == "Ada Lovelace")
        #expect(a.relationship == "Engineer @ Acme")
        let kinds = Set(try await store.identities(for: a.id).map { "\($0.kind.rawValue):\($0.value)" })
        #expect(kinds == ["contact:C1", "phone:+14155550100", "email:ada@example.com"])
        #expect(r.thumbnails.count == 1)
        #expect(r.thumbnails[0].0 == a.id)
    }

    @Test func nothingIsConfirmed() async throws {
        let store = FakePeopleStore()
        let imp = ContactsImporter(
            store: store, source: InMemoryContactsSource(records: [ada()]), normalization: us)
        _ = try await imp.importContacts()
        _ = try await imp.importContacts()
        #expect(try await store.allPeople().allSatisfy { !$0.confirmed })
    }

    @Test func reimportPreservesConfirmation() async throws {
        let store = FakePeopleStore()
        let imp = ContactsImporter(
            store: store, source: InMemoryContactsSource(records: [ada()]), normalization: us)
        _ = try await imp.importContacts()
        var p = try #require(try await store.person(matching: .contact, value: "C1"))
        p.confirmed = true
        try await store.upsert(p)
        let imp2 = ContactsImporter(
            store: store, source: InMemoryContactsSource(records: [ada(name: "Augusta")]))
        _ = try await imp2.importContacts()
        #expect(try await store.person(p.id)?.confirmed == true)
    }

    @Test func secondImportIsNoOp() async throws {
        let store = FakePeopleStore()
        let imp = ContactsImporter(
            store: store, source: InMemoryContactsSource(records: [ada()]), normalization: us)
        _ = try await imp.importContacts()
        let before = try await store.allPeople()
        let identsBefore = await store.idents
        let r = try await imp.importContacts(now: Date().addingTimeInterval(1000))
        #expect(r.created == 0 && r.updated == 0 && r.unchanged == 1)
        #expect(try await store.allPeople() == before)
        #expect(await store.idents == identsBefore)
    }

    @Test func changedNameUpdatesSamePerson() async throws {
        let store = FakePeopleStore()
        _ = try await ContactsImporter(
            store: store, source: InMemoryContactsSource(records: [ada()]), normalization: us
        )
        .importContacts()
        let id = try #require(try await store.person(matching: .contact, value: "C1")).id
        let r = try await ContactsImporter(
            store: store, source: InMemoryContactsSource(records: [ada(name: "Augusta")])
        ).importContacts()
        #expect(r.updated == 1 && r.created == 0)
        #expect(try await store.allPeople().count == 1)
        #expect(try await store.person(id)?.displayName == "Augusta Lovelace")
    }

    @Test func namelessContactSkipped() async throws {
        let store = FakePeopleStore()
        let r = try await ContactsImporter(
            store: store, source: InMemoryContactsSource(records: [ContactRecord(identifier: "X")])
        ).importContacts()
        #expect(r.skipped == 1)
        #expect(try await store.allPeople().isEmpty)
    }

    @Test func duplicatePhoneAcrossContactsCountsConflictAndDoesNotThrow() async throws {
        let store = FakePeopleStore()
        let a = ContactRecord(identifier: "A", givenName: "Ann", phones: ["415-555-0100"])
        let b = ContactRecord(
            identifier: "B", givenName: "Bo", phones: ["+1 415 555 0100"], emails: ["bo@x.com"])
        let r = try await ContactsImporter(
            store: store, source: InMemoryContactsSource(records: [a, b]), normalization: us
        ).importContacts()
        #expect(r.created == 2)
        #expect(r.conflicts == 1)
        let ann = try #require(try await store.person(matching: .contact, value: "A"))
        let bo = try #require(try await store.person(matching: .contact, value: "B"))
        // The handle stays with the first owner; the second contact still gets its other identities.
        #expect(try await store.person(matching: .phone, value: "+14155550100")?.id == ann.id)
        #expect(try await store.identities(for: bo.id).contains { $0.kind == .email })
        #expect(try await store.allPeople().allSatisfy { !$0.confirmed })
    }

    @Test func nonConflictStoreErrorsStillPropagate() async throws {
        struct Boom: Error {}
        actor Failing: PeopleStoring {
            let inner = FakePeopleStore()
            func person(_ id: PersonID) async throws -> Person? { try await inner.person(id) }
            func allPeople() async throws -> [Person] { try await inner.allPeople() }
            func upsert(_ p: Person) async throws { try await inner.upsert(p) }
            func identities(for id: PersonID) async throws -> [Identity] {
                try await inner.identities(for: id)
            }
            func addIdentity(_ i: Identity) async throws { throw Boom() }
            func person(matching k: Identity.Kind, value: String) async throws -> Person? {
                try await inner.person(matching: k, value: value)
            }
            func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] { [] }
            func addEmbeddings(_ e: [FaceEmbedding]) async throws {}
            func forget(_ id: PersonID) async throws {}
            func latestDigest() async throws -> InteractionDigest? { nil }
            func saveDigest(_ d: InteractionDigest) async throws {}
        }
        await #expect(throws: Boom.self) {
            _ = try await ContactsImporter(
                store: Failing(), source: InMemoryContactsSource(records: [ada()]), normalization: us
            ).importContacts()
        }
    }

    @Test func clearedBirthdayAndRelationshipAreRemovedOnReimport() async throws {
        let store = FakePeopleStore()
        _ = try await ContactsImporter(
            store: store, source: InMemoryContactsSource(records: [ada()]), normalization: us
        ).importContacts()
        let stripped = ContactRecord(identifier: "C1", givenName: "Ada", familyName: "Lovelace")
        let r = try await ContactsImporter(
            store: store, source: InMemoryContactsSource(records: [stripped]), normalization: us
        ).importContacts()
        let p = try #require(try await store.person(matching: .contact, value: "C1"))
        #expect(p.birthday == nil && p.relationship == nil)
        #expect(r.updated == 1)
    }

    @Test(arguments: [
        "(415) 555-0100", "415-555-0100", "1 415 555 0100", "+1 (415) 555-0100",
        "+44 20 7946 0958", "0044 20 7946 0958", "+14155550100", "Ada@Example.COM",
        " bo@x.org ", "12345", "abc", "",
    ])
    func normalizationParityWithBridge(raw: String) {
        let bridge = HandleNormalizer(region: "US").normalize(raw)
        if let e = us.e164(raw) {
            #expect(e == bridge)
        } else if let m = us.email(raw) {
            #expect(m == bridge)
        }
    }

    @Test func regionIsConfigurable() {
        let gb = HandleNormalization(region: "GB")
        #expect(gb.e164("020 7946 0958") == HandleNormalizer(region: "GB").normalize("020 7946 0958"))
        #expect(gb.e164("020 7946 0958") == "+442079460958")
    }

    @Test(arguments: [
        ("(415) 555-0100", "+14155550100"),
        ("415-555-0100", "+14155550100"),
        ("1 415 555 0100", "+14155550100"),
        ("+1 (415) 555-0100", "+14155550100"),
        ("+44 20 7946 0958", "+442079460958"),
        ("0044 20 7946 0958", "+442079460958"),
        ("+14155550100", "+14155550100"),
    ])
    func phoneNormalization(raw: String, expected: String) {
        #expect(us.e164(raw) == expected)
    }

    @Test(arguments: ["", "abc", "12345", "+1", "5550"])
    func badPhonesRejected(raw: String) {
        #expect(us.e164(raw) == nil)
    }

    @Test func emailLowercased() {
        #expect(us.email("  Ada@Example.COM ") == "ada@example.com")
        #expect(us.email("nope") == nil)
    }
}

@Suite struct HandleResolverTests {
    private func seeded() async throws -> (FakePeopleStore, PersonID) {
        let store = FakePeopleStore()
        _ = try await ContactsImporter(
            store: store, source: InMemoryContactsSource(records: [ada()]), normalization: us
        )
        .importContacts()
        return (store, try #require(try await store.person(matching: .contact, value: "C1")).id)
    }

    @Test func resolvesByPhoneAndEmail() async throws {
        let (store, id) = try await seeded()
        let r = HandleResolver(store: store, normalization: us)
        #expect(try await r.resolve(handle: "+14155550100") == id)
        #expect(try await r.resolve(handle: "415.555.0100") == id)
        #expect(try await r.resolve(handle: "ADA@example.com") == id)
    }

    @Test func unmatchedIsNil() async throws {
        let (store, _) = try await seeded()
        let r = HandleResolver(store: store, normalization: us)
        #expect(try await r.resolve(handle: "+19995550000") == nil)
        #expect(try await r.resolve(handle: "who@else.com") == nil)
        #expect(try await r.resolve(handle: "garbage") == nil)
    }

    @Test func crossKindAmbiguityIsNil() async throws {
        let store = FakePeopleStore()
        let p1 = Person(displayName: "P1")
        let p2 = Person(displayName: "P2")
        try await store.upsert(p1)
        try await store.upsert(p2)
        try await store.addIdentity(Identity(personID: p1.id, kind: .phone, value: "+14155550100"))
        try await store.addIdentity(
            Identity(personID: p2.id, kind: .imessageHandle, value: "+14155550100"))
        #expect(
            try await HandleResolver(store: store, normalization: us).resolve(handle: "+14155550100") == nil)
    }

    @Test func sameOwnerAcrossKindsResolves() async throws {
        let store = FakePeopleStore()
        let p1 = Person(displayName: "P1")
        try await store.upsert(p1)
        try await store.addIdentity(Identity(personID: p1.id, kind: .phone, value: "+14155550100"))
        try await store.addIdentity(
            Identity(personID: p1.id, kind: .imessageHandle, value: "+14155550100"))
        #expect(
            try await HandleResolver(store: store, normalization: us).resolve(handle: "+14155550100")
                == p1.id)
    }
}

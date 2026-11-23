import Foundation
import HaloCore
import Testing

@testable import HaloImport

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
        let imp = ContactsImporter(store: store, source: InMemoryContactsSource(records: [ada()]))
        _ = try await imp.importContacts()
        _ = try await imp.importContacts()
        #expect(try await store.allPeople().allSatisfy { !$0.confirmed })
    }

    @Test func reimportPreservesConfirmation() async throws {
        let store = FakePeopleStore()
        let imp = ContactsImporter(store: store, source: InMemoryContactsSource(records: [ada()]))
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
        let imp = ContactsImporter(store: store, source: InMemoryContactsSource(records: [ada()]))
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
        _ = try await ContactsImporter(store: store, source: InMemoryContactsSource(records: [ada()]))
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
        #expect(HandleNormalization.e164(raw) == expected)
    }

    @Test(arguments: ["", "abc", "12345", "+1", "5550"])
    func badPhonesRejected(raw: String) {
        #expect(HandleNormalization.e164(raw) == nil)
    }

    @Test func emailLowercased() {
        #expect(HandleNormalization.email("  Ada@Example.COM ") == "ada@example.com")
        #expect(HandleNormalization.email("nope") == nil)
    }
}

@Suite struct HandleResolverTests {
    private func seeded() async throws -> (FakePeopleStore, PersonID) {
        let store = FakePeopleStore()
        _ = try await ContactsImporter(store: store, source: InMemoryContactsSource(records: [ada()]))
            .importContacts()
        return (store, try #require(try await store.person(matching: .contact, value: "C1")).id)
    }

    @Test func resolvesByPhoneAndEmail() async throws {
        let (store, id) = try await seeded()
        let r = HandleResolver(store: store)
        #expect(try await r.resolve(handle: "+14155550100") == id)
        #expect(try await r.resolve(handle: "415.555.0100") == id)
        #expect(try await r.resolve(handle: "ADA@example.com") == id)
    }

    @Test func unmatchedIsNil() async throws {
        let (store, _) = try await seeded()
        let r = HandleResolver(store: store)
        #expect(try await r.resolve(handle: "+19995550000") == nil)
        #expect(try await r.resolve(handle: "who@else.com") == nil)
        #expect(try await r.resolve(handle: "garbage") == nil)
    }
}

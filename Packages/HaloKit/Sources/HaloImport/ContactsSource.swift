import Foundation

#if canImport(Contacts)
    import Contacts
#endif

/// One address-book entry, reduced to the fields the importer needs.
public struct ContactRecord: Hashable, Sendable {
    public var identifier: String
    public var givenName: String
    public var familyName: String
    public var nickname: String
    public var organization: String
    public var jobTitle: String
    public var birthday: DateComponents?
    public var phones: [String]
    public var emails: [String]
    public var thumbnail: Data?

    public init(
        identifier: String, givenName: String = "", familyName: String = "", nickname: String = "",
        organization: String = "", jobTitle: String = "", birthday: DateComponents? = nil,
        phones: [String] = [], emails: [String] = [], thumbnail: Data? = nil
    ) {
        self.identifier = identifier
        self.givenName = givenName
        self.familyName = familyName
        self.nickname = nickname
        self.organization = organization
        self.jobTitle = jobTitle
        self.birthday = birthday
        self.phones = phones
        self.emails = emails
        self.thumbnail = thumbnail
    }
}

public protocol ContactsSource: Sendable {
    func fetchContacts() async throws -> [ContactRecord]
}

/// In-memory source for tests and previews. Never touches the real address book.
public struct InMemoryContactsSource: ContactsSource {
    public var records: [ContactRecord]
    public init(records: [ContactRecord] = []) { self.records = records }
    public func fetchContacts() async throws -> [ContactRecord] { records }
}

public enum ContactsAccessError: Error, Sendable {
    case denied
}

#if canImport(Contacts)
    /// Reads the user's address book via `CNContactStore`. Work runs off the main actor.
    public struct CNContactsSource: ContactsSource {
        public init() {}

        public func fetchContacts() async throws -> [ContactRecord] {
            guard try await CNContactStore().requestAccess(for: .contacts) else {
                throw ContactsAccessError.denied
            }
            return try await Task.detached(priority: .utility) {
                let keys: [CNKeyDescriptor] = [
                    CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor,
                    CNContactNicknameKey as CNKeyDescriptor,
                    CNContactOrganizationNameKey as CNKeyDescriptor,
                    CNContactJobTitleKey as CNKeyDescriptor,
                    CNContactBirthdayKey as CNKeyDescriptor,
                    CNContactPhoneNumbersKey as CNKeyDescriptor,
                    CNContactEmailAddressesKey as CNKeyDescriptor,
                    CNContactThumbnailImageDataKey as CNKeyDescriptor,
                ]
                let request = CNContactFetchRequest(keysToFetch: keys)
                var out: [ContactRecord] = []
                try CNContactStore().enumerateContacts(with: request) { c, _ in
                    out.append(
                        ContactRecord(
                            identifier: c.identifier, givenName: c.givenName,
                            familyName: c.familyName, nickname: c.nickname,
                            organization: c.organizationName, jobTitle: c.jobTitle,
                            birthday: c.birthday,
                            phones: c.phoneNumbers.map { $0.value.stringValue },
                            emails: c.emailAddresses.map { $0.value as String },
                            thumbnail: c.thumbnailImageData))
                }
                return out
            }.value
        }
    }
#endif

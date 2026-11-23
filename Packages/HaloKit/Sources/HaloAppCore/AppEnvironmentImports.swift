import Foundation
import HaloCore
import HaloImport

// MARK: - Imports owned by the environment

extension AppEnvironment {
    /// Imports the address book (onboarding, Settings). The environment owns the task:
    /// - a forget waits for it to finish before deleting anyone;
    /// - the kill switch cancels it and waits for it, so no write lands after the erase;
    /// - while a forget / erase runs, a new import waits until it has finished.
    ///
    /// A second call while one is running joins it instead of importing twice.
    public func importContacts() async throws -> ContactsImportResult {
        if let running = contactsTask { return try await running.value }
        await whenNoDestructiveOperation()
        if let running = contactsTask { return try await running.value }
        let importer = makeContactsImporter()
        let task = Task { try await importer.importContacts() }
        contactsTask = task
        defer { if contactsTask == task { contactsTask = nil } }
        return try await task.value
    }

    /// Imports a `.halodigest` (from `onOpenURL` or the document picker, both app-owned copies the
    /// importer deletes afterwards). Same ownership rules as `importContacts()`. Imports run one at
    /// a time. On success the lens gallery is rebuilt and the lens labels refresh, so the new
    /// conversation context shows at once.
    public func importDigest(url: URL) async {
        while let running = digestTask { await running.value }
        await whenNoDestructiveOperation()
        while let running = digestTask { await running.value }
        let model = digestImport
        let task = Task { await model.importDigest(url: url) }
        digestTask = task
        await task.value
        if digestTask == task { digestTask = nil }
        if case .succeeded = model.status {
            // `saveDigest` went through `store`, which already scheduled the gallery rebuild and
            // bumped `peopleRevision` (People screens reload). Rebuild the on-screen labels now.
            lens?.refreshLabels()
        }
    }
}

// MARK: - Cancellable writes

/// Forwards to the app store, but every write first checks the calling task for cancellation and
/// throws `CancellationError` instead of writing. Importers run on top of it, so the kill switch
/// can stop them between two writes even though the importers themselves never check.
struct CancellableWriteStore: PeopleStoring {
    let base: any PeopleStoring

    private func checkCancellation() throws {
        try Task.checkCancellation()
    }

    func person(_ id: PersonID) async throws -> Person? { try await base.person(id) }
    func allPeople() async throws -> [Person] { try await base.allPeople() }
    func upsert(_ person: Person) async throws {
        try checkCancellation()
        try await base.upsert(person)
    }
    func identities(for id: PersonID) async throws -> [Identity] { try await base.identities(for: id) }
    func addIdentity(_ identity: Identity) async throws {
        try checkCancellation()
        try await base.addIdentity(identity)
    }
    func person(matching kind: Identity.Kind, value: String) async throws -> Person? {
        try await base.person(matching: kind, value: value)
    }
    func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] {
        try await base.confirmedGallery(space: space)
    }
    func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws {
        try checkCancellation()
        try await base.addEmbeddings(embeddings)
    }
    func forget(_ id: PersonID) async throws { try await base.forget(id) }
    func latestDigest() async throws -> InteractionDigest? { try await base.latestDigest() }
    func saveDigest(_ digest: InteractionDigest) async throws {
        try checkCancellation()
        try await base.saveDigest(digest)
    }
}

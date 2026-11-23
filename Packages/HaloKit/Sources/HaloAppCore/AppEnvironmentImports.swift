import Foundation
import HaloCore
import HaloImport

// MARK: - Imports owned by the environment

extension AppEnvironment {
    /// Imports the address book (onboarding, Settings). The environment owns the task:
    /// - a forget waits for it to finish before deleting anyone;
    /// - the kill switch cancels it and waits for it, so no write lands after the erase;
    /// - while a forget runs, a new import waits until it has finished;
    /// - an import requested before a kill switch that has not started writing when the erase
    ///   begins is dropped (throws `CancellationError`), never run after the erase.
    ///
    /// A second call while one is running joins it instead of importing twice.
    public func importContacts() async throws -> ContactsImportResult {
        if let running = contactsTask { return try await running.value }
        let requestedIn = eraseGeneration
        await whenNoDestructiveOperation()
        guard eraseGeneration == requestedIn else { throw CancellationError() }
        if let running = contactsTask { return try await running.value }
        // No suspension between the checks above and registering the task: a forget / erase that
        // starts from here on sees `contactsTask` and stops it.
        let importer = makeContactsImporter()
        let task = Task { try await importer.importContacts() }
        contactsTask = task
        defer { if contactsTask == task { contactsTask = nil } }
        return try await task.value
    }

    /// Imports a `.halodigest` (from `onOpenURL` or the document picker, both app-owned copies the
    /// importer deletes afterwards). On success the lens gallery is rebuilt and the lens labels
    /// refresh, so the new conversation context shows at once.
    ///
    /// Requests are queued and run one at a time, in order. Each one, when its turn comes:
    /// - waits for a running forget / erase to finish (this wait is not a writer, so a forget /
    ///   erase never waits on it);
    /// - is dropped (its app-owned file deleted, nothing saved) if a kill switch began after it was
    ///   requested;
    /// - otherwise registers its writer as `digestTask` with no suspension after those checks, so a
    ///   forget awaits it and a kill switch cancels and awaits it.
    ///
    /// Returns false when the import was dropped by a kill switch; `digestImport.status` has the
    /// result otherwise.
    @discardableResult
    public func importDigest(url: URL) async -> Bool {
        let requestedIn = eraseGeneration
        let previous = digestQueue
        let model = digestImport
        let slot = Task<Bool, Never> { [weak self] in
            _ = await previous?.value
            guard let self else { return false }
            await self.whenNoDestructiveOperation()
            guard self.eraseGeneration == requestedIn else {
                Self.discardOwnedFile(url)
                return false
            }
            let writer = Task { await model.importDigest(url: url) }
            self.digestTask = writer
            await writer.value
            if self.digestTask == writer { self.digestTask = nil }
            if case .succeeded = model.status {
                // `saveDigest` went through `store`, which already scheduled the gallery rebuild
                // and bumped `peopleRevision` (People screens reload). Rebuild on-screen labels now.
                self.lens?.refreshLabels()
            }
            return true
        }
        digestQueue = slot
        let ran = await slot.value
        if digestQueue == slot { digestQueue = nil }
        return ran
    }

    /// Deletes a dropped import's file when it is the app's own copy (Inbox / tmp / caches), the
    /// same rule `DigestImporter` applies after an import. A user's original is never touched.
    nonisolated static func discardOwnedFile(_ url: URL) {
        guard url.isFileURL else { return }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let owned = DigestImporter.defaultDeletableRoots.contains { root in
            let r = root.resolvingSymlinksInPath().standardizedFileURL.path
            return path.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        }
        if owned { try? FileManager.default.removeItem(at: url) }
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

import Foundation
import HaloCore
import Synchronization

/// Every store protocol the app uses. Implemented by HaloStore's `PeopleStore`.
public typealias AppStoring = PeopleStoring & EnrollmentStoring & PrivacyStoring

public enum AppStoreError: Error, Equatable, Sendable {
    /// The encrypted store could not be opened yet (e.g. the app was pre-warmed before the first
    /// device unlock, when Data Protection `.complete` files are unreadable). Retried on `.active`.
    case unavailable
}

/// The store, opened lazily. Opening is retried until it succeeds; until then every operation
/// throws `AppStoreError.unavailable` (never a silent in-memory fallback that would lose data).
///
/// Internal writers (photo scan, gallery refresh) use this directly; screens use the
/// `ObservedStore` wrapper so that destructive operations go through the environment first.
final class LazyStore: AppStoring {
    private let open: @Sendable () throws -> any AppStoring
    private let opened = Mutex<(any AppStoring)?>(nil)
    /// Serializes opening: only one caller at a time runs `open()` (file setup + migrations), so two
    /// callers can never create two stores on the same file concurrently. Separate from `opened` so
    /// reads of an already-open store never wait behind an open in progress.
    private let opening = Mutex(())

    init(open: @escaping @Sendable () throws -> any AppStoring) {
        self.open = open
    }

    var isOpen: Bool { opened.withLock { $0 != nil } }

    /// Opens the store if it is not open yet. Returns true when it is open.
    @discardableResult
    func openIfNeeded() -> Bool {
        if isOpen { return true }
        return opening.withLock { _ in
            if isOpen { return true }  // another caller opened it while we waited
            guard let store = try? open() else { return false }
            opened.withLock { $0 = store }
            return true
        }
    }

    private func base() throws -> any AppStoring {
        if let store = opened.withLock({ $0 }) { return store }
        guard openIfNeeded(), let store = opened.withLock({ $0 }) else { throw AppStoreError.unavailable }
        return store
    }

    // MARK: PeopleStoring

    func person(_ id: PersonID) async throws -> Person? { try await base().person(id) }
    func allPeople() async throws -> [Person] { try await base().allPeople() }
    func upsert(_ person: Person) async throws { try await base().upsert(person) }
    func identities(for id: PersonID) async throws -> [Identity] { try await base().identities(for: id) }
    func addIdentity(_ identity: Identity) async throws { try await base().addIdentity(identity) }
    func person(matching kind: Identity.Kind, value: String) async throws -> Person? {
        try await base().person(matching: kind, value: value)
    }
    func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] {
        try await base().confirmedGallery(space: space)
    }
    func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws {
        try await base().addEmbeddings(embeddings)
    }
    func forget(_ id: PersonID) async throws { try await base().forget(id) }
    func latestDigest() async throws -> InteractionDigest? { try await base().latestDigest() }
    func saveDigest(_ digest: InteractionDigest) async throws { try await base().saveDigest(digest) }

    // MARK: EnrollmentStoring

    func unassignedEmbeddings(space: EmbeddingSpace) async throws -> [FaceEmbedding] {
        try await base().unassignedEmbeddings(space: space)
    }
    func embeddings(ids: [UUID]) async throws -> [FaceEmbedding] { try await base().embeddings(ids: ids) }
    func replaceClusters(_ clusters: [ClusterRecord]) async throws {
        try await base().replaceClusters(clusters)
    }
    func clusters() async throws -> [ClusterRecord] { try await base().clusters() }
    func confirm(cluster id: String, as person: PersonID) async throws {
        try await base().confirm(cluster: id, as: person)
    }
    func deleteEmbeddings(ids: [UUID]) async throws { try await base().deleteEmbeddings(ids: ids) }
    func removeIdentity(_ identity: Identity) async throws { try await base().removeIdentity(identity) }
    func scanCursor() async throws -> String? { try await base().scanCursor() }
    func setScanCursor(_ cursor: String?) async throws { try await base().setScanCursor(cursor) }

    // MARK: PrivacyStoring

    func logRecognition(of id: PersonID, at date: Date) async throws {
        try await base().logRecognition(of: id, at: date)
    }
    func recognitionLog(for id: PersonID) async throws -> [Date] { try await base().recognitionLog(for: id) }
    var hasPendingErasure: Bool { opened.withLock { $0?.hasPendingErasure ?? false } }
    func flushPendingErasure() async -> Bool {
        guard let store = opened.withLock({ $0 }) else { return true }
        return await store.flushPendingErasure()
    }
    func eraseEverything() async throws { try await base().eraseEverything() }
}

/// Receives the store's identity-change and destructive-operation events. Implemented by
/// `AppEnvironment`.
@MainActor
protocol ObservedStoreDelegate: AnyObject, Sendable {
    /// Before any person is forgotten: stop in-flight writers, drop the person from the lens.
    func storeWillForget(_ id: PersonID) async
    func storeDidForget(_ id: PersonID, succeeded: Bool) async
    /// Before the kill switch: stop in-flight writers and the lens.
    func storeWillEraseEverything() async
    func storeDidEraseEverything(succeeded: Bool) async
    /// Something that can change the gallery or a label changed (debounced refresh).
    func storeDidChangeIdentities() async
}

/// The store every screen gets. Forwards to `LazyStore`, but routes the destructive operations
/// through the environment (invariants 2 + 3):
///
/// - `forget` and `eraseEverything` first let the delegate cancel in-flight writers (the photo
///   scan) and, for the kill switch, stop the lens, so nothing can re-insert data after the erase.
/// - Every change that can alter the confirmed gallery or a label (confirm, forget,
///   deleteEmbeddings, eraseEverything, digest import, upsert, identity and embedding writes)
///   triggers a gallery rebuild + `LensPipeline.setMatcher`, so a stale matcher never outlives an
///   identity change.
///
/// Because this is the only store handed to screens, no screen can bypass the ordering.
public final class ObservedStore: AppStoring {
    let base: LazyStore

    private struct WeakDelegate: Sendable {
        weak var value: (any ObservedStoreDelegate)?
    }
    private let delegateRef = Mutex(WeakDelegate())

    init(base: LazyStore) {
        self.base = base
    }

    func setDelegate(_ delegate: any ObservedStoreDelegate) {
        delegateRef.withLock { $0 = WeakDelegate(value: delegate) }
    }

    private var delegate: (any ObservedStoreDelegate)? { delegateRef.withLock { $0.value } }

    private func changed() async {
        guard let delegate else { return }
        await delegate.storeDidChangeIdentities()
    }

    /// Runs `body`, then reports an identity change whether or not it threw (a refresh is
    /// idempotent; a partial failure must not leave a stale gallery).
    private func changing<T>(_ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            await changed()
            return value
        } catch {
            await changed()
            throw error
        }
    }

    // MARK: PeopleStoring

    public func person(_ id: PersonID) async throws -> Person? { try await base.person(id) }
    public func allPeople() async throws -> [Person] { try await base.allPeople() }
    public func upsert(_ person: Person) async throws {
        try await changing { try await base.upsert(person) }
    }
    public func identities(for id: PersonID) async throws -> [Identity] { try await base.identities(for: id) }
    public func addIdentity(_ identity: Identity) async throws {
        try await changing { try await base.addIdentity(identity) }
    }
    public func person(matching kind: Identity.Kind, value: String) async throws -> Person? {
        try await base.person(matching: kind, value: value)
    }
    public func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] {
        try await base.confirmedGallery(space: space)
    }
    public func addEmbeddings(_ embeddings: [FaceEmbedding]) async throws {
        try await changing { try await base.addEmbeddings(embeddings) }
    }

    public func forget(_ id: PersonID) async throws {
        let delegate = self.delegate
        await delegate?.storeWillForget(id)
        do {
            try await base.forget(id)
        } catch {
            await delegate?.storeDidForget(id, succeeded: false)
            throw error
        }
        await delegate?.storeDidForget(id, succeeded: true)
    }

    public func latestDigest() async throws -> InteractionDigest? { try await base.latestDigest() }
    public func saveDigest(_ digest: InteractionDigest) async throws {
        try await changing { try await base.saveDigest(digest) }
    }

    // MARK: EnrollmentStoring

    public func unassignedEmbeddings(space: EmbeddingSpace) async throws -> [FaceEmbedding] {
        try await base.unassignedEmbeddings(space: space)
    }
    public func embeddings(ids: [UUID]) async throws -> [FaceEmbedding] {
        try await base.embeddings(ids: ids)
    }
    public func replaceClusters(_ clusters: [ClusterRecord]) async throws {
        try await base.replaceClusters(clusters)
    }
    public func clusters() async throws -> [ClusterRecord] { try await base.clusters() }
    public func confirm(cluster id: String, as person: PersonID) async throws {
        try await changing { try await base.confirm(cluster: id, as: person) }
    }
    public func deleteEmbeddings(ids: [UUID]) async throws {
        try await changing { try await base.deleteEmbeddings(ids: ids) }
    }
    public func removeIdentity(_ identity: Identity) async throws {
        try await changing { try await base.removeIdentity(identity) }
    }
    public func scanCursor() async throws -> String? { try await base.scanCursor() }
    public func setScanCursor(_ cursor: String?) async throws { try await base.setScanCursor(cursor) }

    // MARK: PrivacyStoring

    public func logRecognition(of id: PersonID, at date: Date) async throws {
        try await base.logRecognition(of: id, at: date)
    }
    public func recognitionLog(for id: PersonID) async throws -> [Date] {
        try await base.recognitionLog(for: id)
    }
    public var hasPendingErasure: Bool { base.hasPendingErasure }
    public func flushPendingErasure() async -> Bool { await base.flushPendingErasure() }

    public func eraseEverything() async throws {
        let delegate = self.delegate
        await delegate?.storeWillEraseEverything()
        do {
            try await base.eraseEverything()
        } catch {
            await delegate?.storeDidEraseEverything(succeeded: false)
            throw error
        }
        await delegate?.storeDidEraseEverything(succeeded: true)
    }
}

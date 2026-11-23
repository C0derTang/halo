import CoreGraphics
import Foundation
import HaloCore
import Observation

/// Resolves a face's source (PHAsset id etc.) to a thumbnail. The app supplies a PhotoKit
/// implementation; tests use a fake. Thumbnails are held in memory only (invariant 2).
public protocol FaceThumbnailProvider: Sendable {
    func thumbnail(for embedding: FaceEmbedding) async -> CGImage?
}

/// One face shown in a triage card.
public struct EnrollmentFace: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let sourceRef: String?
    public let image: CGImage?
}

/// One cluster prepared for display.
public struct EnrollmentCard: Identifiable, Sendable {
    public var cluster: ClusterRecord
    public var representative: EnrollmentFace
    /// Up to `EnrollmentViewModel.maxThumbnails` member faces.
    public var members: [EnrollmentFace]
    /// Existing person the clusterer thinks this is. A suggestion only: never applied until tapped.
    public var suggestedPerson: Person?
    public var id: String { cluster.id }
}

/// "Who is this?" triage. A person only becomes recognizable through an explicit call to one of
/// the `confirm*` / `acceptSuggestion` methods (invariant 3); suggestions are never auto-applied.
@Observable @MainActor
public final class EnrollmentViewModel {
    public static let maxThumbnails = 8

    public private(set) var cards: [EnrollmentCard] = []
    public private(set) var skippedIDs: Set<String> = []
    public private(set) var isLoading = false
    public var errorMessage: String?

    private let store: any EnrollmentStoring & PeopleStoring
    private let thumbnails: any FaceThumbnailProvider

    public init(store: any EnrollmentStoring & PeopleStoring, thumbnails: any FaceThumbnailProvider) {
        self.store = store
        self.thumbnails = thumbnails
    }

    // MARK: Derived state

    /// Cards still awaiting a decision, i.e. not skipped.
    public var pending: [EnrollmentCard] { cards.filter { !skippedIDs.contains($0.id) } }
    public var current: EnrollmentCard? { pending.first }
    /// "12 left" count.
    public var remaining: Int { pending.count }
    public var skippedCount: Int { cards.count - remaining }
    public var progressText: String { "\(remaining) left" }

    // MARK: Loading

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let records = try await store.clusters()
            var built: [EnrollmentCard] = []
            for record in records {
                if let card = try await makeCard(record) { built.append(card) }
            }
            cards = built
            skippedIDs = skippedIDs.intersection(Set(built.map(\.id)))
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load suggestions."
        }
    }

    private func makeCard(_ record: ClusterRecord) async throws -> EnrollmentCard? {
        // Members deleted since the cluster was written (rejects, forget) are silently dropped.
        let found = try await store.embeddings(ids: record.memberIDs)
        guard !found.isEmpty else { return nil }
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = record.memberIDs.compactMap { byID[$0] }
        guard let first = ordered.first else { return nil }
        let rep = byID[record.representativeID] ?? first
        var live = record
        live.memberIDs = ordered.map(\.id)
        live.representativeID = rep.id

        let repFace = await face(rep)
        var memberFaces: [EnrollmentFace] = []
        for e in ordered.prefix(Self.maxThumbnails) {
            memberFaces.append(e.id == rep.id ? repFace : await face(e))
        }
        var suggested: Person?
        if let pid = record.suggestedPersonID { suggested = try await store.person(pid) }
        return EnrollmentCard(
            cluster: live, representative: repFace, members: memberFaces, suggestedPerson: suggested)
    }

    private func face(_ e: FaceEmbedding) async -> EnrollmentFace {
        EnrollmentFace(id: e.id, sourceRef: e.sourceRef, image: await thumbnails.thumbnail(for: e))
    }

    // MARK: People search

    /// Existing people (e.g. imported from Contacts) whose name contains `query`.
    public func searchPeople(_ query: String) async -> [Person] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let all = try? await store.allPeople() else { return [] }
        let hits = q.isEmpty ? all : all.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
        return hits.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: Actions

    /// "This is..." an existing person. Calls the store's `confirm` exactly once.
    @discardableResult
    public func confirm(_ card: EnrollmentCard, as person: Person) async -> Bool {
        await confirm(card, asID: person.id)
    }

    /// Explicit tap on the suggestion chip. Without this call the suggestion is never applied.
    @discardableResult
    public func acceptSuggestion(for card: EnrollmentCard) async -> Bool {
        guard let id = card.cluster.suggestedPersonID else { return false }
        return await confirm(card, asID: id)
    }

    /// "This is..." a new person by name.
    @discardableResult
    public func confirmNewPerson(named name: String, for card: EnrollmentCard) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Created unconfirmed: the store's `confirm` is what makes them recognizable.
        let person = Person(displayName: trimmed, confirmed: false)
        do {
            try await store.upsert(person)
        } catch {
            errorMessage = "Couldn't save this person."
            return false
        }
        if await confirm(card, asID: person.id) { return true }
        try? await store.forget(person.id)  // don't leave an orphan person behind
        return false
    }

    private func confirm(_ card: EnrollmentCard, asID id: PersonID) async -> Bool {
        do {
            try await store.confirm(cluster: card.cluster.id, as: id)
            remove(cluster: card.id)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Couldn't confirm this person."
            return false
        }
    }

    /// "Not the same person": deletes exactly these embeddings, keeps the rest of the cluster.
    @discardableResult
    public func reject(faces ids: [UUID], from card: EnrollmentCard) async -> Bool {
        let own = Set(card.cluster.memberIDs)
        let toDelete = ids.filter { own.contains($0) }
        guard !toDelete.isEmpty else { return false }
        do {
            try await store.deleteEmbeddings(ids: toDelete)
        } catch {
            errorMessage = "Couldn't remove those faces."
            return false
        }
        errorMessage = nil
        let gone = Set(toDelete)
        guard let i = cards.firstIndex(where: { $0.id == card.id }) else { return true }
        var c = cards[i]
        c.cluster.memberIDs.removeAll { gone.contains($0) }
        c.members.removeAll { gone.contains($0.id) }
        guard let newRep = c.cluster.memberIDs.first else {
            remove(cluster: c.id)
            return true
        }
        if gone.contains(c.cluster.representativeID) {
            c.cluster.representativeID = newRep
            if let f = c.members.first(where: { $0.id == newRep }) {
                c.representative = f
            } else if let e = try? await store.embeddings(ids: [newRep]).first {
                c.representative = await face(e)
            }
        }
        if let j = cards.firstIndex(where: { $0.id == c.id }) { cards[j] = c }
        return true
    }

    /// Leave for later; nothing is written.
    public func skip(_ card: EnrollmentCard) {
        guard cards.contains(where: { $0.id == card.id }) else { return }
        skippedIDs.insert(card.id)
    }

    /// Bring skipped clusters back into the queue.
    public func reviewSkipped() { skippedIDs.removeAll() }

    /// "Never suggest": delete every member embedding of the cluster.
    @discardableResult
    public func neverSuggest(_ card: EnrollmentCard) async -> Bool {
        do {
            try await store.deleteEmbeddings(ids: card.cluster.memberIDs)
        } catch {
            errorMessage = "Couldn't remove this suggestion."
            return false
        }
        errorMessage = nil
        remove(cluster: card.id)
        return true
    }

    private func remove(cluster id: String) {
        cards.removeAll { $0.id == id }
        skippedIDs.remove(id)
    }
}

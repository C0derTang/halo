import Foundation
import HaloCore
import Observation

/// One row of the People list.
public struct PeopleRow: Identifiable, Hashable, Sendable {
    public var person: Person
    /// Latest interaction from the digest, if any identity matched a digest entry.
    public var lastInteraction: Date?
    public var id: PersonID { person.id }
}

/// People tab list: confirmed people, search, sort, and the "Needs review" count.
@Observable @MainActor
public final class PeopleListModel {
    public enum Sort: String, CaseIterable, Sendable {
        case lastInteraction, name
    }

    public private(set) var allRows: [PeopleRow] = []
    /// Pending cluster suggestions awaiting triage (imported contacts are unconfirmed but not counted).
    public private(set) var needsReviewCount = 0
    public private(set) var errorMessage: String?
    public var searchText = ""
    public var sort: Sort = .lastInteraction

    @ObservationIgnored private let store: any PeopleStoring & EnrollmentStoring

    @ObservationIgnored private let normalize: @Sendable (String) -> String

    /// - Parameter normalize: handle normalizer; pass the same one the label ranker uses
    ///   (`HandleNormalizer.normalize`). Default only trims and lowercases.
    public init(
        store: any PeopleStoring & EnrollmentStoring,
        normalize: @escaping @Sendable (String) -> String = {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    ) {
        self.store = store
        self.normalize = normalize
    }

    /// Confirmed people only (unconfirmed are never recognizable), filtered by search and sorted.
    public var rows: [PeopleRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered =
            query.isEmpty
            ? allRows : allRows.filter { $0.person.displayName.localizedCaseInsensitiveContains(query) }
        return filtered.sorted(by: Self.comparator(sort))
    }

    static func comparator(_ sort: Sort) -> (PeopleRow, PeopleRow) -> Bool {
        let byName: (PeopleRow, PeopleRow) -> Bool = {
            let order = $0.person.displayName.localizedCaseInsensitiveCompare($1.person.displayName)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.id.description < $1.id.description
        }
        switch sort {
        case .name: return byName
        case .lastInteraction:
            return { a, b in
                switch (a.lastInteraction, b.lastInteraction) {
                case (let x?, let y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return byName(a, b)
                }
            }
        }
    }

    public func load() async {
        do {
            let people = try await store.allPeople()
            let digest = try await store.latestDigest()
            var rows: [PeopleRow] = []
            for person in people where person.confirmed {
                let identities = try await store.identities(for: person.id)
                rows.append(
                    PeopleRow(
                        person: person, lastInteraction: lastInteraction(identities, digest)))
            }
            allRows = rows
            needsReviewCount = try await store.clusters().count
            errorMessage = nil
        } catch {
            errorMessage = "Could not load people."
        }
    }

    func lastInteraction(_ identities: [Identity], _ digest: InteractionDigest?) -> Date? {
        guard let digest else { return nil }
        let handles = Set(
            identities.filter { $0.kind == .phone || $0.kind == .email || $0.kind == .imessageHandle }
                .map { normalize($0.value) })
        return digest.entries.filter { handles.contains(normalize($0.handle)) }
            .compactMap(\.lastMessageAt).max()
    }
}

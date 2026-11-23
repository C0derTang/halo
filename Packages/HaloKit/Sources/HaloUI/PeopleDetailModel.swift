import CoreGraphics
import Foundation
import HaloCore
import Observation

/// One face thumbnail on the detail screen. In-memory only (invariant 2).
public struct PersonFace: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let image: CGImage?
}

@Observable @MainActor
public final class PersonDetailModel {
    public static let maxThumbnails = 12

    public let personID: PersonID
    public private(set) var person: Person?
    public private(set) var identities: [Identity] = []
    /// Exactly what the lens would show for this person right now.
    public private(set) var labelPreview: LabelData?
    public private(set) var faceCount = 0
    public private(set) var faces: [PersonFace] = []
    /// Most recent first.
    public private(set) var recognitions: [Date] = []
    public private(set) var errorMessage: String?
    public private(set) var isForgetting = false
    public private(set) var didForget = false

    @ObservationIgnored private let store: any PeopleStoring & PrivacyStoring
    @ObservationIgnored private let thumbnails: any FaceThumbnailProvider
    @ObservationIgnored private let ranker: any LabelRanking
    @ObservationIgnored private let space: EmbeddingSpace
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let forgetAction: @Sendable (Person) async -> Bool

    /// - Parameters:
    ///   - ranker: the same `LabelRanking` instance the lens uses.
    ///   - forget: the single forget path, i.e. `PrivacySettingsViewModel.confirmForget(_:)`.
    ///     This model never calls `store.forget` itself.
    public init(
        personID: PersonID, store: any PeopleStoring & PrivacyStoring,
        thumbnails: any FaceThumbnailProvider, ranker: any LabelRanking, space: EmbeddingSpace,
        now: @escaping @Sendable () -> Date = { Date() },
        forget: @escaping @Sendable (Person) async -> Bool
    ) {
        self.personID = personID
        self.store = store
        self.thumbnails = thumbnails
        self.ranker = ranker
        self.space = space
        self.now = now
        self.forgetAction = forget
    }

    public func load() async {
        do {
            guard let person = try await store.person(personID) else {
                self.person = nil
                labelPreview = nil
                return
            }
            let identities = try await store.identities(for: personID)
            let digest = try await store.latestDigest()
            let gallery = try await store.confirmedGallery(space: space).filter { $0.personID == personID }
            let log = try await store.recognitionLog(for: personID)
            self.person = person
            self.identities = identities
            labelPreview = ranker.label(for: person, identities: identities, digest: digest, now: now())
            faceCount = gallery.count
            var thumbs: [PersonFace] = []
            for embedding in gallery.prefix(Self.maxThumbnails) {
                thumbs.append(PersonFace(id: embedding.id, image: await thumbnails.thumbnail(for: embedding)))
            }
            faces = thumbs
            recognitions = log.sorted(by: >)
            errorMessage = nil
        } catch {
            errorMessage = "Could not load this person."
        }
    }

    /// Edits name and relationship only. Re-reads the stored person so `confirmed` (and every
    /// other field) is carried over untouched; editing never toggles `confirmed`.
    @discardableResult
    public func save(name: String, relationship: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Name can't be empty."
            return false
        }
        let rel = relationship.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard var current = try await store.person(personID) else { return false }
            current.displayName = trimmed
            current.relationship = rel.isEmpty ? nil : rel
            current.updatedAt = now()
            try await store.upsert(current)
            await load()
            return true
        } catch {
            errorMessage = "Could not save changes."
            return false
        }
    }

    /// Runs the injected forget closure at most once; later calls are no-ops.
    @discardableResult
    public func confirmForget() async -> Bool {
        guard !isForgetting, !didForget, let person else { return false }
        isForgetting = true
        defer { isForgetting = false }
        let ok = await forgetAction(person)
        if ok {
            didForget = true
            self.person = nil
            labelPreview = nil
            faces = []
            faceCount = 0
            recognitions = []
            identities = []
        } else {
            errorMessage = "Could not forget \(person.displayName)."
        }
        return ok
    }
}

import Foundation
import HaloCore
import Observation

/// A person who can be tagged in a Moment: currently recognized in the lens.
public struct MomentsPerson: Hashable, Sendable, Identifiable {
    public var id: PersonID
    public var displayName: String
    /// Only confirmed people may be tagged (invariant 3). Unconfirmed entries are dropped.
    public var isConfirmed: Bool

    public init(id: PersonID, displayName: String, isConfirmed: Bool) {
        self.id = id
        self.displayName = displayName
        self.isConfirmed = isConfirmed
    }
}

/// On-device dictation. Implementations MUST recognize on device only (never over the network);
/// when that is not supported, `isOnDeviceAvailable` is false and the UI hides dictation.
public protocol SpeechTranscribing: Sendable {
    /// True only when on-device recognition is supported right now.
    var isOnDeviceAvailable: Bool { get async }
    /// Starts listening and yields the full transcript so far. Cancelling the consuming task, or
    /// ending iteration, stops listening. Throws on permission denial or recognition failure.
    func transcribe() -> AsyncThrowingStream<String, Error>
}

/// Sanitizes a note; returns the text to store, or nil to reject. Injected by the caller so the
/// HaloMemory sensitive-content and contact/link policy applies without HaloUI importing it.
public typealias MomentsSanitizer = @Sendable (String) -> String?

/// Quick note about the people currently in view. Text only; no images are ever stored.
@Observable @MainActor
public final class MomentsModel {
    public static let maxLength = 140

    public let people: [MomentsPerson]
    public private(set) var selected: Set<PersonID> = []
    public private(set) var text = ""
    public private(set) var isDictating = false
    /// Whether the dictation button is shown. False until `prepareDictation()` confirms on-device.
    public private(set) var isDictationAvailable = false
    public private(set) var isSaving = false
    public private(set) var didSave = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private let store: any MemoryStoring
    @ObservationIgnored private let speech: (any SpeechTranscribing)?
    @ObservationIgnored private let sanitize: MomentsSanitizer
    @ObservationIgnored private let verifyConfirmed: (@Sendable (PersonID) async -> Bool)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var dictationTask: Task<Void, Never>?
    @ObservationIgnored private var dictationBase = ""
    @ObservationIgnored private var dictationToken = 0
    /// People already written by an earlier (partially failed) save: a retry never duplicates them.
    @ObservationIgnored private var savedIDs: Set<PersonID> = []

    /// - Parameter verifyConfirmed: optional live re-check at save time (e.g. the person may have
    ///   been forgotten while the sheet was open). Persons failing it are never written.
    public init(
        people: [MomentsPerson], store: any MemoryStoring, speech: (any SpeechTranscribing)? = nil,
        sanitize: @escaping MomentsSanitizer,
        verifyConfirmed: (@Sendable (PersonID) async -> Bool)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        var seen: Set<PersonID> = []
        let eligible = people.filter { $0.isConfirmed && seen.insert($0.id).inserted }
        self.people = eligible
        self.store = store
        self.speech = speech
        self.sanitize = sanitize
        self.verifyConfirmed = verifyConfirmed
        self.now = now
        // One recognized person: preselect for one-handed speed.
        if eligible.count == 1 { selected = [eligible[0].id] }
    }

    // MARK: Derived

    public var remaining: Int { Self.maxLength - text.count }
    public var canSave: Bool {
        !isSaving && !selected.isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func isSelected(_ id: PersonID) -> Bool { selected.contains(id) }

    // MARK: Editing

    /// Ignores ids that are not currently recognized, confirmed people.
    public func toggle(_ id: PersonID) {
        guard people.contains(where: { $0.id == id }) else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// Clamps to `maxLength` characters.
    public func setText(_ newValue: String) {
        if newValue != text { savedIDs.removeAll() }
        text = newValue.count > Self.maxLength ? String(newValue.prefix(Self.maxLength)) : newValue
    }

    // MARK: Dictation

    public func prepareDictation() async {
        guard let speech else {
            isDictationAvailable = false
            return
        }
        isDictationAvailable = await speech.isOnDeviceAvailable
    }

    public func toggleDictation() {
        if isDictating { stopDictation() } else { startDictation() }
    }

    public func startDictation() {
        guard isDictationAvailable, let speech, !isDictating else { return }
        isDictating = true
        errorMessage = nil
        dictationBase = text.isEmpty || text.hasSuffix(" ") ? text : text + " "
        dictationToken += 1
        let token = dictationToken
        dictationTask = Task { [weak self] in
            do {
                for try await partial in speech.transcribe() {
                    guard let self, self.dictationToken == token else { return }
                    self.setText(self.dictationBase + partial)
                }
            } catch is CancellationError {
            } catch {
                if let self, self.dictationToken == token { self.errorMessage = "Dictation stopped." }
            }
            // A stale session must not flip the flag of a newer one.
            if let self, self.dictationToken == token { self.isDictating = false }
        }
    }

    /// Cancels the dictation task immediately; cancelling the consumer terminates the stream, which
    /// stops the microphone. Late partials from the old session are ignored via the token.
    public func stopDictation() {
        dictationToken += 1
        dictationTask?.cancel()
        dictationTask = nil
        isDictating = false
    }

    // MARK: Save

    /// Writes one `.moment` hook per selected person. Returns true when all were stored.
    @discardableResult
    public func save() async -> Bool {
        stopDictation()
        guard canSave else { return false }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let clean = sanitize(collapsed), !clean.isEmpty, clean.count <= Self.maxLength else {
            errorMessage = "This note can't be saved. Try different wording."
            return false
        }
        isSaving = true
        defer { isSaving = false }
        let created = now()
        var failed = false
        for person in people where selected.contains(person.id) && !savedIDs.contains(person.id) {
            if let verifyConfirmed, !(await verifyConfirmed(person.id)) {
                failed = true
                continue
            }
            let hook = MemoryHook(personID: person.id, text: clean, source: .moment, createdAt: created)
            do {
                try await store.addHook(hook)
                savedIDs.insert(person.id)
            } catch { failed = true }
        }
        if failed {
            errorMessage = "Could not save for everyone."
            return false
        }
        errorMessage = nil
        didSave = true
        return true
    }
}

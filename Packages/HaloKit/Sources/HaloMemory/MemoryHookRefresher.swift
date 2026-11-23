import CryptoKit
import Foundation
import HaloCore

/// What one `MemoryHookRefresher.refresh(now:)` call did.
public enum MemoryRefreshOutcome: Equatable, Sendable {
    /// The on-device model is unavailable: nothing was read or written.
    case modelUnavailable
    /// Called again within `minimumInterval` of the last completed run: nothing was done.
    case rateLimited
    /// Another refresh is still running on this refresher: nothing was done.
    case alreadyRunning
    /// No digest has been imported yet: nothing was done.
    case noDigest
    case completed(MemoryRefreshReport)
}

public struct MemoryRefreshReport: Equatable, Sendable {
    /// People whose `.onDeviceSummary` hooks were replaced with freshly generated ones.
    public var regenerated: Set<PersonID> = []
    /// People whose summary hooks were cleared because they have no message excerpts any more.
    public var cleared: Set<PersonID> = []
    /// People whose generation failed; retried on the next run.
    public var failed: Set<PersonID> = []
    /// People skipped because the per-run generation cap was reached; picked up on the next run.
    public var deferred: Set<PersonID> = []

    public init() {}
}

/// Keeps `.onDeviceSummary` memory hooks in step with the latest interaction digest.
///
/// - Only CONFIRMED people get hooks (invariant 3). Unconfirmed people are never sent to the model.
/// - A person is regenerated only when the hash of their input (name + excerpts) changed since the
///   last successful run. Hashes live in memory only.
/// - Rate limited (`minimumInterval` between completed runs, `maxGenerationsPerRun` model calls per
///   run), cancellable (honours task cancellation between people and never writes after it), and
///   isolated to this actor, so it never runs on the main actor.
/// - Invariant 6: excerpts go only to the injected on-device generator; nothing is logged.
public actor MemoryHookRefresher {
    public static let defaultMinimumInterval: TimeInterval = 15 * 60
    public static let defaultMaxGenerationsPerRun = 8

    private let store: any MemoryStoring & PeopleStoring
    private let generator: any MemoryHookGenerating
    private let minimumInterval: TimeInterval
    private let maxGenerationsPerRun: Int
    private let normalizeHandle: @Sendable (String) -> String

    private var inputHashes: [PersonID: String] = [:]
    private var lastCompletedRun: Date?
    private var isRunning = false

    /// - Parameter normalizeHandle: MUST be the normalizer the importer used for identity values
    ///   (the app passes `HandleNormalizer(region:).normalize`), otherwise handles will not match.
    ///   The default only trims and lowercases, so it under-matches rather than misattributes.
    public init(
        store: any MemoryStoring & PeopleStoring,
        generator: any MemoryHookGenerating,
        minimumInterval: TimeInterval = MemoryHookRefresher.defaultMinimumInterval,
        maxGenerationsPerRun: Int = MemoryHookRefresher.defaultMaxGenerationsPerRun,
        normalizeHandle: @escaping @Sendable (String) -> String = MemoryHookRefresher.basicNormalize
    ) {
        self.store = store
        self.generator = generator
        self.minimumInterval = minimumInterval
        self.maxGenerationsPerRun = max(0, maxGenerationsPerRun)
        self.normalizeHandle = normalizeHandle
    }

    @Sendable public static func basicNormalize(_ handle: String) -> String {
        handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Runs one refresh pass. Throws `CancellationError` if the calling task is cancelled; nothing
    /// is written for the person being processed when cancellation is observed.
    public func refresh(now: Date = Date()) async throws -> MemoryRefreshOutcome {
        guard !isRunning else { return .alreadyRunning }
        if let last = lastCompletedRun, now >= last, now.timeIntervalSince(last) < minimumInterval {
            return .rateLimited
        }
        isRunning = true
        defer { isRunning = false }

        try Task.checkCancellation()
        guard await generator.isAvailable else { return .modelUnavailable }
        guard let digest = try await store.latestDigest() else { return .noDigest }

        let people = try await store.allPeople()
        let excerpts = try await excerptsByConfirmedPerson(people: people, digest: digest)
        let confirmed = people.filter(\.confirmed).sorted {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }

        // Forgotten or unconfirmed people must not keep a cached hash.
        let confirmedIDs = Set(confirmed.map(\.id))
        inputHashes = inputHashes.filter { confirmedIDs.contains($0.key) }

        var report = MemoryRefreshReport()
        var generations = 0
        for person in confirmed {
            try Task.checkCancellation()
            let messages = excerpts[person.id] ?? []
            let hash = Self.inputHash(person: person, messages: messages)
            guard inputHashes[person.id] != hash else { continue }

            if messages.isEmpty {
                try await store.replaceHooks(for: person.id, source: .onDeviceSummary, with: [])
                inputHashes[person.id] = hash
                report.cleared.insert(person.id)
                continue
            }
            guard generations < maxGenerationsPerRun else {
                report.deferred.insert(person.id)
                continue
            }
            generations += 1

            let generated: [MemoryHook]
            do {
                generated = try await generator.hooks(for: person, messages: messages, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Not logged (the error may describe message content); retried next run.
                try Task.checkCancellation()
                report.failed.insert(person.id)
                continue
            }
            try Task.checkCancellation()
            // The model may have become unavailable mid-run: never wipe hooks because of that.
            if generated.isEmpty, await !generator.isAvailable {
                report.failed.insert(person.id)
                continue
            }

            // Re-apply the policy whatever the generator returned.
            let hooks = MemoryHookPolicy.makeHooks(for: person.id, texts: generated.map(\.text), now: now)
            try await store.replaceHooks(for: person.id, source: .onDeviceSummary, with: hooks)
            inputHashes[person.id] = hash
            report.regenerated.insert(person.id)
        }

        lastCompletedRun = now
        return .completed(report)
    }

    // MARK: Attribution

    /// Message excerpts per confirmed person, newest first. A digest entry is attributed only when
    /// its normalized handle equals one of that person's phone/email/iMessage identities AND no other
    /// person claims the same handle (a shared handle is dropped rather than guessed).
    private func excerptsByConfirmedPerson(people: [Person], digest: InteractionDigest) async throws
        -> [PersonID: [InteractionDigest.DigestMessage]]
    {
        let entries = digest.entries.filter { !($0.recentMessages ?? []).isEmpty }
        guard !entries.isEmpty else { return [:] }

        let handleKinds: Set<Identity.Kind> = [.phone, .email, .imessageHandle]
        var owners: [String: Set<PersonID>] = [:]
        for person in people {
            try Task.checkCancellation()
            for identity in try await store.identities(for: person.id)
            where handleKinds.contains(identity.kind) && identity.personID == person.id {
                let key = normalizeHandle(identity.value)
                guard !key.isEmpty else { continue }
                owners[key, default: []].insert(person.id)
            }
        }
        let confirmedIDs = Set(people.filter(\.confirmed).map(\.id))

        var result: [PersonID: [InteractionDigest.DigestMessage]] = [:]
        for entry in entries {
            let key = normalizeHandle(entry.handle)
            guard !key.isEmpty, let claimants = owners[key], claimants.count == 1,
                let owner = claimants.first, confirmedIDs.contains(owner)
            else { continue }
            result[owner, default: []].append(contentsOf: entry.recentMessages ?? [])
        }
        for (id, messages) in result {
            result[id] = Array(Set(messages)).sorted {
                $0.date != $1.date
                    ? $0.date > $1.date : ($0.fromMe ? 0 : 1, $0.text) < ($1.fromMe ? 0 : 1, $1.text)
            }
        }
        return result
    }

    // MARK: Change detection

    /// SHA-256 over everything the generator sees. Kept in memory only, never persisted or logged.
    static func inputHash(person: Person, messages: [InteractionDigest.DigestMessage]) -> String {
        var hasher = SHA256()
        func feed(_ string: String) {
            let data = Data(string.utf8)
            hasher.update(data: Data("\(data.count):".utf8))  // length prefix: no ambiguity
            hasher.update(data: data)
        }
        feed("halo.memory.v1")
        feed(person.displayName)
        for message in messages {
            feed(String(message.date.timeIntervalSince1970.bitPattern))
            feed(message.fromMe ? "1" : "0")
            feed(message.text)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

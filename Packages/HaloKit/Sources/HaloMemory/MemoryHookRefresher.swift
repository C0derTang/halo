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
    /// People whose summary hooks were cleared: no message excerpts any more, or no longer confirmed.
    public var cleared: Set<PersonID> = []
    /// People whose generation failed this run; retried after `MemoryHookRefresher.failureBackoff`.
    public var failed: Set<PersonID> = []
    /// People skipped because an earlier failure's backoff has not elapsed yet.
    public var backingOff: Set<PersonID> = []
    /// People skipped because the per-run generation cap was reached; picked up on the next run.
    public var deferred: Set<PersonID> = []

    public init() {}
}

/// Keeps `.onDeviceSummary` memory hooks in step with the latest interaction digest.
///
/// - Only CONFIRMED people get hooks (invariant 3). Unconfirmed people are never sent to the model,
///   and a person who stops being confirmed has their `.onDeviceSummary` hooks cleared.
/// - A person is regenerated only when the hash of their input (name + excerpts) changed since the
///   last successful run. Hashes live in memory only.
/// - Rate limited (`minimumInterval` between completed runs, `maxGenerationsPerRun` model calls per
///   run, per-person exponential backoff after failures, with never-tried people served before
///   recently failed ones), cancellable (honours task cancellation between people and never writes after it), and
///   isolated to this actor, so it never runs on the main actor.
/// - Invariant 6: excerpts go only to the injected on-device generator; nothing is logged.
public actor MemoryHookRefresher {
    public static let defaultMinimumInterval: TimeInterval = 15 * 60
    public static let defaultMaxGenerationsPerRun = 8
    /// Wait before retrying a person after their 1st, 2nd, 3rd+ consecutive generation failure.
    public static let failureBackoff: [TimeInterval] = [60 * 60, 6 * 60 * 60, 24 * 60 * 60]

    private let store: any MemoryStoring & PeopleStoring
    private let generator: any MemoryHookGenerating
    private let minimumInterval: TimeInterval
    private let maxGenerationsPerRun: Int
    private let normalizeHandle: @Sendable (String) -> String

    private var inputHashes: [PersonID: String] = [:]
    private var lastCompletedRun: Date?
    private var isRunning = false
    /// Who was confirmed when the unconfirmed sweep last completed; nil until the first sweep (so the
    /// first run after launch sweeps everyone). Memory only.
    private var confirmedAtLastSweep: Set<PersonID>?
    /// Consecutive generation failures per person and when they may be retried. Memory only.
    private var failures: [PersonID: (count: Int, retryAfter: Date)] = [:]

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

        // Forgotten or unconfirmed people must not keep cached state.
        let confirmedIDs = Set(confirmed.map(\.id))
        inputHashes = inputHashes.filter { confirmedIDs.contains($0.key) }
        failures = failures.filter { confirmedIDs.contains($0.key) }

        var report = MemoryRefreshReport()

        // A person who is no longer confirmed loses their generated hooks (invariant 3). The first run
        // after launch sweeps every unconfirmed person; later runs only those who were confirmed at
        // the last sweep (anyone else cannot have gained generated hooks since).
        let sweepCandidates = people.filter {
            !$0.confirmed && (confirmedAtLastSweep?.contains($0.id) ?? true)
        }
        for person in sweepCandidates {
            try Task.checkCancellation()
            let existing = try await store.hooks(for: person.id, now: now)
            guard existing.contains(where: { $0.source == .onDeviceSummary }) else { continue }
            try await store.replaceHooks(for: person.id, source: .onDeviceSummary, with: [])
            report.cleared.insert(person.id)
        }

        confirmedAtLastSweep = confirmedIDs

        var pending: [(person: Person, messages: [InteractionDigest.DigestMessage], hash: String)] = []
        for person in confirmed {
            try Task.checkCancellation()
            let messages = excerpts[person.id] ?? []
            let hash = Self.inputHash(person: person, messages: messages)
            guard inputHashes[person.id] != hash else { continue }

            if messages.isEmpty {
                try await store.replaceHooks(for: person.id, source: .onDeviceSummary, with: [])
                inputHashes[person.id] = hash
                failures[person.id] = nil
                report.cleared.insert(person.id)
                continue
            }
            if let failure = failures[person.id], now < failure.retryAfter {
                report.backingOff.insert(person.id)
                continue
            }
            pending.append((person, messages, hash))
        }

        // Never-tried / deferred people go first, then previously failed ones (longest-expired
        // backoff first), so persistently failing people cannot starve everyone else.
        pending.sort { a, b in
            let ra = failures[a.person.id]?.retryAfter ?? .distantPast
            let rb = failures[b.person.id]?.retryAfter ?? .distantPast
            return ra != rb ? ra < rb : a.person.id.rawValue.uuidString < b.person.id.rawValue.uuidString
        }

        var generations = 0
        for (person, messages, hash) in pending {
            try Task.checkCancellation()
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
                // Not logged (the error may describe message content); retried after a backoff.
                try Task.checkCancellation()
                recordFailure(person.id, now: now)
                report.failed.insert(person.id)
                continue
            }
            try Task.checkCancellation()
            // The model may have become unavailable mid-run: never wipe hooks because of that. Stop
            // without recording a failure (no backoff) and without counting the run for rate limiting,
            // so the remaining people are retried as soon as the model is back.
            if generated.isEmpty, await !generator.isAvailable {
                return .completed(report)
            }

            // Re-apply the policy whatever the generator returned.
            let hooks = MemoryHookPolicy.makeHooks(for: person.id, texts: generated.map(\.text), now: now)
            try await store.replaceHooks(for: person.id, source: .onDeviceSummary, with: hooks)
            inputHashes[person.id] = hash
            failures[person.id] = nil
            report.regenerated.insert(person.id)
        }

        lastCompletedRun = now
        return .completed(report)
    }

    private func recordFailure(_ id: PersonID, now: Date) {
        let count = (failures[id]?.count ?? 0) + 1
        let delay = Self.failureBackoff[min(count, Self.failureBackoff.count) - 1]
        failures[id] = (count, now.addingTimeInterval(delay))
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

import Foundation
import HaloCore
import HaloMemory

/// A generator for builds without the on-device model: reports unavailable, generates nothing.
public struct UnavailableHookGenerator: MemoryHookGenerating {
    public init() {}
    public var isAvailable: Bool { false }
    public func hooks(for person: Person, messages: [InteractionDigest.DigestMessage], now: Date)
        async throws -> [MemoryHook]
    { [] }
}

// MARK: - Memory hooks

/// The memory hook refresher is a WRITER (invariants 3 + 6):
/// - it runs on its own actor (never the main actor), after each successful digest import and on
///   every `.active` (it rate-limits itself);
/// - it never starts while a forget / erase runs, and forget and the kill switch cancel it and wait
///   until it has stopped writing before anything is deleted;
/// - message excerpts go only to the injected on-device generator; nothing is logged.
extension AppEnvironment {
    /// The person's unexpired memory hooks, for labels. Empty when unreadable.
    public func hooks(for person: PersonID, now: Date = Date()) async -> [MemoryHook] {
        (try? await store.hooks(for: person, now: now)) ?? []
    }

    /// Hook reader handed to the lens and person detail models.
    nonisolated static func hookReader(_ store: any MemoryStoring)
        -> @Sendable (PersonID, Date) async -> [MemoryHook]
    {
        { person, now in (try? await store.hooks(for: person, now: now)) ?? [] }
    }

    /// Starts a refresh pass unless one is running (then one more runs after it) or a forget /
    /// erase is in progress. Returns the running pass, if any.
    @discardableResult
    func refreshMemoryHooks() -> Task<Void, Never>? {
        if let memoryTask {
            memoryRefreshPending = true
            return memoryTask
        }
        guard destructiveOperations == 0, isStoreAvailable else { return nil }
        let refresher = memoryRefresher
        memoryRunID += 1
        let runID = memoryRunID
        let task = Task { [weak self] in
            // Runs on the refresher's actor; only the outcome comes back to the main actor.
            let outcome = try? await refresher.refresh(now: Date())
            self?.memoryRefreshEnded(runID: runID, outcome)
        }
        memoryTask = task
        return task
    }

    private func memoryRefreshEnded(runID: Int, _ outcome: MemoryRefreshOutcome?) {
        guard runID == memoryRunID else { return }
        memoryTask = nil
        switch outcome {
        case .completed(let report)? where !report.regenerated.isEmpty || !report.cleared.isEmpty:
            hooksDidChange()
        case nil:
            // Cancelled or failed part-way: some hooks may already have been replaced.
            hooksDidChange()
        default:
            break
        }
        if memoryRefreshPending {
            memoryRefreshPending = false
            refreshMemoryHooks()
        }
    }

    /// Forget / kill switch: cancels the running pass and waits until it has stopped writing.
    func stopMemoryRefresh() async {
        memoryRefreshPending = false
        guard let task = memoryTask else { return }
        task.cancel()
        await task.value
    }

    /// Hooks changed (refresh, Moment, note): rebuild the labels on screen; screens reload.
    func hooksDidChange() {
        lens?.refreshLabels()
        peopleRevision += 1
    }
}

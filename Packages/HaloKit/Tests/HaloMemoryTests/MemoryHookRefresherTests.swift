import Foundation
import HaloCore
import Testing

@testable import HaloMemory

@Suite struct MemoryHookRefresherTests {
    let t0 = Fixture.t0

    /// Confirmed Ana (+15550000001) and unconfirmed Ben (+15550000002), both with excerpts.
    func makeWorld(available: Bool = true, texts: [String] = ["Started a new job at Acme"]) async
        -> (FakeMemoryStore, FakeHookGenerator, Person, Person)
    {
        let store = FakeMemoryStore()
        let ana = Person(displayName: "Ana", confirmed: true)
        let ben = Person(displayName: "Ben", confirmed: false)
        await store.seed(ana, handles: [(.phone, "+15550000001")])
        await store.seed(ben, handles: [(.phone, "+15550000002")])
        await store.setDigest(
            Fixture.digest([
                Fixture.entry("+15550000001", [Fixture.message("I start at Acme on Monday!")]),
                Fixture.entry("+15550000002", [Fixture.message("Back from Lisbon")]),
            ]))
        return (store, FakeHookGenerator(available: available, texts: texts), ana, ben)
    }

    func report(_ outcome: MemoryRefreshOutcome) throws -> MemoryRefreshReport {
        guard case .completed(let report) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            throw FakeGenerationError()
        }
        return report
    }

    // MARK: Invariant: only confirmed people

    @Test func onlyConfirmedPeopleGetHooks() async throws {
        let (store, generator, ana, ben) = await makeWorld()
        let refresher = MemoryHookRefresher(store: store, generator: generator)

        let report = try report(try await refresher.refresh(now: t0))

        #expect(report.regenerated == [ana.id])
        #expect(await generator.askedAbout == [ana.id])
        #expect(await store.allHooks(for: ana.id).map(\.text) == ["Started a new job at Acme"])
        #expect(await store.allHooks(for: ben.id).isEmpty)
        #expect(await !store.replaceCalls.contains(ben.id))
    }

    @Test func personWhoBecomesConfirmedIsPickedUpNextRun() async throws {
        let (store, generator, _, ben) = await makeWorld()
        let refresher = MemoryHookRefresher(store: store, generator: generator, minimumInterval: 0)
        _ = try await refresher.refresh(now: t0)
        #expect(await !generator.askedAbout.contains(ben.id))

        await store.setConfirmed(ben.id, true)
        let report = try report(try await refresher.refresh(now: t0.addingTimeInterval(1)))
        #expect(report.regenerated == [ben.id])
    }

    @Test func excerptsAreAttributedOnlyToTheHandleOwner() async throws {
        let (store, generator, ana, _) = await makeWorld()
        let refresher = MemoryHookRefresher(store: store, generator: generator)
        _ = try await refresher.refresh(now: t0)

        let calls = await generator.calls
        #expect(calls.count == 1)
        #expect(calls.first?.messages.map(\.text) == ["I start at Acme on Monday!"])
        #expect(calls.first?.person == ana.id)
    }

    @Test func sharedHandleIsDroppedNotGuessed() async throws {
        let store = FakeMemoryStore()
        let ana = Person(displayName: "Ana", confirmed: true)
        let cam = Person(displayName: "Cam", confirmed: false)
        await store.seed(ana, handles: [(.email, "family@example.com")])
        await store.seed(cam, handles: [(.email, "family@example.com")])
        await store.setDigest(
            Fixture.digest([Fixture.entry("family@example.com", [Fixture.message("Moving to Denver")])]))
        let generator = FakeHookGenerator()
        let refresher = MemoryHookRefresher(store: store, generator: generator)

        let report = try report(try await refresher.refresh(now: t0))

        #expect(await generator.callCount == 0)
        #expect(report.cleared == [ana.id])
        #expect(await store.allHooks(for: ana.id).isEmpty)
    }

    @Test func injectedNormalizerMatchesDifferentlyFormattedHandles() async throws {
        let store = FakeMemoryStore()
        let ana = Person(displayName: "Ana", confirmed: true)
        await store.seed(ana, handles: [(.phone, "+1 (555) 000-0001")])
        await store.setDigest(
            Fixture.digest([Fixture.entry("15550000001", [Fixture.message("New puppy named Miso")])]))
        let generator = FakeHookGenerator()
        let digitsOnly: @Sendable (String) -> String = { $0.filter(\.isNumber) }

        let strict = MemoryHookRefresher(store: store, generator: generator)
        #expect(try report(try await strict.refresh(now: t0)).regenerated.isEmpty)

        let lenient = MemoryHookRefresher(store: store, generator: generator, normalizeHandle: digitsOnly)
        #expect(try report(try await lenient.refresh(now: t0)).regenerated == [ana.id])
    }

    // MARK: Change detection

    @Test func unchangedInputIsNotRegenerated() async throws {
        let (store, generator, ana, _) = await makeWorld()
        let refresher = MemoryHookRefresher(store: store, generator: generator, minimumInterval: 0)

        _ = try await refresher.refresh(now: t0)
        let second = try report(try await refresher.refresh(now: t0.addingTimeInterval(60)))

        #expect(await generator.callCount == 1)
        #expect(second.regenerated.isEmpty)
        #expect(await store.replaceCalls == [ana.id])
    }

    @Test func changedExcerptsOrNameRegenerate() async throws {
        let (store, generator, ana, _) = await makeWorld()
        let refresher = MemoryHookRefresher(store: store, generator: generator, minimumInterval: 0)
        _ = try await refresher.refresh(now: t0)

        await store.setDigest(
            Fixture.digest([
                Fixture.entry(
                    "+15550000001",
                    [
                        Fixture.message("Got the keys to the new flat", minutesAgo: 1),
                        Fixture.message("I start at Acme"),
                    ]
                )
            ]))
        #expect(
            try report(try await refresher.refresh(now: t0.addingTimeInterval(1))).regenerated == [ana.id])

        await store.rename(ana.id, "Ana Lima")
        #expect(
            try report(try await refresher.refresh(now: t0.addingTimeInterval(2))).regenerated == [ana.id])
        #expect(await generator.callCount == 3)
    }

    @Test func inputHashIsStableAndContentSensitive() {
        let person = Person(displayName: "Ana")
        let a = [Fixture.message("one", minutesAgo: 1), Fixture.message("two", minutesAgo: 2)]
        let b = [Fixture.message("one", minutesAgo: 1), Fixture.message("two!", minutesAgo: 2)]
        #expect(
            MemoryHookRefresher.inputHash(person: person, messages: a)
                == MemoryHookRefresher.inputHash(person: person, messages: a))
        #expect(
            MemoryHookRefresher.inputHash(person: person, messages: a)
                != MemoryHookRefresher.inputHash(person: person, messages: b))
        #expect(
            MemoryHookRefresher.inputHash(person: person, messages: [])
                != MemoryHookRefresher.inputHash(person: person, messages: a))
    }

    @Test func noExcerptsClearsOnlySummaryHooks() async throws {
        let (store, generator, ana, _) = await makeWorld()
        let refresher = MemoryHookRefresher(store: store, generator: generator, minimumInterval: 0)
        _ = try await refresher.refresh(now: t0)
        try await store.addHook(
            MemoryHook(personID: ana.id, text: "Loves jazz", source: .userNote, createdAt: t0))

        // The user turned off message export on the Mac: the new digest has no excerpts.
        await store.setDigest(Fixture.digest([Fixture.entry("+15550000001", nil)]))
        let report = try report(try await refresher.refresh(now: t0.addingTimeInterval(1)))

        #expect(report.cleared == [ana.id])
        #expect(await generator.callCount == 1)
        #expect(await store.allHooks(for: ana.id).map(\.source) == [.userNote])
    }

    // MARK: Policy

    @Test func sensitiveTopicFilterAndLimitsApply() async throws {
        let (store, generator, ana, _) = await makeWorld(texts: [
            "Recovering from knee surgery",
            "Started a new job at Acme",
            "Owes me $50",
            "Goes to church on Sundays",
            "Just came out as gay",
            "Paying off a big student loan",
            "This hook is much longer than forty characters in total",
            "Training for a marathon",
            "  Started a new job at Acme ",
            "Adopted a cat named Miso",
            "Learning to surf",
        ])
        let refresher = MemoryHookRefresher(store: store, generator: generator)
        _ = try await refresher.refresh(now: t0)

        let stored = await store.allHooks(for: ana.id)
        #expect(
            stored.map(\.text) == [
                "Started a new job at Acme", "Training for a marathon", "Adopted a cat named Miso",
            ])
        #expect(stored.allSatisfy { $0.text.count <= MemoryHookPolicy.maxLength })
    }

    @Test func storedHooksAreSummariesThatExpireAfter30Days() async throws {
        let (store, generator, ana, _) = await makeWorld()
        let refresher = MemoryHookRefresher(store: store, generator: generator)
        _ = try await refresher.refresh(now: t0)

        let stored = try #require(await store.allHooks(for: ana.id).first)
        #expect(stored.source == .onDeviceSummary)
        #expect(stored.personID == ana.id)
        #expect(stored.createdAt == t0)
        #expect(stored.expiresAt == t0.addingTimeInterval(30 * 24 * 60 * 60))
        #expect(try await store.hooks(for: ana.id, now: t0.addingTimeInterval(31 * 24 * 60 * 60)).isEmpty)
    }

    // MARK: Unavailable model

    @Test func unavailableModelIsANoOp() async throws {
        let (store, generator, ana, _) = await makeWorld(available: false)
        try await store.addHook(
            MemoryHook(personID: ana.id, text: "Old summary", source: .onDeviceSummary, createdAt: t0))
        let refresher = MemoryHookRefresher(store: store, generator: generator)

        #expect(try await refresher.refresh(now: t0) == .modelUnavailable)
        #expect(await generator.callCount == 0)
        #expect(await store.replaceCalls.isEmpty)
        #expect(await store.allHooks(for: ana.id).map(\.text) == ["Old summary"])

        // Becoming available later is not blocked by the rate limit.
        await generator.setAvailable(true)
        #expect(
            try report(try await refresher.refresh(now: t0.addingTimeInterval(1))).regenerated == [ana.id])
    }

    @Test func modelLostMidRunDoesNotWipeHooks() async throws {
        let (store, generator, ana, _) = await makeWorld(texts: [])
        try await store.addHook(
            MemoryHook(personID: ana.id, text: "Old summary", source: .onDeviceSummary, createdAt: t0))
        let lossy = LosesAvailabilityGenerator(inner: generator)
        let refresher = MemoryHookRefresher(store: store, generator: lossy)

        let report = try report(try await refresher.refresh(now: t0))

        #expect(report.failed == [ana.id])
        #expect(await store.allHooks(for: ana.id).map(\.text) == ["Old summary"])
    }

    @Test func noDigestIsANoOp() async throws {
        let (store, generator, _, _) = await makeWorld()
        await store.setDigest(nil)
        let refresher = MemoryHookRefresher(store: store, generator: generator)
        #expect(try await refresher.refresh(now: t0) == .noDigest)
        #expect(await store.replaceCalls.isEmpty)
    }

    // MARK: Rate limiting

    @Test func runsAreRateLimited() async throws {
        let (store, generator, _, _) = await makeWorld()
        let refresher = MemoryHookRefresher(store: store, generator: generator, minimumInterval: 600)

        _ = try report(try await refresher.refresh(now: t0))
        #expect(try await refresher.refresh(now: t0.addingTimeInterval(599)) == .rateLimited)
        _ = try report(try await refresher.refresh(now: t0.addingTimeInterval(600)))
    }

    @Test func generationsPerRunAreCappedAndDeferredToTheNextRun() async throws {
        let store = FakeMemoryStore()
        var entries: [InteractionDigest.Entry] = []
        var ids: Set<PersonID> = []
        for i in 0..<5 {
            let person = Person(displayName: "P\(i)", confirmed: true)
            ids.insert(person.id)
            await store.seed(person, handles: [(.imessageHandle, "p\(i)@example.com")])
            entries.append(Fixture.entry("p\(i)@example.com", [Fixture.message("Hello \(i)")]))
        }
        await store.setDigest(Fixture.digest(entries))
        let generator = FakeHookGenerator()
        let refresher = MemoryHookRefresher(
            store: store, generator: generator, minimumInterval: 0, maxGenerationsPerRun: 2)

        let first = try report(try await refresher.refresh(now: t0))
        #expect(first.regenerated.count == 2)
        #expect(first.deferred.count == 3)
        let second = try report(try await refresher.refresh(now: t0.addingTimeInterval(1)))
        let third = try report(try await refresher.refresh(now: t0.addingTimeInterval(2)))
        #expect(first.regenerated.union(second.regenerated).union(third.regenerated) == ids)
        #expect(await generator.callCount == 5)
    }

    @Test func failedGenerationIsRetriedNextRun() async throws {
        let (store, generator, ana, _) = await makeWorld()
        await generator.setFailure(FakeGenerationError())
        let refresher = MemoryHookRefresher(store: store, generator: generator, minimumInterval: 0)

        #expect(try report(try await refresher.refresh(now: t0)).failed == [ana.id])
        #expect(await store.allHooks(for: ana.id).isEmpty)

        await generator.setFailure(nil)
        #expect(
            try report(try await refresher.refresh(now: t0.addingTimeInterval(1))).regenerated == [ana.id])
    }

    // MARK: Cancellation

    @Test func cancellationStopsTheRunWithoutWriting() async throws {
        let (store, generator, ana, _) = await makeWorld()
        await generator.setBlocking(true)
        let refresher = MemoryHookRefresher(store: store, generator: generator, minimumInterval: 600)

        let task = Task { try await refresher.refresh(now: t0) }
        await generator.waitUntilCalled()
        task.cancel()
        await generator.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await store.replaceCalls.isEmpty)
        #expect(await store.allHooks(for: ana.id).isEmpty)

        // A cancelled run is not "completed": the next call is not rate limited and redoes the work.
        #expect(
            try report(try await refresher.refresh(now: t0.addingTimeInterval(1))).regenerated == [ana.id])
    }

    @Test func alreadyCancelledTaskDoesNothing() async throws {
        let (store, generator, _, _) = await makeWorld()
        let refresher = MemoryHookRefresher(store: store, generator: generator)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await refresher.refresh(now: t0)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await generator.callCount == 0)
        #expect(await store.replaceCalls.isEmpty)
    }

    @Test func overlappingRefreshReportsAlreadyRunning() async throws {
        let (store, generator, _, _) = await makeWorld()
        await generator.setBlocking(true)
        let refresher = MemoryHookRefresher(store: store, generator: generator, minimumInterval: 0)

        let first = Task { try await refresher.refresh(now: t0) }
        await generator.waitUntilCalled()
        #expect(try await refresher.refresh(now: t0) == .alreadyRunning)
        await generator.release()
        _ = try report(try await first.value)
    }
}

/// Reports available for the refresher's up-front check, then unavailable once a generation ran
/// (simulates Apple Intelligence being switched off mid-run).
actor LosesAvailabilityGenerator: MemoryHookGenerating {
    let inner: FakeHookGenerator
    private var generated = false
    init(inner: FakeHookGenerator) { self.inner = inner }
    var isAvailable: Bool { !generated }
    func hooks(for person: Person, messages: [InteractionDigest.DigestMessage], now: Date) async throws
        -> [MemoryHook]
    {
        generated = true
        return try await inner.hooks(for: person, messages: messages, now: now)
    }
}

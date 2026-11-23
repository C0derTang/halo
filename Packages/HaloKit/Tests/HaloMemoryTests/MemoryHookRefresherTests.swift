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

        let first = try report(try await refresher.refresh(now: t0))

        #expect(first.failed.isEmpty)
        #expect(first.regenerated.isEmpty)
        #expect(await store.allHooks(for: ana.id).map(\.text) == ["Old summary"])

        // Not counted for rate limiting and no failure recorded: the same refresher, default
        // interval, regenerates one second later once the model is back.
        await generator.setTexts(["Started a new job at Acme"])
        await lossy.restore()
        let again = try report(try await refresher.refresh(now: t0.addingTimeInterval(1)))
        #expect(again.regenerated == [ana.id])
        #expect(again.backingOff.isEmpty)
        #expect(again.failed.isEmpty)
    }

    @Test func unconfirmedSweepIsFullOnFirstRunThenNarrow() async throws {
        let (store, generator, ana, ben) = await makeWorld()
        let refresher = MemoryHookRefresher(store: store, generator: generator, minimumInterval: 0)

        _ = try await refresher.refresh(now: t0)
        #expect(await store.hookReads.contains(ben.id))

        // Second run: Ben was never confirmed, so nobody needs sweeping.
        await store.resetHookReads()
        _ = try await refresher.refresh(now: t0.addingTimeInterval(1))
        #expect(await store.hookReads.isEmpty)

        // Ana loses confirmation: swept (and cleared) once, then left alone.
        await store.setConfirmed(ana.id, false)
        let cleared = try report(try await refresher.refresh(now: t0.addingTimeInterval(2)))
        #expect(cleared.cleared == [ana.id])
        #expect(await store.hookReads == [ana.id])
        await store.resetHookReads()
        _ = try await refresher.refresh(now: t0.addingTimeInterval(3))
        #expect(await store.hookReads.isEmpty)
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
        // Backing off for the first hour after a failure...
        #expect(
            try report(try await refresher.refresh(now: t0.addingTimeInterval(1))).backingOff == [ana.id])
        #expect(await generator.callCount == 1)
        // ...then retried.
        #expect(
            try report(try await refresher.refresh(now: t0.addingTimeInterval(3600))).regenerated == [ana.id])
    }

    static func fixedPerson(_ n: Int, _ name: String) -> Person {
        let uuid = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
        return Person(id: PersonID(uuid), displayName: name, confirmed: true)
    }

    @Test func failureBackoffGrowsOneHourSixHoursOneDay() async throws {
        let (store, generator, ana, _) = await makeWorld()
        await generator.setFailing([ana.id])
        let refresher = MemoryHookRefresher(store: store, generator: generator, minimumInterval: 0)
        let hour: TimeInterval = 3600

        var now = t0
        #expect(try report(try await refresher.refresh(now: now)).failed == [ana.id])  // 1st failure
        // Each retry fails again; the wait grows 1h -> 6h -> 24h -> 24h.
        for wait in [hour, 6 * hour, 24 * hour, 24 * hour] {
            let calls = await generator.callCount
            #expect(
                try report(try await refresher.refresh(now: now.addingTimeInterval(wait - 1))).backingOff
                    == [ana.id])
            #expect(await generator.callCount == calls)
            now = now.addingTimeInterval(wait)
            #expect(try report(try await refresher.refresh(now: now)).failed == [ana.id])
            #expect(await generator.callCount == calls + 1)
        }

        // Success resets the backoff.
        await generator.setFailing([])
        now = now.addingTimeInterval(24 * hour)
        #expect(try report(try await refresher.refresh(now: now)).regenerated == [ana.id])
    }

    @Test func persistentlyFailingPeopleDoNotStarveOthers() async throws {
        let store = FakeMemoryStore()
        // Failing people sort FIRST by id, so a fixed order would serve them before anyone else.
        let failing = (1...3).map { Self.fixedPerson($0, "F\($0)") }
        let good = Self.fixedPerson(9, "Good")
        var entries: [InteractionDigest.Entry] = []
        for person in failing + [good] {
            await store.seed(person, handles: [(.email, "\(person.displayName)@example.com")])
            entries.append(Fixture.entry("\(person.displayName)@example.com", [Fixture.message("Hi")]))
        }
        await store.setDigest(Fixture.digest(entries))
        let generator = FakeHookGenerator()
        await generator.setFailing(Set(failing.map(\.id)))
        let refresher = MemoryHookRefresher(
            store: store, generator: generator, minimumInterval: 0, maxGenerationsPerRun: 3)

        let first = try report(try await refresher.refresh(now: t0))
        #expect(first.failed == Set(failing.map(\.id)))
        #expect(first.deferred == [good.id])

        // Next run: the failures are backing off and do not use the cap, so Good gets served.
        let second = try report(try await refresher.refresh(now: t0.addingTimeInterval(60)))
        #expect(second.regenerated == [good.id])
        #expect(second.backingOff == Set(failing.map(\.id)))

        // After the backoff, a newcomer (sorting LAST by id) is served before the retries.
        let newcomer = Self.fixedPerson(99, "New")
        await store.seed(newcomer, handles: [(.email, "New@example.com")])
        await store.setDigest(
            Fixture.digest(entries + [Fixture.entry("New@example.com", [Fixture.message("Hello")])]))
        let third = try report(try await refresher.refresh(now: t0.addingTimeInterval(3600)))
        #expect(third.regenerated == [newcomer.id])
        #expect(third.failed.count == 2)
        #expect(third.deferred.count == 1)
        #expect(await generator.askedAbout.suffix(3).first == newcomer.id)
    }

    @Test func unconfirmingAPersonClearsTheirSummaryHooks() async throws {
        let (store, generator, ana, _) = await makeWorld()
        let refresher = MemoryHookRefresher(store: store, generator: generator, minimumInterval: 0)
        _ = try await refresher.refresh(now: t0)
        try await store.addHook(
            MemoryHook(personID: ana.id, text: "Loves jazz", source: .userNote, createdAt: t0))
        #expect(await store.allHooks(for: ana.id).count == 2)

        await store.setConfirmed(ana.id, false)
        let unconfirmed = try report(try await refresher.refresh(now: t0.addingTimeInterval(1)))

        #expect(unconfirmed.cleared == [ana.id])
        #expect(await store.allHooks(for: ana.id).map(\.source) == [.userNote])
        #expect(await generator.callCount == 1)

        // Re-confirming regenerates (the cached hash was dropped with the confirmation).
        await store.setConfirmed(ana.id, true)
        #expect(
            try report(try await refresher.refresh(now: t0.addingTimeInterval(2))).regenerated == [ana.id])
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
    /// The model is back: available again.
    func restore() { generated = false }
    func hooks(for person: Person, messages: [InteractionDigest.DigestMessage], now: Date) async throws
        -> [MemoryHook]
    {
        generated = true
        return try await inner.hooks(for: person, messages: messages, now: now)
    }
}

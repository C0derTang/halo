import Foundation
import HaloBridgeKit
import HaloCore
import Testing

@testable import HaloLabels

private let utc = TimeZone(identifier: "UTC")!
private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = utc
    return c
}()
private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    cal.date(from: DateComponents(timeZone: utc, year: y, month: m, day: d, hour: h))!
}
private let now = date(2026, 6, 15)
private let ranker = ContextLabelRanker(calendar: cal, locale: Locale(identifier: "en_US_POSIX"))

private func entry(
    _ handle: String, last: Date? = nil, theirs: Date? = nil, waiting: Bool = false
) -> InteractionDigest.Entry {
    .init(
        handle: handle, lastMessageAt: last, lastFromMeAt: nil, lastFromThemAt: theirs,
        messagesLast30Days: 1, messagesAllTime: 10, awaitingMyReply: waiting)
}
private func digest(_ entries: [InteractionDigest.Entry]) -> InteractionDigest {
    .init(generatedAt: now, entries: entries)
}
private func rank(
    _ p: Person, ids: [Identity] = [], _ d: InteractionDigest? = nil, at: Date = now
) -> LabelData {
    ranker.label(for: p, identities: ids, digest: d, now: at)
}
private func phone(_ p: Person, _ v: String = "+15551234567") -> Identity {
    Identity(personID: p.id, kind: .phone, value: v)
}

@Test func noDigestGivesNameAndRelationshipOnly() {
    let p = Person(displayName: "Ada", relationship: "Roommate")
    let l = rank(p)
    #expect(l.title == "Ada" && l.subtitle == "Roommate" && l.chips.isEmpty)
}

@Test func birthdayThresholdsAndText() {
    func chip(_ m: Int, _ d: Int) -> LabelChip? {
        rank(Person(displayName: "A", birthday: DateComponents(month: m, day: d))).chips.first
    }
    #expect(chip(6, 15)?.text == "Birthday today")
    #expect(chip(6, 16)?.text == "Birthday tomorrow")
    #expect(chip(6, 20)?.text == "Birthday in 5 days")
    #expect(chip(6, 29)?.text == "Birthday in 14 days")
    #expect(chip(6, 30) == nil)
    #expect(chip(6, 14) == nil)  // yesterday: next one is 364 days away
    #expect(chip(6, 15)!.priority > chip(6, 20)!.priority)
    #expect(chip(6, 20)!.priority > chip(6, 29)!.priority)
}

@Test func birthdayAcrossYearBoundary() {
    let p = Person(displayName: "A", birthday: DateComponents(year: 1990, month: 1, day: 3))
    #expect(rank(p, at: date(2026, 12, 25)).chips.first?.text == "Birthday in 9 days")
}

@Test func leapDayBirthday() {
    let p = Person(displayName: "A", birthday: DateComponents(month: 2, day: 29))
    #expect(rank(p, at: date(2027, 2, 20)).chips.first?.text == "Birthday in 8 days")  // observed Feb 28
    #expect(rank(p, at: date(2028, 2, 20)).chips.first?.text == "Birthday in 9 days")  // real Feb 29
    #expect(rank(p, at: date(2027, 12, 30)).chips.isEmpty)
    // Jan 20 2027 -> Feb 28 2027 is 39 days: outside window.
    #expect(rank(p, at: date(2027, 1, 20)).chips.isEmpty)
}

@Test func openLoopFromAnyIdentityKind() {
    let p = Person(displayName: "A")
    let d = digest([entry("+15551234567", last: date(2026, 6, 12), theirs: date(2026, 6, 12), waiting: true)])
    #expect(
        rank(p, ids: [phone(p)], d).chips.first { $0.kind == .openLoop }?.text
            == "Waiting on your reply · 3d")
    let e = Identity(personID: p.id, kind: .email, value: "A@Example.com")
    let d2 = digest([entry("a@example.com", last: date(2026, 6, 14), waiting: true)])
    #expect(rank(p, ids: [e], d2).chips.contains { $0.text == "Waiting on your reply · 1d" })
    let d3 = digest([entry("+15551234567", last: now, waiting: true)])
    #expect(
        rank(p, ids: [phone(p)], d3).chips.first { $0.kind == .openLoop }?.text
            == "Waiting on your reply · today")
}

@Test func notAwaitingMeansNoOpenLoop() {
    let p = Person(displayName: "A")
    let d = digest([entry("+15551234567", last: date(2026, 6, 12), waiting: false)])
    #expect(!rank(p, ids: [phone(p)], d).chips.contains { $0.kind == .openLoop })
}

@Test func lastInteractionFormats() {
    let p = Person(displayName: "A")
    func text(_ last: Date) -> String? {
        rank(p, ids: [phone(p)], digest([entry("+15551234567", last: last)])).chips
            .first { $0.kind == .lastInteraction }?.text
    }
    #expect(text(date(2026, 6, 15, 1)) == "Talked today")
    #expect(text(date(2026, 6, 12)) == "Texted 3d ago")
    #expect(text(date(2026, 5, 17)) == "Texted 29d ago")
    #expect(text(date(2025, 10, 8)) == "Last texted 8 mo ago")
    #expect(text(date(2024, 6, 1)) == "Last texted 2 y ago")
    #expect(text(date(2026, 6, 20)) == "Talked today")  // clock skew clamps
}

@Test func staleInteractionLowersPriority() {
    let p = Person(displayName: "A")
    func prio(_ last: Date) -> Double {
        rank(p, ids: [phone(p)], digest([entry("+15551234567", last: last)])).chips[0].priority
    }
    #expect(prio(date(2026, 6, 1)) > prio(date(2025, 1, 1)))
    #expect(prio(date(2025, 1, 1)) < 0.4)
}

@Test func multipleHandlesAggregateToMostRecent() {
    let p = Person(displayName: "A")
    let ids = [phone(p), Identity(personID: p.id, kind: .imessageHandle, value: "a@b.com")]
    let d = digest([
        entry("+15551234567", last: date(2026, 1, 1)),
        entry("a@b.com", last: date(2026, 6, 13)),
    ])
    #expect(rank(p, ids: ids, d).chips.first { $0.kind == .lastInteraction }?.text == "Texted 2d ago")
}

@Test func handlesNormalizeBeforeMatching() {
    let p = Person(displayName: "A")
    let d = digest([entry("(555) 123-4567", last: date(2026, 6, 14))])
    #expect(rank(p, ids: [phone(p)], d).chips.contains { $0.kind == .lastInteraction })
}

@Test func otherPeoplesHandlesNeverAttribute() {
    let p = Person(displayName: "A")
    let q = Person(displayName: "B")
    let d = digest([entry("+15559999999", last: now, waiting: true)])
    #expect(rank(p, ids: [phone(p), phone(q, "+15559999999")], d).chips.isEmpty)
    #expect(rank(p, ids: [phone(p)], d).chips.isEmpty)
}

@Test func handleClaimedByTwoPeopleIsAmbiguousAndDropped() {
    let p = Person(displayName: "A")
    let q = Person(displayName: "B")
    let d = digest([entry("+15551234567", last: now, waiting: true)])
    #expect(rank(p, ids: [phone(p), phone(q)], d).chips.isEmpty)
}

@Test func nonHandleIdentityKindsIgnored() {
    let p = Person(displayName: "A")
    let ids = [Identity(personID: p.id, kind: .contact, value: "+15551234567")]
    let d = digest([entry("+15551234567", last: now)])
    #expect(rank(p, ids: ids, d).chips.isEmpty)
}

@Test func memoryHookFirstSentenceAndEllipsis() {
    func hook(_ n: String?) -> String? {
        rank(Person(displayName: "A", notes: n)).chips.first { $0.kind == .memoryHook }?.text
    }
    #expect(hook("Loves climbing. Met at the gym.") == "Loves climbing")
    #expect(hook("  Plays cello\nSecond line") == "Plays cello")
    #expect(hook("Version 3.5 fan") == "Version 3.5 fan")
    #expect(hook("") == nil && hook(nil) == nil && hook("   ") == nil)
    let long = hook("Allergic to shellfish and also afraid of heights forever")!
    #expect(long.count == 40 && long.hasSuffix("…"))
    #expect(hook(String(repeating: "a", count: 40)) == String(repeating: "a", count: 40))
}

@Test func chipsSortedDescendingByPriority() {
    let p = Person(
        displayName: "A", birthday: DateComponents(month: 6, day: 18), notes: "Loves tea.")
    let d = digest([entry("+15551234567", last: date(2026, 6, 12), theirs: date(2026, 6, 12), waiting: true)])
    let l = rank(p, ids: [phone(p)], d)
    #expect(l.chips.map(\.kind) == [.upcoming, .openLoop, .lastInteraction, .memoryHook])
    #expect(l.chips.map(\.priority) == l.chips.map(\.priority).sorted(by: >))
}

@Test func chipTextNeverLeaksHandles() {
    let p = Person(displayName: "A")
    let d = digest([entry("+15551234567", last: date(2026, 6, 12), waiting: true)])
    for chip in rank(p, ids: [phone(p)], d).chips {
        #expect(!chip.text.contains("5551234567"))
    }
}

@Test func deterministicAcrossRuns() {
    let p = Person(displayName: "A", birthday: DateComponents(month: 6, day: 20), notes: "Hi.")
    #expect(rank(p) == rank(p))
}

@Test func regionalNumbersAttributeWithMatchingRegion() {
    let gb = ContextLabelRanker(
        calendar: cal, locale: Locale(identifier: "en_US_POSIX"),
        normalizer: HandleNormalizer(region: "GB"))
    let fr = ContextLabelRanker(
        calendar: cal, locale: Locale(identifier: "en_US_POSIX"),
        normalizer: HandleNormalizer(region: "FR"))
    let p = Person(displayName: "A")
    let g = gb.label(
        for: p, identities: [phone(p, "+442079460958")],
        digest: digest([entry("020 7946 0958", last: date(2026, 6, 14))]), now: now)
    #expect(g.chips.contains { $0.kind == .lastInteraction })
    let f = fr.label(
        for: p, identities: [phone(p, "+33612345678")],
        digest: digest([entry("0612345678", last: date(2026, 6, 14))]), now: now)
    #expect(f.chips.contains { $0.kind == .lastInteraction })
    #expect(!HandleNormalizer(region: "GB").normalize("020 7946 0958").hasPrefix("+1"))
    #expect(!HandleNormalizer(region: "FR").normalize("0612345678").hasPrefix("+1"))
}

@Test func localNumberNeverCollidesWithUSNumber() {
    let gb = ContextLabelRanker(
        calendar: cal, locale: Locale(identifier: "en_US_POSIX"),
        normalizer: HandleNormalizer(region: "GB"))
    let p = Person(displayName: "A")
    // US identity must not match a GB-local number that shares digits.
    let l = gb.label(
        for: p, identities: [phone(p, "+12079460958")],
        digest: digest([entry("2079460958", last: now)]), now: now)
    #expect(l.chips.isEmpty)
}

@Test func handleNormalizingOnOneSideOnlyGivesNoChip() {
    let p = Person(displayName: "A")
    let l = rank(p, ids: [phone(p, "+15551234567")], digest([entry("12345", last: now)]))
    #expect(l.chips.isEmpty)
    let m = rank(p, ids: [phone(p, "12345")], digest([entry("+15551234567", last: now)]))
    #expect(m.chips.isEmpty)
}

@Test func staleCutoffAtExactly365Days() {
    let p = Person(displayName: "A")
    func prio(_ last: Date) -> Double {
        rank(p, ids: [phone(p)], digest([entry("+15551234567", last: last)])).chips[0].priority
    }
    #expect(prio(date(2025, 6, 15)) == 0.2)  // exactly 365 days
    #expect(prio(date(2025, 6, 16)) == 0.45)  // 364 days
}

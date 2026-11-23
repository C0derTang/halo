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
// 2026-06-15 12:00 UTC
private let now = cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 6, day: 15, hour: 12))!
private let ranker = ContextLabelRanker(calendar: cal, locale: Locale(identifier: "en_US_POSIX"))
private let day: TimeInterval = 86_400

private func hook(
    _ p: Person, _ text: String, _ source: MemoryHook.Source = .userNote, age: Double = 0,
    expires: Date? = nil
) -> MemoryHook {
    MemoryHook(
        personID: p.id, text: text, source: source, createdAt: now - age * day, expiresAt: expires)
}
private func chips(_ p: Person, _ hooks: [MemoryHook]) -> [LabelChip] {
    ranker.label(for: p, identities: [], digest: nil, hooks: hooks, now: now).chips
}
private func hookChips(_ p: Person, _ hooks: [MemoryHook]) -> [LabelChip] {
    chips(p, hooks).filter { $0.kind == .memoryHook }
}

@Test func hookTextEllipsizedTo40() {
    let p = Person(displayName: "A")
    let long = hookChips(p, [hook(p, "Training for the Berlin marathon this coming autumn")])
    #expect(long.count == 1 && long[0].text.count == 40 && long[0].text.hasSuffix("…"))
    let exact = String(repeating: "b", count: 40)
    #expect(hookChips(p, [hook(p, exact)]).first?.text == exact)
    #expect(hookChips(p, [hook(p, "  just   started\n at Acme ")]).first?.text == "just started at Acme")
    #expect(hookChips(p, [hook(p, "   ")]).isEmpty)
}

@Test func priorityBySource() {
    let p = Person(displayName: "A")
    let c = hookChips(
        p, [hook(p, "note", .userNote), hook(p, "moment", .moment), hook(p, "sum", .onDeviceSummary)])
    #expect(c.first { $0.text == "note" }?.priority == 0.6)
    #expect(c.first { $0.text == "moment" }?.priority == 0.6)
    #expect(c.first { $0.text == "sum" }?.priority == 0.45)
}

@Test func ordersUserHooksBeforeSummariesBeforeNotesField() {
    let p = Person(displayName: "A", notes: "From notes.")
    let c = hookChips(p, [hook(p, "summary", .onDeviceSummary), hook(p, "moment", .moment)])
    #expect(c.map(\.text) == ["moment", "summary", "From notes"])
}

@Test func summaryPriorityDecaysWithAge() {
    let p = Person(displayName: "A")
    func prio(_ age: Double) -> Double {
        hookChips(p, [hook(p, "s", .onDeviceSummary, age: age)])[0].priority
    }
    #expect(prio(0) > prio(10))
    #expect(prio(10) > prio(20))
    #expect(prio(20) > prio(30))
    #expect(prio(30) == prio(300))  // floor
    #expect(prio(300) > 0)
    let c = hookChips(p, [hook(p, "old", .onDeviceSummary, age: 20), hook(p, "new", .onDeviceSummary)])
    #expect(c.map(\.text) == ["new", "old"])
}

@Test func equalPriorityNewestFirst() {
    let p = Person(displayName: "A")
    let c = hookChips(p, [hook(p, "older", age: 5), hook(p, "newer", age: 1)])
    #expect(c.map(\.text) == ["newer", "older"])
}

@Test func expiredHooksExcluded() {
    let p = Person(displayName: "A")
    let c = hookChips(
        p,
        [
            hook(p, "expired", expires: now - 1),
            hook(p, "expires-now", expires: now),
            hook(p, "future", expires: now + day),
            hook(p, "never"),
        ])
    #expect(Set(c.map(\.text)) == ["future", "never"])
}

@Test func notesDedupedAgainstUserNoteHook() {
    let p = Person(displayName: "A", notes: "Loves climbing. Met at the gym.")
    let c = hookChips(p, [hook(p, "loves  CLIMBING", .userNote)])
    #expect(c.count == 1)
    #expect(c[0].priority == 0.6)  // the higher-priority copy survives
    // a distinct hook is kept alongside the notes chip
    #expect(hookChips(p, [hook(p, "Runs marathons")]).count == 2)
    // duplicate hooks collapse too
    let q = Person(displayName: "Q")
    #expect(hookChips(q, [hook(q, "x"), hook(q, "X", .moment)]).count == 1)
}

@Test func longNotesAndLongHookDedupeAfterEllipsis() {
    let text = "Allergic to shellfish and also afraid of heights forever"
    let p = Person(displayName: "A", notes: text)
    #expect(hookChips(p, [hook(p, text)]).count == 1)
}

@Test func otherPeoplesHooksNeverShown() {
    let p = Person(displayName: "A")
    let other = Person(displayName: "B")
    #expect(hookChips(p, [hook(other, "secret about B")]).isEmpty)
}

@Test func hooksMergeWithOtherChipsByPriority() {
    let p = Person(displayName: "A", birthday: DateComponents(month: 6, day: 17))
    let c = chips(p, [hook(p, "Loves tea", .onDeviceSummary), hook(p, "Moved cities", .moment)])
    #expect(c.map(\.kind) == [.upcoming, .memoryHook, .memoryHook])
    #expect(c.map(\.text).suffix(2) == ["Moved cities", "Loves tea"])
}

@Test func messageExcerptsNeverBecomeChips() {
    let p = Person(displayName: "A")
    let id = Identity(personID: p.id, kind: .phone, value: "+15551234567")
    let entry = InteractionDigest.Entry(
        handle: "+15551234567", lastMessageAt: now, lastFromMeAt: nil, lastFromThemAt: now,
        messagesLast30Days: 1, messagesAllTime: 5, awaitingMyReply: true,
        recentMessages: [.init(date: now, fromMe: false, text: "VERBATIM SECRET MESSAGE")])
    let d = InteractionDigest(generatedAt: now, entries: [entry])
    let l = ranker.label(for: p, identities: [id], digest: d, hooks: [], now: now)
    #expect(!l.chips.isEmpty)
    #expect(l.chips.allSatisfy { !$0.text.contains("VERBATIM") && $0.kind != .memoryHook })
}

@Test func oldMethodMatchesNewWithNoHooks() {
    let p = Person(
        displayName: "A", birthday: DateComponents(month: 6, day: 18), notes: "Loves tea. Ok.")
    let id = Identity(personID: p.id, kind: .phone, value: "+15551234567")
    let e = InteractionDigest.Entry(
        handle: "+15551234567", lastMessageAt: now - 3 * day, lastFromMeAt: nil,
        lastFromThemAt: now - 3 * day, messagesLast30Days: 1, messagesAllTime: 5,
        awaitingMyReply: true)
    let d = InteractionDigest(generatedAt: now, entries: [e])
    let old = ranker.label(for: p, identities: [id], digest: d, now: now)
    let new = ranker.label(for: p, identities: [id], digest: d, hooks: [], now: now)
    #expect(old == new)
    #expect(old.chips.contains { $0.kind == .memoryHook && $0.text == "Loves tea" && $0.priority == 0.4 })
    // protocol-level dispatch reaches the new implementation
    let viaProtocol: any LabelRanking = ranker
    let h = hook(p, "Via protocol")
    #expect(
        viaProtocol.label(for: p, identities: [], digest: nil, hooks: [h], now: now).chips.map(\.text)
            .contains("Via protocol"))
}

import Foundation
import HaloCore
import Testing

@testable import HaloBridgeKit

@Suite struct DigestBuilderTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400

    func rec(_ h: String, me: Bool, ago: TimeInterval) -> MessageRecord {
        MessageRecord(handle: h, isFromMe: me, date: now.addingTimeInterval(-ago))
    }

    func entry(_ records: [MessageRecord]) -> InteractionDigest.Entry? {
        DigestBuilder().build(records: records, now: now).entries.first
    }

    @Test func dateConversionSecondsVsNanoseconds() {
        let secs: Int64 = 700_000_000
        #expect(AppleDate.convert(secs) == AppleDate.convert(secs * 1_000_000_000))
        #expect(AppleDate.convert(0) == Date(timeIntervalSince1970: 978_307_200))
        #expect(AppleDate.convert(secs).timeIntervalSince1970 == 978_307_200 + 700_000_000)
    }

    @Test func aggregationPerHandle() {
        let d = DigestBuilder().build(
            records: [
                rec("+14155550132", me: false, ago: 2 * day),
                rec("+14155550132", me: true, ago: 1 * day),
                rec("a@b.com", me: false, ago: 40 * day),
            ], now: now)
        #expect(d.version == 1)
        #expect(d.generatedAt == now)
        #expect(d.entries.count == 2)
        let p = d.entries.first { $0.handle == "+14155550132" }!
        #expect(p.messagesAllTime == 2)
        #expect(p.messagesLast30Days == 2)
        #expect(p.lastMessageAt == now.addingTimeInterval(-day))
        #expect(p.lastFromMeAt == now.addingTimeInterval(-day))
        #expect(p.lastFromThemAt == now.addingTimeInterval(-2 * day))
        let e = d.entries.first { $0.handle == "a@b.com" }!
        #expect(e.messagesLast30Days == 0)
        #expect(e.messagesAllTime == 1)
        #expect(e.lastFromMeAt == nil)
    }

    @Test func mergesEquivalentHandles() {
        let d = DigestBuilder().build(
            records: [
                rec("(415) 555-0132", me: false, ago: day), rec("+14155550132", me: true, ago: 2 * day),
            ],
            now: now)
        #expect(d.entries.count == 1)
        #expect(d.entries[0].messagesAllTime == 2)
    }

    @Test func awaitingMyReplyTruthTable() {
        // only them
        #expect(entry([rec("x@y.z", me: false, ago: day)])!.awaitingMyReply)
        // only me
        #expect(!entry([rec("x@y.z", me: true, ago: day)])!.awaitingMyReply)
        // them newer than me
        #expect(
            entry([rec("x@y.z", me: true, ago: 2 * day), rec("x@y.z", me: false, ago: day)])!.awaitingMyReply)
        // me newer than them
        #expect(
            !entry([rec("x@y.z", me: false, ago: 2 * day), rec("x@y.z", me: true, ago: day)])!.awaitingMyReply
        )
        // simultaneous: not awaiting
        #expect(
            !entry([rec("x@y.z", me: false, ago: day), rec("x@y.z", me: true, ago: day)])!.awaitingMyReply)
    }

    @Test func thirtyDayWindowBoundary() {
        let e = entry([
            rec("x@y.z", me: true, ago: 30 * day),  // exactly on boundary: included
            rec("x@y.z", me: true, ago: 30 * day + 1),  // just outside
            rec("x@y.z", me: true, ago: 0),  // now: included
            rec("x@y.z", me: true, ago: -1),  // future: all-time only
        ])!
        #expect(e.messagesLast30Days == 2)
        #expect(e.messagesAllTime == 4)
    }

    @Test func emptyInput() {
        #expect(DigestBuilder().build(records: [], now: now).entries.isEmpty)
    }
}

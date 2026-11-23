import Foundation
import HaloCore
import Testing

@testable import HaloBridgeKit

/// Opt-in message excerpts: text selection, the reader query and the builder's bounds.
/// Synthetic chat.db and synthetic typedstream blobs only.
@Suite struct MessageExcerptTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400

    // MARK: Text selection

    @Test func textColumnWinsWhenReadable() {
        let body = TypedStreamWriter.attributedBody("from body")
        #expect(MessageExcerptPolicy.messageText(text: "from text", attributedBody: body) == "from text")
        #expect(MessageExcerptPolicy.messageText(text: nil, attributedBody: body) == "from body")
        // An empty / placeholder-only text column falls back to the body.
        #expect(MessageExcerptPolicy.messageText(text: "", attributedBody: body) == "from body")
        #expect(MessageExcerptPolicy.messageText(text: nil, attributedBody: nil) == nil)
        #expect(MessageExcerptPolicy.messageText(text: nil, attributedBody: Data([1, 2, 3])) == nil)
    }

    @Test func attachmentOnlyMessagesHaveNoExcerpt() {
        #expect(MessageExcerptPolicy.excerptText("\u{FFFC}") == nil)
        #expect(MessageExcerptPolicy.excerptText(" \u{FFFC}\u{FFFC}\n") == nil)
        #expect(MessageExcerptPolicy.excerptText("look \u{FFFC}") == "look")
        let body = TypedStreamWriter.attributedBody("\u{FFFC}")
        #expect(MessageExcerptPolicy.messageText(text: nil, attributedBody: body) == nil)
    }

    @Test func truncatesToMaxCharactersWithoutSplittingGraphemes() {
        let family = "👨‍👩‍👧‍👦"
        let long = String(repeating: family, count: 600)
        let cut = MessageExcerptPolicy.excerptText(long)!
        #expect(cut.count == MessageExcerptPolicy.maxCharacters)
        #expect(cut == String(repeating: family, count: 500))
        let exact = String(repeating: "a", count: 500)
        #expect(MessageExcerptPolicy.excerptText(exact) == exact)
    }

    @Test func descriptionIsRedacted() {
        let e = MessageExcerpt(handle: "a@b.c", isFromMe: true, date: now, text: SyntheticChatDB.secretText)
        #expect(!"\(e)".contains(SyntheticChatDB.secretText))
        #expect(!String(reflecting: e).contains(SyntheticChatDB.secretText))
    }

    // MARK: Reader

    @Test func readerReturnsOneToOneTextInWindow() throws {
        let db = try SyntheticChatDB(tapbackColumn: true)
        let alice = try db.addHandle("+14155550132")
        let bob = try db.addHandle("bob@example.com")
        let carol = try db.addHandle("+14155550199")
        let a = try db.addChat(handles: [alice])
        let group = try db.addChat(handles: [alice, bob, carol])
        try db.addBodyMessage(
            chat: a, handle: alice, fromMe: false, at: now.addingTimeInterval(-day), "body 🎉")
        try db.addMessage(
            chat: a, handle: alice, fromMe: true, at: now.addingTimeInterval(-2 * day), nanoseconds: false,
            text: "plain column", body: TypedStreamWriter.attributedBody("ignored"))
        try db.addBodyMessage(
            chat: a, handle: alice, fromMe: false, at: now.addingTimeInterval(-3 * day), "\u{FFFC}")
        try db.addMessage(
            chat: a, handle: alice, fromMe: false, at: now.addingTimeInterval(-4 * day), text: nil,
            body: Data("not an archive".utf8))
        // Odd column types (an invalid-UTF-8 blob in `text`) are skipped, not trapped on.
        try db.addMessage(
            chat: a, handle: alice, fromMe: false, at: now.addingTimeInterval(-5 * day),
            text: Data([0xFF, 0xFE]), body: nil)
        try db.addTapback(chat: a, handle: alice, fromMe: false, at: now.addingTimeInterval(-6 * day))
        try db.addBodyMessage(
            chat: a, handle: alice, fromMe: false, at: now.addingTimeInterval(-40 * day), "old")
        try db.addBodyMessage(
            chat: group, handle: carol, fromMe: false, at: now.addingTimeInterval(-day), "group")

        let excerpts = try ChatDatabaseReader(url: db.url).recentMessageExcerpts(
            since: now.addingTimeInterval(-30 * day))
        #expect(excerpts.map(\.text) == ["body 🎉", "plain column"])
        #expect(excerpts.map(\.isFromMe) == [false, true])
        #expect(excerpts.allSatisfy { $0.handle == "+14155550132" })
        #expect(excerpts[1].date == now.addingTimeInterval(-2 * day))  // seconds-format date converted
    }

    @Test func metadataQueryIsUnchangedByExcerpts() throws {
        let db = try SyntheticChatDB()
        let h = try db.addHandle("x@example.com")
        let c = try db.addChat(handles: [h])
        try db.addBodyMessage(chat: c, handle: h, fromMe: false, at: now, "hello")
        let records = try ChatDatabaseReader(url: db.url).messageRecords()
        #expect(records == [MessageRecord(handle: "x@example.com", isFromMe: false, date: now)])
    }

    // MARK: Builder

    func excerpt(_ h: String, ago: TimeInterval, me: Bool = false, _ text: String) -> MessageExcerpt {
        MessageExcerpt(handle: h, isFromMe: me, date: now.addingTimeInterval(-ago), text: text)
    }

    func record(_ h: String, ago: TimeInterval) -> MessageRecord {
        MessageRecord(handle: h, isFromMe: false, date: now.addingTimeInterval(-ago))
    }

    @Test func withoutExcerptsOutputIsMetadataOnly() throws {
        let d = DigestBuilder().build(records: [record("a@b.c", ago: day)], now: now)
        #expect(d.entries[0].recentMessages == nil)
        let json = String(decoding: try DigestCoding.encoder().encode(d), as: UTF8.self)
        #expect(!json.contains("recentMessages"))
        #expect(d.version == 1)
    }

    @Test func excerptsAreNewestFirstAndBounded() throws {
        var excerpts = (0..<25).map { excerpt("a@b.c", ago: Double($0) * 3600, "msg \($0)") }
        excerpts.append(excerpt("a@b.c", ago: 30 * day + 1, "outside window"))
        excerpts.append(excerpt("a@b.c", ago: -60, "in the future"))
        excerpts.append(excerpt("a@b.c", ago: 30 * day, String(repeating: "z", count: 900)))
        excerpts.shuffle()
        let d = DigestBuilder().build(
            records: [record("a@b.c", ago: day), record("quiet@b.c", ago: day)], excerpts: excerpts, now: now)
        let busy = d.entries.first { $0.handle == "a@b.c" }!
        let recent = try #require(busy.recentMessages)
        #expect(recent.count == MessageExcerptPolicy.maxPerHandle)
        #expect(recent.map(\.text) == (0..<20).map { "msg \($0)" })
        #expect(recent.map(\.date) == recent.map(\.date).sorted(by: >))
        #expect(!recent.contains { $0.text.contains("window") || $0.text.contains("future") })
        // A handle with no text in the window still gets an (empty) list once opted in.
        #expect(d.entries.first { $0.handle == "quiet@b.c" }!.recentMessages == [])
        #expect(d.version == InteractionDigest.currentVersion)
    }

    @Test func excerptsTruncatedAndMergedByNormalizedHandle() {
        let d = DigestBuilder(normalizer: HandleNormalizer(region: "US")).build(
            records: [record("(415) 555-0132", ago: day)],
            excerpts: [
                excerpt("(415) 555-0132", ago: 2 * day, me: true, String(repeating: "é", count: 700)),
                excerpt("+14155550132", ago: day, "newer"),
            ], now: now)
        #expect(d.entries.count == 1)
        let recent = d.entries[0].recentMessages!
        #expect(recent.map(\.fromMe) == [false, true])
        #expect(recent[0].text == "newer")
        #expect(recent[1].text.count == MessageExcerptPolicy.maxCharacters)
    }

    @Test func equalTimestampsPutLaterRowFirst() {
        let d = DigestBuilder().build(
            records: [record("a@b.c", ago: day)],
            excerpts: [excerpt("a@b.c", ago: day, "first row"), excerpt("a@b.c", ago: day, "second row")],
            now: now)
        #expect(d.entries[0].recentMessages?.map(\.text) == ["second row", "first row"])
    }
}

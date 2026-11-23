import Foundation
import GRDB
import HaloCore
import Testing

@testable import HaloBridgeKit

@Suite struct ChatDatabaseReaderTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func fixture(wal: Bool = false) throws -> SyntheticChatDB {
        let db = try SyntheticChatDB(wal: wal)
        let alice = try db.addHandle("+14155550132")
        let bob = try db.addHandle("bob@example.com")
        let carol = try db.addHandle("+14155550199")
        let direct1 = try db.addChat(handles: [alice])
        let direct2 = try db.addChat(handles: [bob])
        let group = try db.addChat(handles: [alice, bob, carol])
        try db.addMessage(chat: direct1, handle: alice, fromMe: false, at: now.addingTimeInterval(-86_400))
        try db.addMessage(
            chat: direct1, handle: alice, fromMe: true, at: now.addingTimeInterval(-3 * 86_400),
            nanoseconds: false)
        try db.addMessage(chat: direct2, handle: bob, fromMe: true, at: now.addingTimeInterval(-86_400))
        try db.addMessage(chat: group, handle: carol, fromMe: false, at: now.addingTimeInterval(-3600))
        try db.addMessage(chat: group, handle: alice, fromMe: false, at: now.addingTimeInterval(-3600))
        return db
    }

    @Test func readsOneToOneOnlyAndConvertsDates() throws {
        let db = try fixture()
        let records = try ChatDatabaseReader(url: db.url).messageRecords()
        #expect(records.count == 3)  // group chat messages excluded
        #expect(!records.contains { $0.handle == "+14155550199" })
        let aliceTimes = records.filter { $0.handle == "+14155550132" }.map(\.date).sorted()
        #expect(aliceTimes == [now.addingTimeInterval(-3 * 86_400), now.addingTimeInterval(-86_400)])
    }

    @Test func endToEndDigest() throws {
        let db = try fixture()
        let digest = DigestBuilder().build(
            records: try ChatDatabaseReader(url: db.url).messageRecords(), now: now)
        #expect(digest.entries.map(\.handle) == ["+14155550132", "bob@example.com"])
        let alice = digest.entries[0]
        #expect(alice.messagesAllTime == 2)
        #expect(alice.awaitingMyReply)
        #expect(!digest.entries[1].awaitingMyReply)
    }

    @Test func snapshotIsReadOnlyAndOriginalUntouched() throws {
        let db = try fixture()
        let before = try Data(contentsOf: db.url)
        let reader = try ChatDatabaseReader(url: db.url)
        #expect(throws: DatabaseError.self) {
            try reader.queue.write { d in try d.execute(sql: "DELETE FROM message") }
        }
        #expect(try Data(contentsOf: db.url) == before)
        // Original is still writable by its owner, i.e. reader held no lock on it.
        let other = try DatabaseQueue(path: db.url.path)
        try other.write { d in try d.execute(sql: "DELETE FROM message WHERE 0") }
    }

    @Test func snapshotCleanedUpOnDeinit() throws {
        let db = try fixture()
        var reader: ChatDatabaseReader? = try ChatDatabaseReader(url: db.url)
        let path = try #require(reader?.queue.path)
        #expect(FileManager.default.fileExists(atPath: path))
        reader = nil
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func missingDatabase() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID()).db")
        #expect(throws: ChatDatabaseError.notFound(path: url.path)) {
            _ = try ChatDatabaseReader(url: url)
        }
    }

    @Test func permissionDeniedMapsToFullDiskAccess() throws {
        let db = try fixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: db.url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: db.url.path)
        }
        if getuid() == 0 { return }  // root ignores permissions
        #expect(throws: ChatDatabaseError.fullDiskAccessRequired(path: db.url.path)) {
            _ = try ChatDatabaseReader(url: db.url)
        }
    }

    @Test func nonDatabaseFileIsUnreadable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("chat.db")
        try Data("not a database, just junk bytes".utf8).write(to: file)
        #expect(throws: ChatDatabaseError.self) {
            _ = try ChatDatabaseReader(url: file).messageRecords()
        }
    }

    @Test func cliWritesMetadataOnlyDigest() throws {
        let db = try fixture()
        let out = db.dir.appendingPathComponent("digest.json")
        let code = BridgeCLI.run(arguments: [
            "digest", "--db", db.url.path, "--out", out.path, "--now", "2027-01-15T08:00:00Z",
        ])
        #expect(code == 0)
        let data = try Data(contentsOf: out)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(SyntheticChatDB.secretText))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let digest = try dec.decode(InteractionDigest.self, from: data)
        #expect(digest.version == InteractionDigest.currentVersion)
        #expect(digest.entries.count == 2)
        #expect(digest.generatedAt == ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
    }

    @Test func cliErrors() throws {
        var messages: [String] = []
        #expect(BridgeCLI.run(arguments: [], errorOutput: { messages.append($0) }) == 64)
        #expect(BridgeCLI.run(arguments: ["digest"], errorOutput: { messages.append($0) }) == 64)
        #expect(
            BridgeCLI.run(
                arguments: ["digest", "--out", "x", "--now", "garbage"], errorOutput: { messages.append($0) })
                == 64)
        #expect(
            BridgeCLI.run(
                arguments: ["digest", "--db", "/nonexistent/chat.db", "--out", "/tmp/x"],
                errorOutput: { messages.append($0) }) == 1)
        #expect(messages.count == 4)
    }

    @Test func uncheckpointedWalIsSnapshotted() throws {
        let db = try fixture(wal: true)  // db stays open: data lives only in the -wal
        let wal = db.url.path + "-wal"
        let size = try FileManager.default.attributesOfItem(atPath: wal)[.size] as? Int ?? 0
        #expect(size > 0)
        let records = try ChatDatabaseReader(url: db.url).messageRecords()
        #expect(records.count == 3)
    }

    @Test func staleSnapshotsAreRemoved() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let stale = tmp.appendingPathComponent("halo-bridge-old")
        let fresh = tmp.appendingPathComponent("halo-bridge-new")
        let other = tmp.appendingPathComponent("unrelated")
        for d in [stale, fresh, other] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        // Directories younger than the threshold are kept.
        #expect(ChatDatabaseReader.removeStaleSnapshots(in: tmp, olderThan: 300) == 0)
        let removed = ChatDatabaseReader.removeStaleSnapshots(
            in: tmp, olderThan: 300, now: Date().addingTimeInterval(400))
        #expect(removed == 3 - 1)  // stale + fresh match the prefix; "unrelated" does not
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func cliOutputIsOwnerOnly() throws {
        let db = try fixture()
        let out = db.dir.appendingPathComponent("perm.json")
        #expect(BridgeCLI.run(arguments: ["digest", "--db", db.url.path, "--out", out.path]) == 0)
        let perms = try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }
}

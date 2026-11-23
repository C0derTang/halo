import Foundation
import GRDB

@testable import HaloBridgeKit

/// Builds a synthetic chat.db using the real-schema subset (no real data).
final class SyntheticChatDB {
    static let secretText = "SECRET-MESSAGE-BODY-DO-NOT-LEAK"

    let dir: URL
    let url: URL
    private let queue: DatabaseQueue
    private var nextMessage: Int64 = 1

    /// `tapbackColumn` adds the modern `message.associated_message_type` column.
    init(wal: Bool = false, tapbackColumn: Bool = false) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "halo-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("chat.db")
        var config = Configuration()
        if wal {
            // Keep writes in the -wal file (never checkpointed) while this queue stays open.
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            }
        }
        queue = try DatabaseQueue(path: url.path, configuration: config)
        if wal { try queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = WAL") } }
        try queue.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, service TEXT);
                    CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT, style INTEGER);
                    CREATE TABLE message (
                        ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT, text TEXT,
                        attributedBody BLOB, handle_id INTEGER, is_from_me INTEGER DEFAULT 0,
                        date INTEGER);
                    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
                    CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
                    """)
            if tapbackColumn {
                try db.execute(
                    sql: "ALTER TABLE message ADD COLUMN associated_message_type INTEGER DEFAULT 0")
            }
        }
    }

    /// Adds a tapback (reaction) row; requires `tapbackColumn`.
    func addTapback(chat: Int64, handle: Int64, fromMe: Bool, at date: Date, type: Int64 = 2000) throws {
        try addMessage(chat: chat, handle: handle, fromMe: fromMe, at: date)
        try queue.write { db in
            try db.execute(
                sql:
                    "UPDATE message SET associated_message_type = ? WHERE ROWID = (SELECT MAX(ROWID) FROM message)",
                arguments: [type])
        }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func addHandle(_ id: String) throws -> Int64 {
        try queue.write { db in
            try db.execute(sql: "INSERT INTO handle (id, service) VALUES (?, 'iMessage')", arguments: [id])
            return db.lastInsertedRowID
        }
    }

    /// Creates a chat containing the given handles; returns its id.
    @discardableResult
    func addChat(handles: [Int64]) throws -> Int64 {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO chat (guid, style) VALUES (?, ?)",
                arguments: [UUID().uuidString, handles.count > 1 ? 43 : 45])
            let chat = db.lastInsertedRowID
            for h in handles {
                try db.execute(sql: "INSERT INTO chat_handle_join VALUES (?, ?)", arguments: [chat, h])
            }
            return chat
        }
    }

    func addMessage(chat: Int64, handle: Int64, fromMe: Bool, rawDate: Int64) throws {
        try queue.write { db in
            try db.execute(
                sql:
                    "INSERT INTO message (guid, text, attributedBody, handle_id, is_from_me, date) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [
                    UUID().uuidString, Self.secretText, Data(Self.secretText.utf8), handle, fromMe ? 1 : 0,
                    rawDate,
                ])
            let id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO chat_message_join VALUES (?, ?)", arguments: [chat, id])
        }
    }

    /// Message at a Unix time, stored as Apple-epoch nanoseconds (modern macOS) or seconds.
    func addMessage(chat: Int64, handle: Int64, fromMe: Bool, at date: Date, nanoseconds: Bool = true) throws
    {
        let secs = Int64(date.timeIntervalSince1970 - AppleDate.appleEpochOffset)
        try addMessage(
            chat: chat, handle: handle, fromMe: fromMe, rawDate: nanoseconds ? secs * 1_000_000_000 : secs)
    }
}

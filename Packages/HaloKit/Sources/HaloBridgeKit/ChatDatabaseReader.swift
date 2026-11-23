import Foundation
import GRDB

public enum ChatDatabaseError: Error, CustomStringConvertible, Equatable {
    case fullDiskAccessRequired(path: String)
    case notFound(path: String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .fullDiskAccessRequired(let path):
            return """
                Cannot read \(path): permission denied.
                Grant Full Disk Access to your terminal (or the halo-bridge binary):
                  System Settings > Privacy & Security > Full Disk Access, enable the app, then re-run.
                """
        case .notFound(let path): return "No chat database found at \(path)."
        case .unreadable(let why): return "Could not read chat database: \(why)"
        }
    }
}

/// Reads message metadata from chat.db.
///
/// Privacy: the original file is never opened by SQLite. It is copied (with its -wal/-shm
/// sidecars) into a private temp directory, and that snapshot is opened read-only.
/// `messageRecords()` selects only `handle.id`, `message.is_from_me` and `message.date`.
/// `text` and `attributedBody` are read only by `recentMessageExcerpts(since:)`, which runs only
/// when the user opts in (`--with-messages`). v1 covers 1:1 chats only: chats whose
/// `chat_handle_join` has exactly one handle. Group chats are excluded.
///
/// Tapbacks/reactions (`associated_message_type != 0`) are excluded when the schema has that
/// column; older schemas without it are read unfiltered (the column is never assumed).
///
/// Each snapshot directory holds an `owner.pid` file; the stale-snapshot sweep never deletes a
/// snapshot whose owner process is still alive (up to a 24 h cap against pid reuse).
public final class ChatDatabaseReader: Sendable {
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Messages/chat.db")
    }

    private let snapshotDir: URL
    let queue: DatabaseQueue

    static let snapshotPrefix = "halo-bridge-"
    static let pidFileName = "owner.pid"

    /// Owner pid recorded in a snapshot directory, if the file exists and holds a valid pid.
    static func ownerPID(of dir: URL) -> pid_t? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(pidFileName)),
            let pid = pid_t(
                String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
            pid > 0  // never probe 0 / negative pids (process groups)
        else { return nil }
        return pid
    }

    /// Whether `pid` names a running process (signal 0 only checks; EPERM still means alive).
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Removes snapshot directories left behind by a crashed run (they hold full message
    /// bodies).
    /// - A snapshot whose `owner.pid` names a live process is kept, but only while the pid file
    ///   is younger than `maxLiveAge` (24 h): a reused pid can't keep message bodies around
    ///   indefinitely, and no real run takes that long.
    /// - A snapshot with a dead owner is removed immediately.
    /// - One without a valid pid file (an owner that has not written it yet, or an older build)
    ///   is removed once older than `olderThan` seconds.
    @discardableResult
    static func removeStaleSnapshots(
        in tempDir: URL = FileManager.default.temporaryDirectory, olderThan age: TimeInterval = 300,
        maxLiveAge: TimeInterval = 24 * 3600, now: Date = Date()
    ) -> Int {
        let fm = FileManager.default
        guard
            let items = try? fm.contentsOfDirectory(
                at: tempDir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return 0 }
        var removed = 0
        for item in items where item.lastPathComponent.hasPrefix(snapshotPrefix) {
            if let pid = ownerPID(of: item) {
                let claimed = modificationDate(item.appendingPathComponent(pidFileName))
                if isAlive(pid), let claimed, now.timeIntervalSince(claimed) < maxLiveAge { continue }
            } else {
                if let modified = modificationDate(item), now.timeIntervalSince(modified) < age { continue }
            }
            if (try? fm.removeItem(at: item)) != nil { removed += 1 }
        }
        return removed
    }

    public init(url: URL) throws {
        let fm = FileManager.default
        Self.removeStaleSnapshots()
        guard fm.fileExists(atPath: url.path) else {
            throw ChatDatabaseError.notFound(path: url.path)
        }
        let dir = fm.temporaryDirectory.appendingPathComponent("\(Self.snapshotPrefix)\(UUID().uuidString)")
        do {
            try fm.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // Claim the snapshot before copying anything into it.
            try Data("\(getpid())\n".utf8).write(to: dir.appendingPathComponent(Self.pidFileName))
            let target = dir.appendingPathComponent("chat.db")
            try fm.copyItem(at: url, to: target)
            // Copy db + wal only. The -shm index is rebuilt by SQLite; copying a live shm could
            // disagree with the copied wal.
            for suffix in ["-wal"] {
                let side = URL(fileURLWithPath: url.path + suffix)
                if fm.fileExists(atPath: side.path) {
                    try fm.copyItem(at: side, to: URL(fileURLWithPath: target.path + suffix))
                }
            }
            var config = Configuration()
            config.readonly = true
            self.queue = try DatabaseQueue(path: target.path, configuration: config)
            self.snapshotDir = dir
        } catch {
            try? fm.removeItem(at: dir)
            throw Self.map(error, path: url.path)
        }
    }

    deinit { try? FileManager.default.removeItem(at: snapshotDir) }

    static func map(_ error: Error, path: String) -> ChatDatabaseError {
        if let e = error as? ChatDatabaseError { return e }
        if let db = error as? DatabaseError {
            switch db.resultCode.primaryResultCode {
            case .SQLITE_AUTH, .SQLITE_PERM, .SQLITE_CANTOPEN:
                return .fullDiskAccessRequired(path: path)
            default: return .unreadable(db.description)
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
            ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError
        {
            return .fullDiskAccessRequired(path: path)
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) {
            return .fullDiskAccessRequired(path: path)
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            let m = map(underlying, path: path)
            if case .fullDiskAccessRequired = m { return m }
        }
        return .unreadable(error.localizedDescription)
    }

    /// SQL shared by both queries: 1:1 chats only, tapbacks excluded when the column exists.
    static func oneToOneQuery(_ db: Database, columns: String, extraFilter: String = "") throws -> String {
        let hasTapbackColumn = try db.columns(in: "message").contains {
            $0.name.lowercased() == "associated_message_type"
        }
        let tapbackFilter =
            hasTapbackColumn
            ? "AND (m.associated_message_type IS NULL OR m.associated_message_type = 0)" : ""
        return """
            SELECT h.id AS handle, m.is_from_me AS is_from_me, m.date AS date\(columns)
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat_handle_join chj ON chj.chat_id = cmj.chat_id
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE cmj.chat_id IN (
                SELECT chat_id FROM chat_handle_join GROUP BY chat_id HAVING COUNT(*) = 1
            )
            \(tapbackFilter)
            \(extraFilter)
            """
    }

    /// Metadata for every message in a 1:1 chat.
    public func messageRecords() throws -> [MessageRecord] {
        do {
            return try queue.read { db in
                try Row.fetchAll(db, sql: try Self.oneToOneQuery(db, columns: "")).compactMap {
                    row -> MessageRecord? in
                    guard let handle: String = row["handle"], let date: Int64 = row["date"] else {
                        return nil
                    }
                    let fromMe: Int64 = row["is_from_me"] ?? 0
                    return MessageRecord(
                        handle: handle, isFromMe: fromMe != 0, date: AppleDate.convert(date))
                }
            }
        } catch {
            throw Self.map(error, path: "chat.db")
        }
    }

    /// Text of 1:1 messages dated at or after `since` (OPT-IN ONLY: `--with-messages`).
    ///
    /// Uses `message.text` when it is readable, else decodes `attributedBody` with
    /// `TypedStreamDecoder`. Messages with no readable text (attachment-only, undecodable) are
    /// skipped; text is cleaned and cut to `MessageExcerptPolicy.maxCharacters`. Rows come back in
    /// `ROWID` order. MESSAGE CONTENT (invariant 6): the result is never logged.
    public func recentMessageExcerpts(since: Date) throws -> [MessageExcerpt] {
        // Pre-filter in SQL so old bodies are never loaded. chat.db mixes Apple-epoch seconds and
        // nanoseconds (see `AppleDate`); this keeps every row that could be in range, and the
        // exact `>= since` check happens after conversion.
        let sinceSeconds = Int64((since.timeIntervalSince1970 - AppleDate.appleEpochOffset).rounded(.down))
        let (sinceNanos, overflow) = sinceSeconds.multipliedReportingOverflow(by: 1_000_000_000)
        let filter = "AND (m.date >= ? OR (m.date < 100000000000 AND m.date >= ?)) ORDER BY m.ROWID"
        do {
            return try queue.read { db in
                let sql = try Self.oneToOneQuery(
                    db, columns: ", m.text AS text, m.attributedBody AS body", extraFilter: filter)
                let args: StatementArguments = [overflow ? Int64.max : sinceNanos, sinceSeconds]
                return try Row.fetchAll(db, sql: sql, arguments: args).compactMap(Self.excerpt(since: since))
            }
        } catch {
            throw Self.map(error, path: "chat.db")
        }
    }

    /// Maps one row to an excerpt. Columns are read through `DatabaseValue` storage so an
    /// unexpected column type yields nil instead of trapping in a typed GRDB subscript.
    static func excerpt(since: Date) -> (Row) -> MessageExcerpt? {
        { row in
            guard case .string(let handle) = (row["handle"] as DatabaseValue).storage,
                case .int64(let raw) = (row["date"] as DatabaseValue).storage
            else { return nil }
            let date = AppleDate.convert(raw)
            guard date >= since else { return nil }
            let text: String?
            switch (row["text"] as DatabaseValue).storage {
            case .string(let s): text = s
            case .blob(let d): text = String(data: d, encoding: .utf8)
            default: text = nil
            }
            let body: Data?
            if case .blob(let d) = (row["body"] as DatabaseValue).storage { body = d } else { body = nil }
            guard let excerpt = MessageExcerptPolicy.messageText(text: text, attributedBody: body) else {
                return nil
            }
            let fromMe: Bool
            if case .int64(let v) = (row["is_from_me"] as DatabaseValue).storage {
                fromMe = v != 0
            } else {
                fromMe = false
            }
            return MessageExcerpt(handle: handle, isFromMe: fromMe, date: date, text: excerpt)
        }
    }
}

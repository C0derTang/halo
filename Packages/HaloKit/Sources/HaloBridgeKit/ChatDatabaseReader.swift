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
/// sidecars) into a private temp directory, and that snapshot is opened read-only. Only
/// `handle.id`, `message.is_from_me` and `message.date` are ever selected; `text` and
/// `attributedBody` are never referenced. v1 covers 1:1 chats only: chats whose
/// `chat_handle_join` has exactly one handle. Group chats are excluded.
public final class ChatDatabaseReader: Sendable {
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Messages/chat.db")
    }

    private let snapshotDir: URL
    let queue: DatabaseQueue

    public init(url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw ChatDatabaseError.notFound(path: url.path)
        }
        let dir = fm.temporaryDirectory.appendingPathComponent("halo-bridge-\(UUID().uuidString)")
        do {
            try fm.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let target = dir.appendingPathComponent("chat.db")
            try fm.copyItem(at: url, to: target)
            for suffix in ["-wal", "-shm"] {
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

    /// Metadata for every message in a 1:1 chat.
    public func messageRecords() throws -> [MessageRecord] {
        let sql = """
            SELECT h.id AS handle, m.is_from_me AS is_from_me, m.date AS date
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat_handle_join chj ON chj.chat_id = cmj.chat_id
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE cmj.chat_id IN (
                SELECT chat_id FROM chat_handle_join GROUP BY chat_id HAVING COUNT(*) = 1
            )
            """
        do {
            return try queue.read { db in
                try Row.fetchAll(db, sql: sql).compactMap { row -> MessageRecord? in
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
}

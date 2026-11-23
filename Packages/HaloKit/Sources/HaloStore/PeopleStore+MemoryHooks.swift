import Foundation
import GRDB
import HaloCore

/// `MemoryStoring`. Hook text is private (invariants 3 + 6): `forget` deletes a person's hooks
/// (explicitly, via `Schema.personScopedTables`, with the FK cascade as a backstop) and
/// `eraseEverything` deletes every row. Every hook deletion marks the erasure pending so the
/// freed bytes are scrubbed from the WAL like any other forgotten data.
extension PeopleStore {
    /// Unexpired hooks (no expiry, or expiring after `now`), newest first.
    public func hooks(for person: PersonID, now: Date) async throws -> [MemoryHook] {
        try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM memory_hook
                    WHERE personId = ? AND (expiresAt IS NULL OR expiresAt > ?)
                    ORDER BY createdAt DESC, id DESC
                    """,
                arguments: [person.description, now.storedValue]
            ).map(RowDecoding.memoryHook)
        }
    }

    /// Throws `unknownPerson` if the owner does not exist, and on a duplicate hook ID.
    public func addHook(_ hook: MemoryHook) async throws {
        try await write { db in try Self.insertHook(hook, in: db) }
    }

    /// Atomically swaps all of the person's hooks of `source` for `hooks`: all-or-nothing, so a
    /// failure leaves the previous hooks untouched. Every hook must belong to `person`.
    public func replaceHooks(for person: PersonID, source: MemoryHook.Source, with hooks: [MemoryHook])
        async throws
    {
        if let stray = hooks.first(where: { $0.personID != person }) {
            throw PeopleStoreError.hookPersonMismatch(hook: stray.id, expected: person)
        }
        try await write { db in
            try db.execute(
                sql: "DELETE FROM memory_hook WHERE personId = ? AND source = ?",
                arguments: [person.description, source.rawValue])
            for hook in hooks {
                // Stored under the requested source, whatever the caller put on the hook.
                var hook = hook
                hook.source = source
                try Self.insertHook(hook, in: db)
            }
            self.markErasurePending()
        }
    }

    public func deleteHook(id: UUID) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM memory_hook WHERE id = ?", arguments: [id.uuidString])
            if db.changesCount > 0 { self.markErasurePending() }
        }
    }

    private static func insertHook(_ hook: MemoryHook, in db: Database) throws {
        guard
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM person WHERE id = ?)",
                arguments: [hook.personID.description]) == true
        else { throw PeopleStoreError.unknownPerson(hook.personID) }
        try db.execute(
            sql: """
                INSERT INTO memory_hook (id, personId, text, source, createdAt, expiresAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                hook.id.uuidString, hook.personID.description, hook.text, hook.source.rawValue,
                hook.createdAt.storedValue, hook.expiresAt?.storedValue,
            ])
    }
}

import Foundation
import GRDB
import HaloCore

/// Internal introspection used by tests to verify schema, pragmas and the forget cascade without
/// the test target importing GRDB directly.
extension PeopleStore {
    func appliedMigrations() async throws -> [String] {
        try await writer.read { db in try Schema.migrator.appliedMigrations(db) }
    }

    func userTables() async throws -> [String] {
        try await writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                    ORDER BY name
                    """)
        }
    }

    func rowCount(_ table: String) async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier)") ?? 0
        }
    }

    /// Integer value of a pragma, read on a reader connection and on the writer connection.
    func pragma(_ name: String) async throws -> (reader: Int?, writer: Int?) {
        let reader = try await writer.read { db in try Int.fetchOne(db, sql: "PRAGMA \(name)") }
        let writerValue = try await writer.write { db in try Int.fetchOne(db, sql: "PRAGMA \(name)") }
        return (reader, writerValue)
    }

    /// For every user table, the number of rows in which *any* column's text mentions `id`.
    /// Catches foreign keys, JSON blobs and anything else that would still reference the person.
    func rowsMentioning(_ id: PersonID) async throws -> [String: Int] {
        let needle = id.description
        return try await writer.read { db in
            var counts: [String: Int] = [:]
            let tables = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                    """)
            for table in tables {
                let columns = try db.columns(in: table).map(\.name)
                let predicate =
                    columns
                    .map { "instr(CAST(\($0.quotedDatabaseIdentifier) AS TEXT), :needle) > 0" }
                    .joined(separator: " OR ")
                counts[table] =
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier) WHERE \(predicate)",
                        arguments: ["needle": needle]) ?? 0
            }
            return counts
        }
    }

    /// Replaces the stored digest payload with arbitrary bytes (to simulate corruption).
    func overwriteDigestJSON(_ json: Data) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO digest (id, version, generatedAt, json) VALUES (1, 1, 0, ?)
                    ON CONFLICT(id) DO UPDATE SET json = excluded.json
                    """,
                arguments: [json])
        }
    }

    /// Opens a read transaction on a reader connection (pinning the current WAL snapshot) and keeps
    /// it open on a background thread until `release()` is called on the returned handle.
    func holdReadTransaction() -> HeldReadTransaction {
        let held = HeldReadTransaction()
        let writer = self.writer
        Thread.detachNewThread {
            try? writer.read { db in
                _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM person")
                held.started.signal()
                held.releaseSignal.wait()
            }
            held.started.signal()  // never leave the caller blocked if the read failed
            held.finished.signal()
        }
        held.started.wait()
        return held
    }
}

final class HeldReadTransaction: Sendable {
    let started = DispatchSemaphore(value: 0)
    let releaseSignal = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)

    /// Ends the read transaction and waits until the reader connection is released.
    func release() {
        releaseSignal.signal()
        finished.wait()
    }
}

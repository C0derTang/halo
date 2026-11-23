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
}

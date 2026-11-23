import GRDB

/// Versioned schema for the people graph. Append new migrations; never edit a shipped one.
enum Schema {
    static let person = "person"
    static let identity = "identity"
    static let embedding = "embedding"
    static let digest = "digest"
    static let recognitionLog = "recognition_log"

    /// Every table that can hold a row about a specific person (by `personId`).
    static let personScopedTables = [identity, embedding, recognitionLog]

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE person (
                        id TEXT PRIMARY KEY NOT NULL,
                        displayName TEXT NOT NULL,
                        relationship TEXT,
                        birthday TEXT,
                        notes TEXT,
                        confirmed INTEGER NOT NULL DEFAULT 0 CHECK (confirmed IN (0, 1)),
                        createdAt REAL NOT NULL,
                        updatedAt REAL NOT NULL
                    );

                    CREATE TABLE identity (
                        personId TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
                        kind TEXT NOT NULL,
                        value TEXT NOT NULL,
                        UNIQUE (kind, value)
                    );
                    CREATE INDEX identity_personId ON identity(personId);

                    CREATE TABLE embedding (
                        id TEXT PRIMARY KEY NOT NULL,
                        personId TEXT REFERENCES person(id) ON DELETE CASCADE,
                        modelID TEXT NOT NULL,
                        dimension INTEGER NOT NULL CHECK (dimension > 0),
                        vector BLOB NOT NULL CHECK (length(vector) = dimension * 4),
                        source TEXT NOT NULL,
                        sourceRef TEXT,
                        quality REAL NOT NULL,
                        createdAt REAL NOT NULL
                    );
                    CREATE INDEX embedding_personId ON embedding(personId);
                    CREATE INDEX embedding_space ON embedding(modelID, dimension);

                    CREATE TABLE digest (
                        id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
                        version INTEGER NOT NULL,
                        generatedAt REAL NOT NULL,
                        json BLOB NOT NULL
                    );

                    CREATE TABLE recognition_log (
                        id INTEGER PRIMARY KEY NOT NULL,
                        personId TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
                        at REAL NOT NULL
                    );
                    CREATE INDEX recognition_log_personId ON recognition_log(personId);
                    """)
        }
        return migrator
    }
}

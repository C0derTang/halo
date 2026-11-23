import GRDB

/// Versioned schema for the people graph. Append new migrations; never edit a shipped one.
enum Schema {
    static let person = "person"
    static let identity = "identity"
    static let embedding = "embedding"
    static let digest = "digest"
    static let recognitionLog = "recognition_log"
    static let cluster = "cluster"
    static let clusterMember = "cluster_member"
    static let scanState = "scan_state"
    static let memoryHook = "memory_hook"

    /// Every table that can hold a row about a specific person (by `personId`).
    static let personScopedTables = [identity, embedding, recognitionLog, memoryHook]

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
        migrator.registerMigration("v2") { db in
            // Clustering suggestions awaiting triage (invariant 3: suggestion only).
            // `suggestedPersonId` cascades as a backstop, but `forget` deletes these clusters AND their
            // member embeddings explicitly; the cascade alone would leave the members behind.
            // `representativeId` is maintained by the store (always one of the cluster's members).
            // Each embedding belongs to at most one cluster; deleting it removes the membership.
            try db.execute(
                sql: """
                    CREATE TABLE cluster (
                        id TEXT PRIMARY KEY NOT NULL,
                        position INTEGER NOT NULL,
                        representativeId TEXT NOT NULL,
                        suggestedPersonId TEXT REFERENCES person(id) ON DELETE CASCADE,
                        cohesion REAL NOT NULL
                    );
                    CREATE INDEX cluster_suggestedPersonId ON cluster(suggestedPersonId);

                    CREATE TABLE cluster_member (
                        clusterId TEXT NOT NULL REFERENCES cluster(id) ON DELETE CASCADE,
                        embeddingId TEXT NOT NULL UNIQUE REFERENCES embedding(id) ON DELETE CASCADE,
                        position INTEGER NOT NULL,
                        PRIMARY KEY (clusterId, embeddingId)
                    );

                    CREATE TABLE scan_state (
                        id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
                        cursor TEXT NOT NULL
                    );
                    """)
        }
        migrator.registerMigration("v4_memoryHooks") { db in
            // Short "what to say" notes per person (invariants 3 + 6). The FK cascade is a backstop;
            // `forget` also deletes these rows explicitly (see `Schema.personScopedTables`).
            try db.execute(
                sql: """
                    CREATE TABLE memory_hook (
                        id TEXT PRIMARY KEY NOT NULL,
                        personId TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
                        text TEXT NOT NULL,
                        source TEXT NOT NULL,
                        createdAt REAL NOT NULL,
                        expiresAt REAL
                    );
                    CREATE INDEX memory_hook_personId ON memory_hook(personId);
                    """)
        }
        return migrator
    }
}

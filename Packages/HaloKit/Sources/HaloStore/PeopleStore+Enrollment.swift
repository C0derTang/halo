import Foundation
import GRDB
import HaloCore

/// Photo-scan + "Who is this?" triage storage (`EnrollmentStoring`).
///
/// Invariant 3: cluster records are suggestions only. Every cluster member is an unassigned
/// embedding (validated on `replaceClusters`, and detached as soon as an embedding gets an owner),
/// and `confirm(cluster:as:)` assigns only still-unassigned members.
extension PeopleStore {
    public func unassignedEmbeddings(space: EmbeddingSpace) async throws -> [FaceEmbedding] {
        try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM embedding
                    WHERE personId IS NULL AND modelID = ? AND dimension = ?
                    ORDER BY createdAt, id
                    """,
                arguments: [space.modelID, space.dimension]
            ).map(RowDecoding.embedding)
        }
    }

    /// The stored embeddings among `ids`, in the order given (missing IDs and repeats skipped).
    public func embeddings(ids: [UUID]) async throws -> [FaceEmbedding] {
        try await writer.read { db in
            let statement = try db.cachedStatement(sql: "SELECT * FROM embedding WHERE id = ?")
            var seen = Set<UUID>()
            var result: [FaceEmbedding] = []
            for id in ids where seen.insert(id).inserted {
                if let row = try Row.fetchOne(statement, arguments: [id.uuidString]) {
                    result.append(try RowDecoding.embedding(row))
                }
            }
            return result
        }
    }

    /// Atomically replaces every stored cluster with `clusters` (kept in this order). Throws
    /// `invalidCluster` and stores nothing if any cluster is empty, has a representative outside its
    /// members, repeats an embedding, names an unknown or already-assigned embedding, or suggests a
    /// person that does not exist.
    public func replaceClusters(_ clusters: [ClusterRecord]) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM cluster")
            let embeddingOwner = try db.cachedStatement(sql: "SELECT personId FROM embedding WHERE id = ?")
            let personExists = try db.cachedStatement(sql: "SELECT 1 FROM person WHERE id = ?")
            let insertCluster = try db.cachedStatement(
                sql: """
                    INSERT INTO cluster (id, position, representativeId, suggestedPersonId, cohesion)
                    VALUES (?, ?, ?, ?, ?)
                    """)
            let insertMember = try db.cachedStatement(
                sql: "INSERT INTO cluster_member (clusterId, embeddingId, position) VALUES (?, ?, ?)")
            var seenIDs = Set<String>()
            var seenMembers = Set<UUID>()
            for (position, cluster) in clusters.enumerated() {
                func invalid(_ reason: PeopleStoreError.ClusterProblem) -> PeopleStoreError {
                    .invalidCluster(id: cluster.id, reason: reason)
                }
                guard seenIDs.insert(cluster.id).inserted else { throw invalid(.duplicateID) }
                guard !cluster.memberIDs.isEmpty else { throw invalid(.empty) }
                guard cluster.memberIDs.contains(cluster.representativeID) else {
                    throw invalid(.representativeNotMember)
                }
                if let suggested = cluster.suggestedPersonID,
                    try Row.fetchOne(personExists, arguments: [suggested.description]) == nil
                {
                    throw invalid(.unknownSuggestedPerson(suggested))
                }
                for member in cluster.memberIDs {
                    guard seenMembers.insert(member).inserted else { throw invalid(.duplicateMember(member)) }
                    guard let row = try Row.fetchOne(embeddingOwner, arguments: [member.uuidString]) else {
                        throw invalid(.unknownMember(member))
                    }
                    guard (row["personId"] as String?) == nil else { throw invalid(.assignedMember(member)) }
                }
                try insertCluster.execute(arguments: [
                    cluster.id, position, cluster.representativeID.uuidString,
                    cluster.suggestedPersonID?.description, Double(cluster.cohesion),
                ])
                for (memberPosition, member) in cluster.memberIDs.enumerated() {
                    try insertMember.execute(arguments: [cluster.id, member.uuidString, memberPosition])
                }
            }
        }
    }

    /// Stored clusters in the order they were saved, members in their saved order.
    public func clusters() async throws -> [ClusterRecord] {
        try await writer.read { db in
            var members: [String: [UUID]] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT clusterId, embeddingId FROM cluster_member ORDER BY clusterId, position")
            {
                let clusterID: String = row["clusterId"]
                members[clusterID, default: []].append(
                    try RowDecoding.uuid(row, "embeddingId", table: Schema.clusterMember))
            }
            return try Row.fetchAll(db, sql: "SELECT * FROM cluster ORDER BY position").map { row in
                let table = Schema.cluster
                let id: String = row["id"]
                let suggested: String? = row["suggestedPersonId"]
                return ClusterRecord(
                    id: id, memberIDs: members[id] ?? [],
                    representativeID: try RowDecoding.uuid(row, "representativeId", table: table),
                    suggestedPersonID: suggested == nil
                        ? nil : try RowDecoding.personID(row, "suggestedPersonId", table: table),
                    cohesion: Float(row["cohesion"] as Double))
            }
        }
    }

    /// One transaction: assigns the cluster's still-existing, still-unassigned members to
    /// `person`, marks `person` confirmed, adds the `.photoCluster` identity (value = cluster ID)
    /// and deletes the cluster record.
    ///
    /// If no member embedding remains (all were deleted during triage), the stale record is deleted,
    /// the person is NOT confirmed, and `emptyCluster` is thrown.
    public func confirm(cluster id: String, as person: PersonID) async throws {
        let key = person.description
        let assignedAny = try await write { db -> Bool in
            guard try Row.fetchOne(db, sql: "SELECT 1 FROM cluster WHERE id = ?", arguments: [id]) != nil
            else { throw PeopleStoreError.unknownCluster(id: id) }
            guard try Row.fetchOne(db, sql: "SELECT 1 FROM person WHERE id = ?", arguments: [key]) != nil
            else { throw PeopleStoreError.unknownPerson(person) }

            try db.execute(
                sql: """
                    UPDATE embedding SET personId = ?
                    WHERE personId IS NULL
                      AND id IN (SELECT embeddingId FROM cluster_member WHERE clusterId = ?)
                    """,
                arguments: [key, id])
            let assigned = db.changesCount
            if assigned > 0 {
                try db.execute(
                    sql: "UPDATE person SET confirmed = 1, updatedAt = ? WHERE id = ?",
                    arguments: [Date().storedValue, key])
                try Self.insertIdentity(Identity(personID: person, kind: .photoCluster, value: id), in: db)
            }
            try db.execute(sql: "DELETE FROM cluster WHERE id = ?", arguments: [id])
            return assigned > 0
        }
        // Thrown after the commit so the stale record's deletion sticks.
        guard assignedAny else { throw PeopleStoreError.emptyCluster(id: id) }
    }

    /// Deletes these embeddings outright (any owner), pruning them from clusters: a cluster whose
    /// representative was deleted gets its first remaining member, and an emptied cluster is
    /// deleted. The bytes are erased from disk on the next successful checkpoint.
    public func deleteEmbeddings(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try await write { db in
            let delete = try db.cachedStatement(sql: "DELETE FROM embedding WHERE id = ?")
            var deleted = 0
            for id in Set(ids) {
                try delete.execute(arguments: [id.uuidString])  // cascades cluster_member
                deleted += db.changesCount
            }
            guard deleted > 0 else { return }
            try Self.repairClusters(in: db)
            self.markErasurePending()
        }
    }

    public func removeIdentity(_ identity: Identity) async throws {
        try await write { db in
            try db.execute(
                sql: "DELETE FROM identity WHERE personId = ? AND kind = ? AND value = ?",
                arguments: [identity.personID.description, identity.kind.rawValue, identity.value])
        }
    }

    public func scanCursor() async throws -> String? {
        try await writer.read { db in
            try String.fetchOne(db, sql: "SELECT cursor FROM scan_state WHERE id = 1")
        }
    }

    /// `nil` clears the cursor (the next scan starts from the beginning).
    public func setScanCursor(_ cursor: String?) async throws {
        try await write { db in
            if let cursor {
                try db.execute(
                    sql: """
                        INSERT INTO scan_state (id, cursor) VALUES (1, ?)
                        ON CONFLICT(id) DO UPDATE SET cursor = excluded.cursor
                        """,
                    arguments: [cursor])
            } else {
                try db.execute(sql: "DELETE FROM scan_state")
            }
        }
    }

    // MARK: - Cluster maintenance (inside a write transaction)

    /// Removes these embeddings from any cluster (they now belong to a person).
    static func detachFromClusters(_ ids: [UUID], in db: Database) throws {
        let detach = try db.cachedStatement(sql: "DELETE FROM cluster_member WHERE embeddingId = ?")
        for id in ids {
            try detach.execute(arguments: [id.uuidString])
        }
        try repairClusters(in: db)
    }

    /// Deletes clusters left without members and re-points a representative that is no longer a
    /// member at the cluster's first remaining member.
    static func repairClusters(in db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM cluster
                WHERE NOT EXISTS (SELECT 1 FROM cluster_member WHERE clusterId = cluster.id);

                UPDATE cluster SET representativeId = (
                    SELECT embeddingId FROM cluster_member
                    WHERE clusterId = cluster.id ORDER BY position LIMIT 1)
                WHERE NOT EXISTS (
                    SELECT 1 FROM cluster_member
                    WHERE clusterId = cluster.id AND embeddingId = cluster.representativeId);
                """)
    }
}

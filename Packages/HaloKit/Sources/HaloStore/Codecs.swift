import Foundation
import GRDB
import HaloCore

public enum PeopleStoreError: Error, Equatable, Sendable {
    /// The embedding's vector length does not equal its space's dimension.
    case dimensionMismatch(expected: Int, actual: Int)
    /// The (kind, value) identity already belongs to a different person.
    case identityConflict(kind: Identity.Kind, value: String, existingOwner: PersonID)
    /// A stored row could not be decoded.
    case corruptRow(table: String, column: String)
    /// No person with this ID exists.
    case unknownPerson(PersonID)
    /// No stored cluster record with this ID exists.
    case unknownCluster(id: String)
    /// None of the cluster's member embeddings exist any more (all deleted during triage). The
    /// stale record was deleted and the person was NOT confirmed.
    case emptyCluster(id: String)
    /// A hook passed to `replaceHooks` belongs to a different person than the one being replaced.
    case hookPersonMismatch(hook: UUID, expected: PersonID)
    /// A cluster passed to `replaceClusters` is malformed (a caller bug); nothing was stored.
    /// Stale state (deleted/assigned members, a forgotten suggested person) is pruned, not thrown.
    case invalidCluster(id: String, reason: ClusterProblem)

    public enum ClusterProblem: Equatable, Sendable {
        /// Two clusters share this ID.
        case duplicateID
        /// The cluster was passed with no members.
        case empty
        /// `representativeID` is not one of `memberIDs`.
        case representativeNotMember
        /// The embedding is listed twice (in this cluster or in another one).
        case duplicateMember(UUID)
    }
}

/// Embedding vectors are stored as a packed little-endian IEEE-754 Float32 BLOB.
/// Encoding goes through `bitPattern`, so round trips are bit-exact (incl. -0, NaN payloads).
enum VectorCodec {
    static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) -> [Float]? {
        guard data.count % 4 == 0 else { return nil }
        let bytes = [UInt8](data)
        var vector = [Float]()
        vector.reserveCapacity(bytes.count / 4)
        var index = 0
        while index < bytes.count {
            let bits =
                UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16
                | UInt32(bytes[index + 3]) << 24
            vector.append(Float(bitPattern: bits))
            index += 4
        }
        return vector
    }
}

/// Dates are stored as `timeIntervalSinceReferenceDate` doubles so they round-trip exactly.
extension Date {
    var storedValue: Double { timeIntervalSinceReferenceDate }
    init(storedValue: Double) { self.init(timeIntervalSinceReferenceDate: storedValue) }
}

enum RowDecoding {
    static func personID(_ row: Row, _ column: String, table: String) throws -> PersonID {
        guard let string: String = row[column], let uuid = UUID(uuidString: string) else {
            throw PeopleStoreError.corruptRow(table: table, column: column)
        }
        return PersonID(uuid)
    }

    static func uuid(_ row: Row, _ column: String, table: String) throws -> UUID {
        guard let string: String = row[column], let uuid = UUID(uuidString: string) else {
            throw PeopleStoreError.corruptRow(table: table, column: column)
        }
        return uuid
    }

    static func person(_ row: Row) throws -> Person {
        let table = Schema.person
        var birthday: DateComponents?
        if let json: String = row["birthday"] {
            do {
                birthday = try JSONDecoder().decode(DateComponents.self, from: Data(json.utf8))
            } catch {
                throw PeopleStoreError.corruptRow(table: table, column: "birthday")
            }
        }
        return Person(
            id: try personID(row, "id", table: table),
            displayName: row["displayName"],
            relationship: row["relationship"],
            birthday: birthday,
            notes: row["notes"],
            confirmed: row["confirmed"],
            createdAt: Date(storedValue: row["createdAt"]),
            updatedAt: Date(storedValue: row["updatedAt"]))
    }

    static func identity(_ row: Row) throws -> Identity {
        let table = Schema.identity
        guard let rawKind: String = row["kind"], let kind = Identity.Kind(rawValue: rawKind) else {
            throw PeopleStoreError.corruptRow(table: table, column: "kind")
        }
        return Identity(
            personID: try personID(row, "personId", table: table), kind: kind, value: row["value"])
    }

    static func embedding(_ row: Row) throws -> FaceEmbedding {
        let table = Schema.embedding
        guard let idString: String = row["id"], let id = UUID(uuidString: idString) else {
            throw PeopleStoreError.corruptRow(table: table, column: "id")
        }
        let space = EmbeddingSpace(modelID: row["modelID"], dimension: row["dimension"])
        guard let blob: Data = row["vector"], let vector = VectorCodec.decode(blob),
            vector.count == space.dimension
        else {
            throw PeopleStoreError.corruptRow(table: table, column: "vector")
        }
        guard let rawSource: String = row["source"], let source = FaceEmbedding.Source(rawValue: rawSource)
        else {
            throw PeopleStoreError.corruptRow(table: table, column: "source")
        }
        let ownerString: String? = row["personId"]
        let owner: PersonID? = ownerString == nil ? nil : try personID(row, "personId", table: table)
        var faceBox: CGRect?
        if let x: Double = row["faceBoxX"], let y: Double = row["faceBoxY"],
            let width: Double = row["faceBoxWidth"], let height: Double = row["faceBoxHeight"]
        {
            faceBox = CGRect(x: x, y: y, width: width, height: height)
        }
        return FaceEmbedding(
            id: id, personID: owner, space: space, vector: vector, source: source,
            sourceRef: row["sourceRef"], quality: Float(row["quality"] as Double),
            createdAt: Date(storedValue: row["createdAt"]), faceBox: faceBox)
    }

    static func memoryHook(_ row: Row) throws -> MemoryHook {
        let table = Schema.memoryHook
        guard let rawSource: String = row["source"], let source = MemoryHook.Source(rawValue: rawSource)
        else {
            throw PeopleStoreError.corruptRow(table: table, column: "source")
        }
        let expires: Double? = row["expiresAt"]
        return MemoryHook(
            id: try uuid(row, "id", table: table), personID: try personID(row, "personId", table: table),
            text: row["text"], source: source, createdAt: Date(storedValue: row["createdAt"]),
            expiresAt: expires.map(Date.init(storedValue:)))
    }

    static func encodeBirthday(_ birthday: DateComponents?) throws -> String? {
        guard let birthday else { return nil }
        return String(decoding: try JSONEncoder().encode(birthday), as: UTF8.self)
    }
}

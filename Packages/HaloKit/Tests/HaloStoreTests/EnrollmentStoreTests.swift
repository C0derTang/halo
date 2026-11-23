import Foundation
import HaloCore
import Testing

@testable import HaloStore

/// Shared setup: one confirmed and one unconfirmed person, plus six unassigned faces.
struct EnrollmentWorld {
    let store: PeopleStore
    let known: Person
    let newcomer: Person
    let faces: [FaceEmbedding]

    init(store: PeopleStore? = nil) async throws {
        let store = try store ?? PeopleStore.inMemory()
        self.store = store
        known = Fixture.person("Known Example", confirmed: true)
        newcomer = Fixture.person("Newcomer Example", confirmed: false)
        try await store.upsert(known)
        try await store.upsert(newcomer)
        try await store.addEmbeddings([Fixture.embedding(for: known.id, seed: 0.9)])
        faces = (0..<6).map { Fixture.traceableEmbedding(for: nil, tag: $0) }
        try await store.addEmbeddings(faces)
    }

    func ids(_ indices: Int...) -> [UUID] { indices.map { faces[$0].id } }

    func cluster(
        _ id: String, _ members: [UUID], suggested: PersonID? = nil, cohesion: Float = 0.75
    ) -> ClusterRecord {
        ClusterRecord(
            id: id, memberIDs: members, representativeID: members.first ?? UUID(),
            suggestedPersonID: suggested, cohesion: cohesion)
    }
}

@Suite struct EnrollmentQueryTests {
    @Test func unassignedEmbeddingsAreSpaceExact() async throws {
        let world = try await EnrollmentWorld()
        let store = world.store
        try await store.addEmbeddings([
            Fixture.embedding(for: nil, space: Fixture.spaceOtherModel),
            Fixture.embedding(for: nil, space: Fixture.spaceSameModelOtherDim),
            Fixture.embedding(for: world.newcomer.id),  // assigned (unconfirmed owner): not unassigned
        ])

        let unassigned = try await store.unassignedEmbeddings(space: Fixture.spaceA)
        #expect(unassigned == world.faces)  // ordered by createdAt
        #expect(unassigned.allSatisfy { $0.personID == nil && $0.space == Fixture.spaceA })
        #expect(try await store.unassignedEmbeddings(space: Fixture.spaceOtherModel).count == 1)
        #expect(try await store.unassignedEmbeddings(space: Fixture.spaceSameModelOtherDim).count == 1)
        #expect(
            try await store.unassignedEmbeddings(space: EmbeddingSpace(modelID: "unknown", dimension: 4))
                .isEmpty)
    }

    @Test func embeddingsByIDKeepOrderAndSkipMissingAndRepeats() async throws {
        let world = try await EnrollmentWorld()
        let fetched = try await world.store.embeddings(
            ids: [world.faces[3].id, UUID(), world.faces[1].id, world.faces[3].id])
        #expect(fetched == [world.faces[3], world.faces[1]])
        #expect(try await world.store.embeddings(ids: []).isEmpty)
    }

    @Test func scanCursorRoundTrip() async throws {
        let store = try PeopleStore.inMemory()
        #expect(try await store.scanCursor() == nil)
        try await store.setScanCursor("synthetic-cursor-1")
        #expect(try await store.scanCursor() == "synthetic-cursor-1")
        try await store.setScanCursor("synthetic-cursor-2")
        #expect(try await store.scanCursor() == "synthetic-cursor-2")
        #expect(try await store.rowCount("scan_state") == 1)
        try await store.setScanCursor(nil)
        #expect(try await store.scanCursor() == nil)
        #expect(try await store.rowCount("scan_state") == 0)
    }

    @Test func scanCursorPersistsAcrossReopen() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await PeopleStore(path: path).setScanCursor("synthetic-cursor-9")
        #expect(try await PeopleStore(path: path).scanCursor() == "synthetic-cursor-9")
    }

    @Test func removeIdentityRemovesOnlyThatIdentity() async throws {
        let world = try await EnrollmentWorld()
        let store = world.store
        let cluster = Identity(personID: world.known.id, kind: .photoCluster, value: "synthetic-cluster")
        let email = Identity(personID: world.known.id, kind: .email, value: "known@example.com")
        try await store.addIdentity(cluster)
        try await store.addIdentity(email)
        // Same (kind, value) but a different owner is not this identity: no-op.
        try await store.removeIdentity(
            Identity(personID: world.newcomer.id, kind: .email, value: "known@example.com"))
        #expect(try await store.identities(for: world.known.id).count == 2)

        try await store.removeIdentity(cluster)
        #expect(try await store.identities(for: world.known.id) == [email])
        #expect(try await store.person(matching: .photoCluster, value: "synthetic-cluster") == nil)
        try await store.removeIdentity(cluster)  // idempotent
    }
}

@Suite struct ReplaceClustersTests {
    @Test func roundTripPreservesOrderAndFields() async throws {
        let world = try await EnrollmentWorld()
        let clusters = [
            world.cluster("c-b", world.ids(2, 0, 4), suggested: world.known.id, cohesion: 0.123_456_7),
            world.cluster("c-a", world.ids(5), cohesion: 1),
        ]
        try await world.store.replaceClusters(clusters)
        #expect(try await world.store.clusters() == clusters)
    }

    @Test func replacesEveryPreviousCluster() async throws {
        let world = try await EnrollmentWorld()
        try await world.store.replaceClusters([
            world.cluster("old-1", world.ids(0, 1)), world.cluster("old-2", world.ids(2)),
        ])
        let next = [world.cluster("new-1", world.ids(1, 2, 3))]
        try await world.store.replaceClusters(next)
        #expect(try await world.store.clusters() == next)
        #expect(try await world.store.rowCount("cluster_member") == 3)

        try await world.store.replaceClusters([])
        #expect(try await world.store.clusters().isEmpty)
        #expect(try await world.store.rowCount("cluster_member") == 0)
        // Clusters are suggestions only: replacing them never touches the embeddings.
        #expect(try await world.store.unassignedEmbeddings(space: Fixture.spaceA) == world.faces)
    }

    @Test func callerBugsAreRejectedAtomically() async throws {
        let world = try await EnrollmentWorld()
        let store = world.store
        let existing = [world.cluster("keep", world.ids(0, 1), suggested: world.known.id)]
        try await store.replaceClusters(existing)
        let valid = world.cluster("valid", world.ids(2, 3))

        var representativeOutside = world.cluster("bad", world.ids(4))
        representativeOutside.representativeID = world.faces[5].id
        let cases: [(ClusterRecord, PeopleStoreError.ClusterProblem)] = [
            (world.cluster("bad", []), .empty),
            (representativeOutside, .representativeNotMember),
            (world.cluster("bad", world.ids(4, 4)), .duplicateMember(world.faces[4].id)),
            (world.cluster("bad", world.ids(2)), .duplicateMember(world.faces[2].id)),  // also in `valid`
            (world.cluster("valid", world.ids(4)), .duplicateID),
        ]
        for (bad, problem) in cases {
            let expectedID = bad.id
            await #expect(throws: PeopleStoreError.invalidCluster(id: expectedID, reason: problem)) {
                try await store.replaceClusters([valid, bad])
            }
            // Nothing from the failed call was applied; the previous clusters are intact.
            #expect(try await store.clusters() == existing)
        }
    }

    @Test func deletedMembersArePrunedAndRepresentativeRepointed() async throws {
        let world = try await EnrollmentWorld()
        let store = world.store
        // The scan clustered faces 0-2; the user rejected face 0 (the representative) meanwhile.
        try await store.deleteEmbeddings(ids: world.ids(0))
        try await store.replaceClusters([world.cluster("c", world.ids(0, 1, 2))])

        let stored = try #require(try await store.clusters().first)
        #expect(stored.memberIDs == world.ids(1, 2))
        #expect(stored.representativeID == world.faces[1].id)
        #expect(try await store.rowCount("cluster_member") == 2)
    }

    @Test func membersThatGotAnOwnerArePruned() async throws {
        let world = try await EnrollmentWorld()
        let store = world.store
        // Face 2 was confirmed as the newcomer between clustering and saving.
        try await store.replaceClusters([world.cluster("first", world.ids(2, 3))])
        try await store.confirm(cluster: "first", as: world.newcomer.id)
        let ownedByKnown = try #require(
            try await store.confirmedGallery(space: Fixture.spaceA).first {
                $0.personID == world.known.id
            })

        var stale = world.cluster("c", [ownedByKnown.id] + world.ids(2, 4))
        stale.representativeID = world.faces[4].id
        try await store.replaceClusters([stale])

        let stored = try #require(try await store.clusters().first)
        #expect(stored.memberIDs == world.ids(4))
        #expect(stored.representativeID == world.faces[4].id)  // still a member: kept
        // Owned faces were left with their owners.
        #expect(try await store.embeddings(ids: world.ids(2)).first?.personID == world.newcomer.id)
        #expect(try await store.embeddings(ids: [ownedByKnown.id]).first?.personID == world.known.id)
    }

    @Test func clustersLeftEmptyAreDropped() async throws {
        let world = try await EnrollmentWorld()
        let store = world.store
        try await store.deleteEmbeddings(ids: world.ids(0, 1))
        try await store.replaceClusters([
            world.cluster("gone", world.ids(0, 1)), world.cluster("ghost", [UUID()]),
            world.cluster("kept", world.ids(2)),
        ])
        #expect(try await store.clusters() == [world.cluster("kept", world.ids(2))])
    }

    @Test func clusterSuggestingAForgottenPersonIsDroppedWithItsFaces() async throws {
        let world = try await EnrollmentWorld()
        let store = world.store
        // The scan suggested `known`, who the user forgot before the scan saved its clusters.
        let clusters = [
            world.cluster("forgotten", world.ids(0, 1), suggested: world.known.id),
            world.cluster("kept", world.ids(2, 3), suggested: world.newcomer.id),
            world.cluster("ghost", world.ids(4), suggested: PersonID()),
        ]
        try await store.forget(world.known.id)
        try await store.replaceClusters(clusters)

        #expect(try await store.clusters() == [clusters[1]])
        #expect(try await store.embeddings(ids: world.ids(0, 1, 4)).isEmpty)
        #expect(try await store.embeddings(ids: world.ids(2, 3, 5)).count == 3)
        #expect(try await store.rowsMentioning(world.known.id).values.reduce(0, +) == 0)
    }

    @Test func forgottenSuggestionFacesAreErasedFromDisk() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let world = try await EnrollmentWorld(store: PeopleStore(path: path))
        let doomed = world.faces[0...1].flatMap(Fixture.needles(for:))
        try await world.store.forget(world.known.id)
        #expect(!Fixture.rawTraces(of: doomed, at: path).isEmpty)

        try await world.store.replaceClusters([
            world.cluster("forgotten", world.ids(0, 1), suggested: world.known.id)
        ])

        #expect(!world.store.hasPendingErasure)
        #expect(Fixture.rawTraces(of: doomed, at: path) == [])
    }

    @Test func clusterRecordsNeverMakeAnyoneRecognizable() async throws {
        let world = try await EnrollmentWorld()
        try await world.store.replaceClusters([
            world.cluster("suggest-known", world.ids(0, 1), suggested: world.known.id)
        ])
        let gallery = try await world.store.confirmedGallery(space: Fixture.spaceA)
        #expect(gallery.count == 1)  // only the known person's own enrolled face
        #expect(gallery.allSatisfy { $0.personID == world.known.id && !world.faces.contains($0) })
    }
}

@Suite struct ConfirmClusterTests {
    @Test func confirmIsOneTransactionThatEnrollsThePerson() async throws {
        let world = try await EnrollmentWorld()
        let store = world.store
        try await store.replaceClusters([
            world.cluster("cluster-x", world.ids(0, 1, 2), suggested: world.known.id),
            world.cluster("cluster-y", world.ids(3, 4)),
        ])
        #expect(try await store.confirmedGallery(space: Fixture.spaceA).count == 1)

        // The user overrides the suggestion and says this is the newcomer.
        try await store.confirm(cluster: "cluster-x", as: world.newcomer.id)

        let newcomer = try #require(try await store.person(world.newcomer.id))
        #expect(newcomer.confirmed)
        #expect(newcomer.displayName == world.newcomer.displayName)
        #expect(
            try await store.identities(for: world.newcomer.id) == [
                Identity(personID: world.newcomer.id, kind: .photoCluster, value: "cluster-x")
            ])
        #expect(try await store.person(matching: .photoCluster, value: "cluster-x")?.id == world.newcomer.id)
        #expect(try await store.clusters().map(\.id) == ["cluster-y"])
        #expect(try await store.rowCount("cluster_member") == 2)

        let gallery = try await store.confirmedGallery(space: Fixture.spaceA)
        let enrolled = gallery.filter { $0.personID == world.newcomer.id }
        #expect(Set(enrolled.map(\.id)) == Set(world.ids(0, 1, 2)))
        #expect(gallery.count == 4)
        #expect(
            Set(try await store.unassignedEmbeddings(space: Fixture.spaceA).map(\.id))
                == Set(world.ids(3, 4, 5)))
    }

    @Test func confirmToleratesMembersDeletedDuringTriage() async throws {
        let world = try await EnrollmentWorld()
        let store = world.store
        try await store.replaceClusters([world.cluster("cluster-x", world.ids(0, 1, 2))])

        // "Not this person" on the representative: pruned from the record, representative moves.
        try await store.deleteEmbeddings(ids: world.ids(0))
        let pruned = try #require(try await store.clusters().first)
        #expect(pruned.memberIDs == world.ids(1, 2))
        #expect(pruned.representativeID == world.faces[1].id)

        try await store.confirm(cluster: "cluster-x", as: world.newcomer.id)
        let enrolled = try await store.confirmedGallery(space: Fixture.spaceA)
            .filter { $0.personID == world.newcomer.id }
        #expect(Set(enrolled.map(\.id)) == Set(world.ids(1, 2)))
        #expect(try await store.clusters().isEmpty)
    }

    @Test func confirmOfMemberlessRecordDeletesItAndDoesNotConfirm() async throws {
        let world = try await EnrollmentWorld()
        let store = world.store
        try await store.replaceClusters([world.cluster("cluster-x", world.ids(0, 1))])
        try await store.simulateStaleClusterRecord("cluster-x")

        await #expect(throws: PeopleStoreError.emptyCluster(id: "cluster-x")) {
            try await store.confirm(cluster: "cluster-x", as: world.newcomer.id)
        }
        #expect(try await store.person(world.newcomer.id)?.confirmed == false)
        #expect(try await store.identities(for: world.newcomer.id).isEmpty)
        #expect(try await store.clusters().isEmpty)  // the stale record is gone
        #expect(try await store.unassignedEmbeddings(space: Fixture.spaceA) == world.faces)
    }

    @Test func confirmNeverReassignsAnEmbeddingThatGotAnOwner() async throws {
        let world = try await EnrollmentWorld()
        let store = world.store
        try await store.replaceClusters([world.cluster("cluster-x", world.ids(0, 1))])
        // Face 0 is enrolled for the known person by another path; it leaves the cluster.
        var claimed = world.faces[0]
        claimed.personID = world.known.id
        try await store.addEmbeddings([claimed])
        #expect(try await store.clusters().first?.memberIDs == world.ids(1))
        #expect(try await store.clusters().first?.representativeID == world.faces[1].id)

        try await store.confirm(cluster: "cluster-x", as: world.newcomer.id)
        #expect(try await store.embeddings(ids: world.ids(0)).first?.personID == world.known.id)
        #expect(try await store.embeddings(ids: world.ids(1)).first?.personID == world.newcomer.id)
    }

    @Test func confirmFailuresChangeNothing() async throws {
        let world = try await EnrollmentWorld()
        let store = world.store
        let clusters = [world.cluster("cluster-x", world.ids(0, 1))]
        try await store.replaceClusters(clusters)

        await #expect(throws: PeopleStoreError.unknownCluster(id: "nope")) {
            try await store.confirm(cluster: "nope", as: world.newcomer.id)
        }
        let ghost = PersonID()
        await #expect(throws: PeopleStoreError.unknownPerson(ghost)) {
            try await store.confirm(cluster: "cluster-x", as: ghost)
        }
        // The cluster ID is already someone else's identity: the whole transaction rolls back.
        try await store.addIdentity(
            Identity(personID: world.known.id, kind: .photoCluster, value: "cluster-x"))
        await #expect(
            throws: PeopleStoreError.identityConflict(
                kind: .photoCluster, value: "cluster-x", existingOwner: world.known.id)
        ) {
            try await store.confirm(cluster: "cluster-x", as: world.newcomer.id)
        }

        #expect(try await store.clusters() == clusters)
        #expect(try await store.person(world.newcomer.id)?.confirmed == false)
        #expect(try await store.unassignedEmbeddings(space: Fixture.spaceA) == world.faces)
        #expect(try await store.identities(for: world.newcomer.id).isEmpty)
    }
}

@Suite struct DeleteEmbeddingsTests {
    @Test func deleteRemovesEmbeddingsAndPrunesClusters() async throws {
        let world = try await EnrollmentWorld()
        let store = world.store
        try await store.replaceClusters([
            world.cluster("a", world.ids(0, 1, 2)), world.cluster("b", world.ids(3, 4)),
            world.cluster("c", world.ids(5)),
        ])

        try await store.deleteEmbeddings(ids: world.ids(1, 3, 4) + [UUID()])

        #expect(try await store.embeddings(ids: world.ids(1, 3, 4)).isEmpty)
        let clusters = try await store.clusters()
        #expect(clusters.map(\.id) == ["a", "c"])  // "b" lost every member and is gone
        #expect(clusters[0].memberIDs == world.ids(0, 2))
        #expect(clusters[0].representativeID == world.faces[0].id)  // unchanged: still a member
        #expect(try await store.rowCount("cluster_member") == 3)
        #expect(try await store.rowCount("embedding") == 4)  // 1 enrolled + 3 remaining faces

        try await store.deleteEmbeddings(ids: [])
        #expect(try await store.rowCount("embedding") == 4)
    }

    @Test func deletedFacesAreErasedFromDisk() async throws {
        let (directory, path) = try Fixture.temporaryDatabasePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let world = try await EnrollmentWorld(store: PeopleStore(path: path))
        let rejected = world.faces[2]
        #expect(!Fixture.rawTraces(of: Fixture.needles(for: rejected), at: path).isEmpty)

        try await world.store.deleteEmbeddings(ids: [rejected.id])

        #expect(!world.store.hasPendingErasure)
        #expect(Fixture.rawTraces(of: Fixture.needles(for: rejected), at: path) == [])
        #expect(!Fixture.rawTraces(of: Fixture.needles(for: world.faces[3]), at: path).isEmpty)
    }
}

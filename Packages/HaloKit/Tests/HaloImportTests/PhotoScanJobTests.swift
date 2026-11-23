import CoreGraphics
import Foundation
import HaloClustering
import HaloCore
import ImageIO
import Testing

@testable import HaloImport

private typealias F = PhotoScanFixture

private func makeJob(
    _ library: InMemoryPhotoLibrary, _ detector: ScriptedDetector, _ store: PhotoScanFakeStore,
    embedder: SyntheticEmbedder = SyntheticEmbedder(), config: PhotoScanConfig = PhotoScanConfig(),
    uprighter: (any PhotoScanUprighting)? = nil,
    isSystemicFailure: @escaping @Sendable (any Error) -> Bool = { _ in false }
) -> PhotoScanJob {
    PhotoScanJob(
        source: library, detector: detector, embedder: embedder, store: store, clusterer: FaceClusterer(),
        config: config, uprighter: uprighter ?? CoreImageUprighter(), isSystemicFailure: isSystemicFailure)
}

/// One face per asset, identities cycling so clustering has something to do.
private func oneFaceEach(_ count: Int) -> [[FaceObservation]] {
    (0..<count).map { [F.face(identity: $0 % 3, jitter: Double($0) * 0.01)] }
}

private func refs(_ embeddings: [FaceEmbedding]) -> [String] {
    embeddings.compactMap(\.sourceRef).sorted()
}

@Suite struct PhotoScanJobTests {
    // MARK: Batches + unassigned embeddings

    @Test func scansNewestFirstInBatchesAndStoresUnassignedEmbeddings() async throws {
        let (library, detector) = F.library(oneFaceEach(7))
        let store = PhotoScanFakeStore()
        let embedder = SyntheticEmbedder()
        let job = makeJob(
            library, detector, store, embedder: embedder, config: PhotoScanConfig(batchSize: 3))
        let result = try await job.run()

        let stored = await store.embeddings
        #expect(stored.count == 7)
        #expect(stored.allSatisfy { $0.personID == nil })
        #expect(stored.allSatisfy { $0.source == .photoLibrary && $0.space == embedder.space })
        #expect(refs(stored) == (0..<7).map { "asset-\($0)" }.sorted())
        #expect(await library.loadedIdentifiers == (0..<7).map { "asset-\($0)" })
        #expect(result.batchesCompleted == 3)
        #expect(result.facesEmbedded == 7)
        #expect(result.phase == .finished)
        // One cursor write per batch plus the pass-complete write.
        #expect(await store.cursorWrites == 4)
        let cursor = await F.decodedCursor(store, space: embedder.space)
        #expect(cursor.completedTop == F.asset(0))
        #expect(cursor.resumeAfter == nil && cursor.passTop == nil)

        var phases: [ScanProgress.Phase] = []
        for await p in job.progress { phases.append(p.phase) }
        #expect(phases.first == .scanning)
        #expect(phases.last == .finished)
        #expect(phases.contains(.clustering))
    }

    // MARK: Resume

    @Test func resumeAfterSimulatedKillProducesNoDuplicates() async throws {
        let (library, detector) = F.library(oneFaceEach(7))
        let store = PhotoScanFakeStore()
        // Batch 2's embeddings land, then the process "dies" before its cursor write.
        await store.setFailCursorWrite(2)
        let config = PhotoScanConfig(batchSize: 3)
        await #expect(throws: PhotoScanFakeStore.SimulatedKill.self) {
            try await makeJob(library, detector, store, config: config).run()
        }
        #expect(await store.embeddings.count == 6)

        await store.setFailCursorWrite(nil)
        let loadsBefore = await library.loadedIdentifiers.count
        let result = try await makeJob(library, detector, store, config: config).run()

        let stored = await store.embeddings
        #expect(stored.count == 7)
        #expect(Set(refs(stored)).count == 7)
        // Batch 1 is behind the cursor; batch 2 is deduped by sourceRef without even loading.
        #expect(Array(await library.loadedIdentifiers.dropFirst(loadsBefore)) == ["asset-6"])
        #expect(result.assetsSkipped == 3)
    }

    @Test func cancellationMidBatchPersistsFinishedAssetsThenResumes() async throws {
        // Cancel while detecting asset-4: the middle of batch 2 (assets 3, 4, 5).
        let (library, detector) = F.library(oneFaceEach(7), cancelOnCall: 5)
        let store = PhotoScanFakeStore()
        let embedder = SyntheticEmbedder()
        let config = PhotoScanConfig(batchSize: 3)
        let job = makeJob(library, detector, store, embedder: embedder, config: config)
        let task = Task { try await job.run() }
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(refs(await store.embeddings) == (0...4).map { "asset-\($0)" })
        #expect(await library.loadedIdentifiers == (0...4).map { "asset-\($0)" })
        let cursor = await F.decodedCursor(store, space: embedder.space)
        #expect(cursor.resumeAfter == F.asset(4))
        #expect(cursor.completedTop == nil)
        #expect(await store.replaceClustersCalls == 0)

        let (_, freshDetector) = F.library(oneFaceEach(7))
        try await makeJob(library, freshDetector, store, embedder: embedder, config: config).run()
        #expect(Array(await library.loadedIdentifiers.dropFirst(5)) == ["asset-5", "asset-6"])
        let stored = await store.embeddings
        #expect(stored.count == 7)
        #expect(Set(refs(stored)).count == 7)
    }

    @Test func laterRunsOnlyVisitNewPhotos() async throws {
        let (library, detector) = F.library(oneFaceEach(3))
        let store = PhotoScanFakeStore()
        try await makeJob(library, detector, store).run()
        #expect(await library.loadedIdentifiers.count == 3)

        // A photo taken after the scan, with its own synthetic image width.
        let newAsset = PhotoAsset(localIdentifier: "new-0", creationDate: F.epoch.addingTimeInterval(60))
        await library.add([(newAsset, PhotoScanImage(image: F.image(width: 2000, height: 800)))])
        var faces = detector.facesByWidth
        faces[2000] = [F.face(identity: 4)]
        let detector2 = ScriptedDetector(facesByWidth: faces)
        let result = try await makeJob(library, detector2, store).run()
        #expect(Array(await library.loadedIdentifiers.dropFirst(3)) == ["new-0"])
        #expect(result.facesEmbedded == 1)
        #expect(await F.decodedCursor(store, space: SyntheticEmbedder().space).completedTop == newAsset)

        // Nothing new: nothing is loaded and the floor stays put.
        try await makeJob(library, detector2, store).run()
        #expect(await library.loadedIdentifiers.count == 4)
        #expect(await F.decodedCursor(store, space: SyntheticEmbedder().space).completedTop == newAsset)
        #expect(await store.embeddings.count == 4)
    }

    @Test func cursorFromAnotherModelRestartsAndEmbedsInTheNewSpace() async throws {
        let (library, detector) = F.library(oneFaceEach(3))
        let store = PhotoScanFakeStore()
        try await makeJob(library, detector, store).run()

        let newModel = SyntheticEmbedder(modelID: "synthetic-v2")
        try await makeJob(library, detector, store, embedder: newModel).run()
        #expect(await library.loadedIdentifiers.count == 6)
        let stored = await store.embeddings
        #expect(stored.filter { $0.space == newModel.space }.count == 3)
        #expect(stored.filter { $0.space == SyntheticEmbedder().space }.count == 3)
    }

    // MARK: Dedupe + availability

    @Test func neverReprocessesAnAssetAlreadyEmbeddedInThisSpace() async throws {
        let (library, detector) = F.library(oneFaceEach(3))
        let store = PhotoScanFakeStore()
        let embedder = SyntheticEmbedder()
        let otherSpace = EmbeddingSpace(modelID: "old-model", dimension: 8)
        await store.seed(embeddings: [
            FaceEmbedding(
                space: embedder.space, vector: [1, 0, 0, 0, 0, 0, 0, 0], source: .photoLibrary,
                sourceRef: "asset-1", quality: 0.9),
            FaceEmbedding(
                space: otherSpace, vector: [1, 0, 0, 0, 0, 0, 0, 0], source: .photoLibrary,
                sourceRef: "asset-2", quality: 0.9),
        ])
        let result = try await makeJob(library, detector, store, embedder: embedder).run()
        #expect(await library.loadedIdentifiers == ["asset-0", "asset-2"])
        #expect(result.assetsSkipped == 1)
        let inSpace = await store.embeddings.filter { $0.space == embedder.space }
        #expect(refs(inSpace) == ["asset-0", "asset-1", "asset-2"])
    }

    @Test func unavailableAssetsAreSkippedAndTheScanCompletes() async throws {
        let (library, detector) = F.library(oneFaceEach(3), unavailable: [1])
        let store = PhotoScanFakeStore()
        let result = try await makeJob(library, detector, store).run()
        #expect(result.assetsUnavailable == 1)
        #expect(result.assetsScanned == 2)
        #expect(refs(await store.embeddings) == ["asset-0", "asset-2"])
        #expect(await F.decodedCursor(store, space: SyntheticEmbedder().space).completedTop == F.asset(0))
    }

    // MARK: Filter + failures

    @Test func qualityAndSizeFilterDropsPoorFaces() async throws {
        let (library, detector) = F.library([
            [
                F.face(identity: 0),
                F.face(identity: 1, quality: 0.1),
                // 0.02 * 800 px = 16 px tall: below the 40 px minimum.
                F.face(identity: 2, side: 0.02),
            ]
        ])
        let store = PhotoScanFakeStore()
        let result = try await makeJob(library, detector, store).run()
        #expect(result.facesRejected == 2)
        #expect(result.facesEmbedded == 1)
        let stored = await store.embeddings
        #expect(stored.count == 1)
        #expect(stored.first?.quality == 0.9)
    }

    @Test func singleEmbedFailureIsSkipped() async throws {
        let (library, detector) = F.library([
            [F.face(identity: -1), F.face(identity: 1)], [F.face(identity: 2)],
        ])
        let store = PhotoScanFakeStore()
        let result = try await makeJob(library, detector, store).run()
        #expect(result.facesFailed == 1)
        #expect(result.facesEmbedded == 2)
        #expect(result.phase == .finished)
    }

    @Test func crowdPhotoWithManyFailingFacesCountsAsOneFailedAsset() async throws {
        let crowd = (0..<10).map { _ in F.face(identity: -1) }
        let (library, detector) = F.library([crowd] + oneFaceEach(3).dropFirst())
        let store = PhotoScanFakeStore()
        let result = try await makeJob(
            library, detector, store, config: PhotoScanConfig(maxConsecutiveFailures: 3)
        ).run()
        #expect(result.phase == .finished)
        #expect(result.facesFailed == 10)
        #expect(result.facesEmbedded == 2)
    }

    @Test func anEmbeddedFaceResetsTheFailedAssetCount() async throws {
        let bad = [F.face(identity: -1)]
        let good = [F.face(identity: 1)]
        // Two failed assets, a success, two more failed assets: never three in a row.
        let (library, detector) = F.library([bad, bad, good, bad, bad, good])
        let store = PhotoScanFakeStore()
        let result = try await makeJob(
            library, detector, store, config: PhotoScanConfig(maxConsecutiveFailures: 3)
        ).run()
        #expect(result.phase == .finished)
        #expect(result.facesFailed == 4)
        #expect(result.facesEmbedded == 2)
    }

    @Test func consecutiveFailedAssetsAbortWithoutAdvancingTheCursor() async throws {
        let (library, detector) = F.library(oneFaceEach(5))
        let store = PhotoScanFakeStore()
        let job = makeJob(
            library, detector, store, embedder: SyntheticEmbedder(alwaysFails: true),
            config: PhotoScanConfig(batchSize: 5, maxConsecutiveFailures: 3))
        await #expect(throws: SyntheticEmbedder.Failure.self) { try await job.run() }
        #expect(await store.cursor == nil)
        #expect(await store.embeddings.isEmpty)
        #expect(await library.loadedIdentifiers.count == 3)
    }

    @Test func systemicFailureAbortsAtOnce() async throws {
        let (library, detector) = F.library(oneFaceEach(5))
        let store = PhotoScanFakeStore()
        let embedder = SyntheticEmbedder(alwaysFails: true)
        let job = makeJob(
            library, detector, store, embedder: embedder,
            config: PhotoScanConfig(maxConsecutiveFailures: 100),
            isSystemicFailure: { $0 is SyntheticEmbedder.Failure })
        await #expect(throws: SyntheticEmbedder.Failure.self) { try await job.run() }
        #expect(embedder.sizes.all.count == 1)
        #expect(await store.cursor == nil)
    }

    @Test func runIsSingleUseAndRejectsInvalidConfig() async throws {
        let (library, detector) = F.library(oneFaceEach(1))
        let store = PhotoScanFakeStore()
        let job = makeJob(library, detector, store)
        try await job.run()
        await #expect(throws: PhotoScanError.alreadyStarted) { try await job.run() }
        let bad = makeJob(library, detector, store, config: PhotoScanConfig(batchSize: 0))
        await #expect(throws: PhotoScanError.invalidConfig) { try await bad.run() }
    }

    // MARK: Clusters (suggestions only, invariant 3)

    @Test func clustersAreSuggestionsAndNothingIsAssignedOrConfirmed() async throws {
        let embedder = SyntheticEmbedder()
        let known = Person(displayName: "Known", confirmed: true)
        let pending = Person(displayName: "Pending", confirmed: false)
        let galleryFace = FaceEmbedding(
            personID: known.id, space: embedder.space, vector: [1, 0, 0, 0, 0, 0, 0, 0],
            source: .liveCapture, quality: 0.9)
        let store = PhotoScanFakeStore()
        await store.seed(people: [known, pending], embeddings: [galleryFace])

        // Three faces that look like `known` (identity 0) and three of a stranger (identity 1).
        let (library, detector) = F.library(
            (0..<6).map { [F.face(identity: $0 < 3 ? 0 : 1, jitter: Double($0 % 3) * 0.05)] })
        let result = try await makeJob(library, detector, store, embedder: embedder).run()

        let stored = await store.embeddings
        let scanned = stored.filter { $0.source == .photoLibrary }
        #expect(scanned.count == 6)
        #expect(scanned.allSatisfy { $0.personID == nil })
        #expect(stored.filter { $0.personID == known.id } == [galleryFace])
        #expect(await store.identityMutations.isEmpty)
        #expect(await store.people[known.id] == known)
        #expect(await store.people[pending.id]?.confirmed == false)

        let clusters = await store.clusterRecords
        #expect(result.clusterCount == 2)
        #expect(clusters.count == 2)
        let scannedIDs = Set(scanned.map(\.id))
        #expect(clusters.allSatisfy { Set($0.memberIDs).isSubset(of: scannedIDs) })
        #expect(clusters.allSatisfy { $0.memberIDs.contains($0.representativeID) })
        let suggested = clusters.filter { $0.suggestedPersonID == known.id }
        #expect(suggested.count == 1)
        #expect(suggested.first?.memberIDs.count == 3)
        #expect(clusters.filter { $0.suggestedPersonID == nil }.count == 1)
        #expect(clusters.allSatisfy { $0.suggestedPersonID != pending.id })
    }

    @Test func staleClustersAreReplacedAndReclusteredEveryKBatches() async throws {
        let store = PhotoScanFakeStore()
        let stale = ClusterRecord(id: "stale", memberIDs: [UUID()], representativeID: UUID(), cohesion: 1)
        await store.seed(clusters: [stale])
        let (library, detector) = F.library(oneFaceEach(5))
        try await makeJob(
            library, detector, store, config: PhotoScanConfig(batchSize: 2, clusterEveryBatches: 1)
        ).run()
        // After batches 1, 2 and 3, plus once when the pass completes.
        #expect(await store.replaceClustersCalls == 4)
        let clusters = await store.clusterRecords
        #expect(!clusters.contains { $0.id == "stale" })
        #expect(!clusters.isEmpty)
    }

    @Test func clusteringRunsOnlyAtTheEndWhenKIsZero() async throws {
        let store = PhotoScanFakeStore()
        let (library, detector) = F.library(oneFaceEach(5))
        try await makeJob(
            library, detector, store, config: PhotoScanConfig(batchSize: 2, clusterEveryBatches: 0)
        ).run()
        #expect(await store.replaceClustersCalls == 1)
    }

    @Test func midPassRoundsAreIncrementalAndKeepExistingClusterIDs() async throws {
        let embedder = SyntheticEmbedder()
        let old = (1...2).map { i in
            FaceEmbedding(
                space: embedder.space, vector: [1, 0, 0, 0, 0, 0, 0, 0], source: .photoLibrary,
                sourceRef: "old-\(i)", quality: 0.9)
        }
        // An id that is NOT the smallest member id, so a full re-cluster would rename it.
        let keptID = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
        let open = ClusterRecord(
            id: keptID, memberIDs: old.map(\.id), representativeID: old[0].id, cohesion: 1)
        let store = PhotoScanFakeStore()
        await store.seed(embeddings: old, clusters: [open])

        let faces = [
            [F.face(identity: 0, jitter: 0.05)], [F.face(identity: 0, jitter: 0.1)],
            [F.face(identity: 1)], [F.face(identity: 1, jitter: 0.05)],
        ]
        let (library, detector) = F.library(faces)
        try await makeJob(
            library, detector, store, embedder: embedder,
            config: PhotoScanConfig(batchSize: 2, clusterEveryBatches: 1)
        ).run()

        let history = await store.clusterHistory
        #expect(history.count == 3)
        // After batch 1: the open cluster keeps its id and gains the two new identity-0 faces.
        let first = try #require(history.first)
        #expect(first.count == 1)
        #expect(first.first?.id == keptID)
        #expect(first.first?.memberIDs.count == 4)
        #expect(Set(old.map(\.id)).isSubset(of: Set(first.first?.memberIDs ?? [])))
        // After batch 2: still there, plus a new identity-1 cluster.
        #expect(history[1].count == 2)
        #expect(history[1].contains { $0.id == keptID && $0.memberIDs.count == 4 })
    }

    // MARK: Clustering failures and races

    @Test func transientReplaceClustersFailuresAreRetried() async throws {
        let store = PhotoScanFakeStore()
        await store.setFailReplaceClusters(2)
        let (library, detector) = F.library(oneFaceEach(5))
        let result = try await makeJob(
            library, detector, store, config: PhotoScanConfig(batchSize: 2, clusterEveryBatches: 0)
        ).run()
        // Two failed attempts, then the third succeeds within the same round.
        #expect(await store.replaceClustersCalls == 3)
        #expect(!(await store.clusterRecords).isEmpty)
        #expect(result.warning == nil)
        #expect(result.clusteringFailures == 0)
    }

    /// The user confirms one member, rejects another and forgets the suggested person while the
    /// scan is writing clusters: the write fails, the retry re-reads everything and stores only
    /// valid suggestions, and the scan finishes.
    @Test(arguments: [(0, 2), (1, 4)])
    func concurrentUserActionsDuringReclusterAreRetriedWithFreshState(
        clusterEveryBatches: Int, expectedWrites: Int
    ) async throws {
        let embedder = SyntheticEmbedder()
        let known = Person(displayName: "Known", confirmed: true)
        let other = Person(displayName: "Other", confirmed: true)
        let store = PhotoScanFakeStore()
        await store.seed(
            people: [known, other],
            embeddings: [
                FaceEmbedding(
                    personID: known.id, space: embedder.space, vector: [1, 0, 0, 0, 0, 0, 0, 0],
                    source: .liveCapture, quality: 0.9),
                FaceEmbedding(
                    personID: other.id, space: embedder.space, vector: [0, 0, 0, 0, 0, 1, 0, 0],
                    source: .liveCapture, quality: 0.9),
            ])
        await store.setInterfereOnNextReplace(other.id)

        // Assets 0-2 look like `known`; assets 3-5 are a stranger.
        let (library, detector) = F.library(
            (0..<6).map { [F.face(identity: $0 < 3 ? 0 : 1, jitter: Double($0 % 3) * 0.05)] })
        let result = try await makeJob(
            library, detector, store, embedder: embedder,
            config: PhotoScanConfig(batchSize: 3, clusterEveryBatches: clusterEveryBatches)
        ).run()

        #expect(result.phase == .finished)
        #expect(result.facesEmbedded == 6)
        #expect(result.warning == nil)
        #expect(result.clusteringFailures == 0)
        #expect(await store.replaceClustersCalls == expectedWrites)
        #expect(await store.people[known.id] == nil)
        #expect(await store.identityMutations.isEmpty)

        let unassigned = Set(await store.embeddings.filter { $0.personID == nil }.map(\.id))
        let clusters = await store.clusterRecords
        #expect(clusters.count == 1)
        #expect(clusters.allSatisfy { Set($0.memberIDs).isSubset(of: unassigned) })
        #expect(clusters.allSatisfy { $0.suggestedPersonID == nil })
        #expect(clusters.first?.memberIDs.count == 3)
    }

    @Test func exhaustedMidPassRoundWarnsAndScanningContinues() async throws {
        let store = PhotoScanFakeStore()
        // The whole first round (after batch 1) fails; later rounds succeed.
        await store.setFailReplaceClusters(3)
        let (library, detector) = F.library(oneFaceEach(5))
        let job = makeJob(
            library, detector, store, config: PhotoScanConfig(batchSize: 2, clusterEveryBatches: 1))
        let result = try await job.run()

        #expect(result.phase == .finished)
        #expect(await store.embeddings.count == 5)
        #expect(await F.decodedCursor(store, space: SyntheticEmbedder().space).completedTop == F.asset(0))
        #expect(!(await store.clusterRecords).isEmpty)
        #expect(result.clusteringFailures == 1)
        #expect(result.warning == nil)
        var sawWarning = false
        for await p in job.progress where p.warning == .clusteringFailed { sawWarning = true }
        #expect(sawWarning)
    }

    @Test func exhaustedEndOfPassRoundThrowsAfterTheScanIsPersisted() async throws {
        let store = PhotoScanFakeStore()
        await store.setFailReplaceClusters(.max)
        let stale = ClusterRecord(id: "stale", memberIDs: [UUID()], representativeID: UUID(), cohesion: 1)
        await store.seed(clusters: [stale])
        let (library, detector) = F.library(oneFaceEach(4))
        let config = PhotoScanConfig(batchSize: 2, clusterEveryBatches: 1)
        await #expect(throws: PhotoScanFakeStore.ClusterConflict.self) {
            try await makeJob(library, detector, store, config: config).run()
        }
        // Mid-pass rounds after batches 1 and 2 warned and the scan went on; the final round
        // made 3 attempts and then threw. The scan itself is complete and persisted.
        #expect(await store.replaceClustersCalls == 9)
        #expect(await store.embeddings.count == 4)
        #expect(await store.embeddings.allSatisfy { $0.personID == nil })
        #expect(await F.decodedCursor(store, space: SyntheticEmbedder().space).completedTop == F.asset(0))
        #expect(await store.clusterRecords == [stale])

        // The next run has nothing to scan and only re-clusters.
        await store.setFailReplaceClusters(0)
        let loads = await library.loadedIdentifiers.count
        let result = try await makeJob(library, detector, store, config: config).run()
        #expect(result.phase == .finished)
        #expect(await library.loadedIdentifiers.count == loads)
        #expect(!(await store.clusterRecords).contains { $0.id == "stale" })
    }

    // MARK: Orientation

    @Test func orientationIsPassedToTheUprighterAndItsImageToDetectAndEmbed() async throws {
        let raw = F.image(width: 1000, height: 800)
        let upright = F.image(width: 800, height: 1000)
        let asset = F.asset(0)
        let library = InMemoryPhotoLibrary([(asset, PhotoScanImage(image: raw, orientation: .right))])
        let detector = ScriptedDetector(facesByWidth: [800: [F.face(identity: 0)]])
        let embedder = SyntheticEmbedder()
        let uprighter = RecordingUprighter(result: upright)
        let store = PhotoScanFakeStore()
        let result = try await makeJob(library, detector, store, embedder: embedder, uprighter: uprighter)
            .run()
        #expect(uprighter.orientations.all == [.right])
        #expect(detector.sizes.all == [CGSize(width: 800, height: 1000)])
        #expect(embedder.sizes.all == [CGSize(width: 800, height: 1000)])
        #expect(result.facesEmbedded == 1)
    }

    @Test func defaultUprighterRotatesBeforeDetection() async throws {
        let library = InMemoryPhotoLibrary([
            (F.asset(0), PhotoScanImage(image: F.image(width: 1000, height: 800), orientation: .left)),
            (F.asset(1), PhotoScanImage(image: F.image(width: 1001, height: 800), orientation: .up)),
        ])
        let detector = ScriptedDetector(facesByWidth: [
            800: [F.face(identity: 0)], 1001: [F.face(identity: 1)],
        ])
        let store = PhotoScanFakeStore()
        let result = try await makeJob(library, detector, store).run()
        #expect(detector.sizes.all == [CGSize(width: 800, height: 1000), CGSize(width: 1001, height: 800)])
        #expect(result.facesEmbedded == 2)
    }
}

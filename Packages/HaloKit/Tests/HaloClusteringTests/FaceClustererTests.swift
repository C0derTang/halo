import Foundation
import HaloCore
import Testing

@testable import HaloClustering

private let space = EmbeddingSpace(modelID: "synthetic", dimension: 32)

/// Deterministic generator so fixtures are reproducible.
private struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

private func gaussian(_ g: inout LCG) -> Float {
    let u1 = Float.random(in: 0.0001..<1, using: &g)
    let u2 = Float.random(in: 0..<1, using: &g)
    return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
}

private func unit(_ v: [Float]) -> [Float] {
    let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
    return v.map { $0 / n }
}

private func centers(_ k: Int, dim: Int = 32, seed: UInt64 = 1) -> [[Float]] {
    var g = LCG(state: seed)
    return (0..<k).map { _ in unit((0..<dim).map { _ in gaussian(&g) }) }
}

private func sample(
    _ center: [Float], noise: Float, quality: Float = 0.9, space: EmbeddingSpace = space,
    g: inout LCG
) -> FaceEmbedding {
    let v = unit(center.map { $0 + noise * gaussian(&g) / sqrt(Float(center.count)) })
    return FaceEmbedding(space: space, vector: v, source: .photoLibrary, quality: quality)
}

private func makeData(clusters k: Int, per: Int, seed: UInt64 = 7) -> (
    [FaceEmbedding], [UUID: Int]
) {
    var g = LCG(state: seed)
    var all: [FaceEmbedding] = []
    var truth: [UUID: Int] = [:]
    for (ci, c) in centers(k).enumerated() {
        for _ in 0..<per {
            let e = sample(c, noise: 0.5, g: &g)
            all.append(e)
            truth[e.id] = ci
        }
    }
    return (all, truth)
}

private func purity(_ result: ClusteringResult, truth: [UUID: Int]) -> Double {
    var correct = 0
    var total = 0
    for c in result.clusters {
        var counts: [Int: Int] = [:]
        for id in c.memberIDs { counts[truth[id]!, default: 0] += 1 }
        correct += counts.values.max() ?? 0
        total += c.size
    }
    return total == 0 ? 0 : Double(correct) / Double(total)
}

@Test func recoversSeparatedClusters() throws {
    let (data, truth) = makeData(clusters: 5, per: 40)
    let result = try FaceClusterer().cluster(data)
    #expect(purity(result, truth: truth) >= 0.95)
    #expect(result.clusters.count == 5)
    #expect(result.clusters.allSatisfy { $0.size == 40 })
    #expect(result.unclustered.isEmpty)
    for c in result.clusters {
        #expect(c.memberIDs.contains(c.representativeID))
        #expect(c.cohesion > 0.6)
    }
}

@Test func sortedBySizeDescending() throws {
    var g = LCG(state: 3)
    let cs = centers(3)
    var data: [FaceEmbedding] = []
    for (i, n) in [5, 20, 10].enumerated() {
        for _ in 0..<n { data.append(sample(cs[i], noise: 0.4, g: &g)) }
    }
    let sizes = try FaceClusterer().cluster(data).clusters.map(\.size)
    #expect(sizes == [20, 10, 5])
}

@Test func deterministicAcrossRunsAndInputOrder() throws {
    let (data, _) = makeData(clusters: 4, per: 25)
    let a = try FaceClusterer().cluster(data)
    let b = try FaceClusterer().cluster(data)
    let c = try FaceClusterer().cluster(data.reversed())
    #expect(a.clusters == b.clusters)
    #expect(a.clusters == c.clusters)
    #expect(a.unclustered == c.unclustered)
}

@Test func singletonsAndSmallGroupsAreUnclustered() throws {
    var g = LCG(state: 11)
    let cs = centers(3)
    var data: [FaceEmbedding] = []
    for _ in 0..<10 { data.append(sample(cs[0], noise: 0.3, g: &g)) }
    let lone = sample(cs[1], noise: 0.1, g: &g)
    data.append(lone)
    let result = try FaceClusterer(config: ClusteringConfig(minClusterSize: 3)).cluster(data)
    #expect(result.clusters.count == 1)
    #expect(result.unclustered == [lone.id])
}

@Test func mixedSpacesThrow() {
    var g = LCG(state: 5)
    let c = centers(1)[0]
    let a = sample(c, noise: 0.1, g: &g)
    let other = EmbeddingSpace(modelID: "other", dimension: 32)
    let b = sample(c, noise: 0.1, space: other, g: &g)
    #expect(throws: ClusteringError.mixedEmbeddingSpaces) { try FaceClusterer().cluster([a, b]) }
}

@Test func wrongDimensionThrows() {
    let bad = FaceEmbedding(space: space, vector: [1, 0], source: .photoLibrary, quality: 1)
    #expect(throws: ClusteringError.dimensionMismatch(embeddingID: bad.id)) {
        try FaceClusterer().cluster([bad])
    }
}

@Test func onlyLowQualityEmbeddingsYieldEmptyClusters() throws {
    var g = LCG(state: 10)
    let c = centers(1)[0]
    let poor = (0..<4).map { _ in sample(c, noise: 0.2, quality: 0.05, g: &g) }
    let result = try FaceClusterer().cluster(poor)
    #expect(result.clusters.isEmpty)
    #expect(result.unclustered.isEmpty)
    #expect(Set(result.lowQuality) == Set(poor.map(\.id)))
}

@Test func lowQualityFiltered() throws {
    var g = LCG(state: 9)
    let c = centers(1)[0]
    var data = (0..<6).map { _ in sample(c, noise: 0.2, g: &g) }
    let poor = sample(c, noise: 0.2, quality: 0.05, g: &g)
    data.append(poor)
    let result = try FaceClusterer().cluster(data)
    #expect(result.lowQuality == [poor.id])
    #expect(result.clusters.count == 1)
    #expect(result.clusters[0].size == 6)
    #expect(!result.clusters[0].memberIDs.contains(poor.id))
}

@Test func emptyInput() throws {
    let r = try FaceClusterer().cluster([])
    #expect(r.clusters.isEmpty && r.unclustered.isEmpty && r.lowQuality.isEmpty)
}

@Test func incrementalAssign() throws {
    var g = LCG(state: 21)
    let cs = centers(3)
    var initial: [FaceEmbedding] = []
    for i in 0..<2 {
        for _ in 0..<15 { initial.append(sample(cs[i], noise: 0.4, g: &g)) }
    }
    let clusterer = FaceClusterer()
    let base = try clusterer.cluster(initial)
    #expect(base.clusters.count == 2)

    let toExisting = (0..<4).map { _ in sample(cs[0], noise: 0.4, g: &g) }
    let fresh = (0..<5).map { _ in sample(cs[2], noise: 0.4, g: &g) }
    let result = try clusterer.assign(
        newEmbeddings: toExisting + fresh, to: base.clusters, existingEmbeddings: initial)
    #expect(result.clusters.count == 3)
    let baseIDs = Set(base.clusters.map(\.id))
    let grown = result.clusters.filter { baseIDs.contains($0.id) && $0.size == 19 }
    #expect(grown.count == 1)
    #expect(Set(grown[0].memberIDs).isSuperset(of: toExisting.map(\.id)))
    #expect(result.clusters.contains { Set($0.memberIDs) == Set(fresh.map(\.id)) })
}

@Test func suggestionReturnsClosestPersonAndNilBelowThreshold() throws {
    var g = LCG(state: 33)
    let cs = centers(3)
    let data = (0..<10).map { _ in sample(cs[0], noise: 0.3, g: &g) }
    let clusterer = FaceClusterer()
    let cluster = try clusterer.cluster(data).clusters[0]
    let alice = PersonID()
    let bob = PersonID()
    func gal(_ p: PersonID, _ c: [Float], _ g: inout LCG) -> FaceEmbedding {
        var e = sample(c, noise: 0.2, g: &g)
        e.personID = p
        return e
    }
    let gallery = [gal(alice, cs[0], &g), gal(bob, cs[1], &g)]
    let s = try clusterer.suggest(for: cluster, confirmedGallery: gallery)
    #expect(s?.personID == alice)
    // Nobody close: gallery holds only an unrelated person.
    #expect(try clusterer.suggest(for: cluster, confirmedGallery: [gal(bob, cs[1], &g)]) == nil)
    // Unlabeled gallery entries are ignored.
    #expect(try clusterer.suggest(for: cluster, confirmedGallery: data) == nil)
}

@Test func ambiguousSuggestionIsNil() throws {
    var g = LCG(state: 44)
    let c = centers(1)[0]
    let data = (0..<8).map { _ in sample(c, noise: 0.2, g: &g) }
    let clusterer = FaceClusterer()
    let cluster = try clusterer.cluster(data).clusters[0]
    var a = sample(c, noise: 0.05, g: &g)
    a.personID = PersonID()
    var b = a
    b.id = UUID()
    b.personID = PersonID()
    #expect(try clusterer.suggest(for: cluster, confirmedGallery: [a, b]) == nil)
}

@Test func suggestionMixedSpaceThrows() throws {
    var g = LCG(state: 55)
    let c = centers(1)[0]
    let data = (0..<4).map { _ in sample(c, noise: 0.2, g: &g) }
    let cluster = try FaceClusterer().cluster(data).clusters[0]
    var other = sample(c, noise: 0.1, space: EmbeddingSpace(modelID: "x", dimension: 32), g: &g)
    other.personID = PersonID()
    #expect(throws: ClusteringError.mixedEmbeddingSpaces) {
        try FaceClusterer().suggest(for: cluster, confirmedGallery: [other])
    }
}

@Test func inputsNeverMutated() throws {
    let (data, _) = makeData(clusters: 3, per: 10)
    let copy = data
    let clusterer = FaceClusterer()
    let r = try clusterer.cluster(data)
    _ = try clusterer.assign(newEmbeddings: data, to: r.clusters, existingEmbeddings: data)
    #expect(data == copy)
    #expect(data.allSatisfy { $0.personID == nil })
}

@Test(.timeLimit(.minutes(5)), .enabled(if: ProcessInfo.processInfo.environment["HALO_PERF"] == "1"))
func largeInputTiming() throws {
    // Non-gating: prints elapsed time; only basic correctness is asserted.
    let dim = 512
    let sp = EmbeddingSpace(modelID: "big", dimension: dim)
    var g = LCG(state: 99)
    let cs = centers(200, dim: dim, seed: 5)
    var data: [FaceEmbedding] = []
    data.reserveCapacity(20_000)
    for c in cs {
        for _ in 0..<100 { data.append(sample(c, noise: 0.5, space: sp, g: &g)) }
    }
    let t = ContinuousClock().measure {
        _ = try? FaceClusterer().cluster(data)
    }
    print("cluster 20k x 512: \(t)")
}

private func assignFixture() throws -> ([FaceEmbedding], ClusteringResult, [[Float]]) {
    var g = LCG(state: 77)
    let cs = centers(2)
    let initial = (0..<10).map { _ in sample(cs[0], noise: 0.3, g: &g) }
    return (initial, try FaceClusterer().cluster(initial), cs)
}

@Test func assignMixedSpacesThrow() throws {
    var g = LCG(state: 78)
    let (initial, base, cs) = try assignFixture()
    let other = sample(
        cs[0], noise: 0.1, space: EmbeddingSpace(modelID: "x", dimension: 32), g: &g)
    #expect(throws: ClusteringError.mixedEmbeddingSpaces) {
        try FaceClusterer().assign(
            newEmbeddings: [other], to: base.clusters, existingEmbeddings: initial)
    }
}

@Test func assignMissingMemberEmbeddingThrows() throws {
    var g = LCG(state: 79)
    let (initial, base, cs) = try assignFixture()
    let new = sample(cs[0], noise: 0.2, g: &g)
    let missing = initial[0].id
    #expect(throws: ClusteringError.missingMemberEmbedding(id: missing)) {
        try FaceClusterer().assign(
            newEmbeddings: [new], to: base.clusters,
            existingEmbeddings: Array(initial.dropFirst()))
    }
}

@Test func assignInvalidCentroidThrows() throws {
    var g = LCG(state: 80)
    let (initial, fixtureBase, cs) = try assignFixture()
    var base = fixtureBase
    base.clusters[0].centroid = [1, 0]
    let new = sample(cs[0], noise: 0.2, g: &g)
    #expect(throws: ClusteringError.invalidCluster(id: base.clusters[0].id)) {
        try FaceClusterer().assign(
            newEmbeddings: [new], to: base.clusters, existingEmbeddings: initial)
    }
}

@Test func assignDropsLowQualityNewFaces() throws {
    var g = LCG(state: 81)
    let (initial, base, cs) = try assignFixture()
    let poor = sample(cs[0], noise: 0.2, quality: 0.01, g: &g)
    let r = try FaceClusterer().assign(
        newEmbeddings: [poor], to: base.clusters, existingEmbeddings: initial)
    #expect(r.lowQuality == [poor.id])
    #expect(r.clusters == base.clusters)
}

@Suite struct FaceClusterInitTests {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private var centroid: [Float] { [Float](repeating: 0.1, count: 32) }

    @Test func buildsAndSortsMembers() throws {
        let c = try FaceCluster(
            id: b, space: space, memberIDs: [a, b], representativeID: a, cohesion: 0.8,
            centroid: centroid)
        #expect(c.memberIDs == [b, a])
        #expect(c.representativeID == a)
        #expect(c.size == 2)
        #expect(c.cohesion == 0.8)
    }

    @Test func rejectsInvalidParts() {
        let stranger = UUID()
        func make(
            members: [UUID], rep: UUID, cohesion: Float = 1, centroid: [Float]
        ) throws -> FaceCluster {
            try FaceCluster(
                id: b, space: space, memberIDs: members, representativeID: rep, cohesion: cohesion,
                centroid: centroid)
        }
        #expect(throws: ClusteringError.invalidCluster(id: b)) {
            try make(members: [], rep: a, centroid: centroid)
        }
        #expect(throws: ClusteringError.invalidCluster(id: b)) {
            try make(members: [a], rep: stranger, centroid: centroid)
        }
        #expect(throws: ClusteringError.invalidCluster(id: b)) {
            try make(members: [a, a], rep: a, centroid: centroid)
        }
        #expect(throws: ClusteringError.invalidCluster(id: b)) {
            try make(members: [a], rep: a, centroid: [1, 2, 3])
        }
        #expect(throws: ClusteringError.invalidCluster(id: b)) {
            try make(members: [a], rep: a, cohesion: .nan, centroid: centroid)
        }
        #expect(throws: ClusteringError.invalidCluster(id: b)) {
            try make(members: [a], rep: a, centroid: [Float](repeating: .infinity, count: 32))
        }
    }

    @Test func roundTripsAClusterer() throws {
        var g = LCG(state: 7)
        let center = centers(1)[0]
        let faces = (0..<5).map { _ in sample(center, noise: 0.2, g: &g) }
        let original = try #require(try FaceClusterer().cluster(faces).clusters.first)
        let rebuilt = try FaceCluster(
            id: original.id, space: original.space, memberIDs: original.memberIDs,
            representativeID: original.representativeID, cohesion: original.cohesion,
            centroid: original.centroid)
        #expect(rebuilt == original)
    }
}

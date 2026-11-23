// Synthetic fakes for the photo-scan tests. No real photos, faces or Photos-library access.

import CoreGraphics
import Foundation
import HaloCore
import ImageIO
import Synchronization

@testable import HaloImport

// MARK: - Store

/// In-memory `PeopleStoring & EnrollmentStoring` that records every call that could assign or
/// confirm someone, and can simulate a kill by failing the Nth cursor write.
actor PhotoScanFakeStore: PeopleStoring, EnrollmentStoring {
    var people: [PersonID: Person] = [:]
    var embeddings: [FaceEmbedding] = []
    var clusterRecords: [ClusterRecord] = []
    var cursor: String?
    var cursorWrites = 0
    var replaceClustersCalls = 0
    /// Names of calls that assign, confirm, create or delete people/identities/embeddings.
    var identityMutations: [String] = []
    /// 1-based cursor write that throws (simulates the process dying before it lands).
    var failCursorWrite: Int?

    struct SimulatedKill: Error {}

    func seed(people: [Person] = [], embeddings: [FaceEmbedding] = [], clusters: [ClusterRecord] = []) {
        for p in people { self.people[p.id] = p }
        self.embeddings += embeddings
        clusterRecords += clusters
    }

    func setFailCursorWrite(_ n: Int?) {
        failCursorWrite = n
        cursorWrites = 0
    }

    // PeopleStoring
    func person(_ id: PersonID) async throws -> Person? { people[id] }
    func allPeople() async throws -> [Person] { Array(people.values) }
    func upsert(_ person: Person) async throws {
        identityMutations.append("upsert")
        people[person.id] = person
    }
    func identities(for id: PersonID) async throws -> [Identity] { [] }
    func addIdentity(_ identity: Identity) async throws { identityMutations.append("addIdentity") }
    func person(matching kind: Identity.Kind, value: String) async throws -> Person? { nil }
    func confirmedGallery(space: EmbeddingSpace) async throws -> [FaceEmbedding] {
        embeddings.filter { e in
            e.space == space && e.personID.flatMap { people[$0]?.confirmed } == true
        }
    }
    func addEmbeddings(_ new: [FaceEmbedding]) async throws { embeddings += new }
    func forget(_ id: PersonID) async throws { identityMutations.append("forget") }
    func latestDigest() async throws -> InteractionDigest? { nil }
    func saveDigest(_ digest: InteractionDigest) async throws {}

    // EnrollmentStoring
    func unassignedEmbeddings(space: EmbeddingSpace) async throws -> [FaceEmbedding] {
        embeddings.filter { $0.personID == nil && $0.space == space }
    }
    func embeddings(ids: [UUID]) async throws -> [FaceEmbedding] {
        let wanted = Set(ids)
        return embeddings.filter { wanted.contains($0.id) }
    }
    func replaceClusters(_ clusters: [ClusterRecord]) async throws {
        replaceClustersCalls += 1
        clusterRecords = clusters
    }
    func clusters() async throws -> [ClusterRecord] { clusterRecords }
    func confirm(cluster id: String, as person: PersonID) async throws { identityMutations.append("confirm") }
    func deleteEmbeddings(ids: [UUID]) async throws { identityMutations.append("deleteEmbeddings") }
    func removeIdentity(_ identity: Identity) async throws { identityMutations.append("removeIdentity") }
    func scanCursor() async throws -> String? { cursor }
    func setScanCursor(_ cursor: String?) async throws {
        cursorWrites += 1
        if cursorWrites == failCursorWrite { throw SimulatedKill() }
        self.cursor = cursor
    }
}

// MARK: - Vision fakes

final class Recorder<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])
    func append(_ value: Value) { values.withLock { $0.append(value) } }
    var all: [Value] { values.withLock { $0 } }
    /// Appends and returns the new count.
    func record(_ value: Value) -> Int {
        values.withLock {
            $0.append(value)
            return $0.count
        }
    }
}

/// Returns the faces scripted for an image, keyed by the image's pixel width (each synthetic asset
/// has a unique width). Records the size of every image it is handed.
struct ScriptedDetector: FaceDetecting {
    var facesByWidth: [Int: [FaceObservation]]
    /// 1-based call on which the detector cancels the task that is running the scan.
    var cancelOnCall: Int?
    let sizes = Recorder<CGSize>()

    init(facesByWidth: [Int: [FaceObservation]], cancelOnCall: Int? = nil) {
        self.facesByWidth = facesByWidth
        self.cancelOnCall = cancelOnCall
    }

    func detectFaces(in image: CGImage, timestamp: TimeInterval) async throws -> [FaceObservation] {
        let call = sizes.record(CGSize(width: image.width, height: image.height))
        if call == cancelOnCall { withUnsafeCurrentTask { $0?.cancel() } }
        return facesByWidth[image.width] ?? []
    }
}

/// Synthetic embedder: identity `k` is encoded in `face.roll` and maps to the one-hot vector `e_k`
/// plus `yaw` on the next axis, so same-identity faces are near-identical and different ones are
/// near-orthogonal. `roll < 0` makes it throw.
struct SyntheticEmbedder: FaceEmbedder {
    struct Failure: Error {}
    let space: EmbeddingSpace
    var alwaysFails = false
    let sizes = Recorder<CGSize>()

    init(modelID: String = "synthetic-v1", alwaysFails: Bool = false) {
        space = EmbeddingSpace(modelID: modelID, dimension: 8)
        self.alwaysFails = alwaysFails
    }

    func embed(face: FaceObservation, in image: CGImage) async throws -> [Float] {
        sizes.append(CGSize(width: image.width, height: image.height))
        let identity = Int(face.roll ?? 0)
        if alwaysFails || identity < 0 { throw Failure() }
        var v = [Float](repeating: 0, count: space.dimension)
        v[identity % space.dimension] = 1
        v[(identity + 1) % space.dimension] = Float(face.yaw ?? 0)
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / norm }
    }
}

/// Records the orientation it is asked for and returns a fixed upright image.
struct RecordingUprighter: PhotoScanUprighting {
    let result: CGImage
    let orientations = Recorder<CGImagePropertyOrientation>()

    func upright(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> CGImage {
        orientations.append(orientation)
        return result
    }
}

// MARK: - Fixtures

enum PhotoScanFixture {
    static let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Asset `i`; larger `i` is older.
    static func asset(_ i: Int, prefix: String = "asset") -> PhotoAsset {
        PhotoAsset(
            localIdentifier: "\(prefix)-\(i)", creationDate: epoch.addingTimeInterval(-3600 * Double(i)))
    }

    static func face(
        identity: Int, jitter: Double = 0, quality: Float = 0.9, side: Double = 0.2
    ) -> FaceObservation {
        FaceObservation(
            boundingBox: CGRect(x: 0.3, y: 0.3, width: side, height: side), roll: Double(identity),
            yaw: jitter, quality: quality, timestamp: 0)
    }

    /// Solid-gray synthetic image.
    static func image(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Image from row-major RGBA pixels (top row first).
    static func image(width: Int, height: Int, rgba: [UInt8]) -> CGImage {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Row-major RGBA pixels (top row first).
    static func pixels(of image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    /// A library of `faces.count` assets (asset `i` newest-first) whose images are keyed by width
    /// for `ScriptedDetector`. `unavailable` assets load as nil (iCloud-only).
    static func library(
        _ faces: [[FaceObservation]], unavailable: Set<Int> = [], cancelOnCall: Int? = nil
    ) -> (InMemoryPhotoLibrary, ScriptedDetector) {
        var entries: [(PhotoAsset, PhotoScanImage?)] = []
        var byWidth: [Int: [FaceObservation]] = [:]
        for (i, f) in faces.enumerated() {
            let width = 1000 + i
            byWidth[width] = f
            entries.append(
                (
                    asset(i),
                    unavailable.contains(i) ? nil : PhotoScanImage(image: image(width: width, height: 800))
                ))
        }
        return (
            InMemoryPhotoLibrary(entries), ScriptedDetector(facesByWidth: byWidth, cancelOnCall: cancelOnCall)
        )
    }

    static func decodedCursor(_ store: PhotoScanFakeStore, space: EmbeddingSpace) async -> PhotoScanCursor {
        PhotoScanCursor.decode(await store.cursor, space: space)
    }
}

import CoreGraphics
import CoreVideo
import Foundation
import HaloCore
import ImageIO
import Synchronization

@testable import HaloLens

// Synthetic fixtures only: blank pixel buffers, hand-placed boxes, one-float "embeddings" that
// encode a scripted match outcome. No real faces or data.

/// Matcher code carried in the 1-float fake embedding: 0 = unknown, negative = ambiguous,
/// k > 0 = known person k.
func person(_ k: Int) -> PersonID {
    PersonID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", k))!)
}

let fakeSpace = EmbeddingSpace(modelID: "fake-1", dimension: 1)

/// Policy used by most tests; thresholds are irrelevant to the fake matcher, minVotes matters.
let testPolicy = MatchPolicy(minSimilarity: 0.5, minMargin: 0.1, minVotes: 3)

let frameDuration: TimeInterval = 1.0 / 30

/// Key identifying a synthetic face by its box position.
struct FaceKey: Hashable, Sendable {
    var x: Int
    var y: Int
    init(_ box: CGRect) {
        x = Int((box.minX * 1000).rounded())
        y = Int((box.minY * 1000).rounded())
    }
    init(x: Double, y: Double) { self.init(CGRect(x: x, y: y, width: 0, height: 0)) }
}

func face(x: Double, y: Double = 0.3, size: Double = 0.2, quality: Float = 0.9) -> FaceObservation {
    FaceObservation(
        boundingBox: CGRect(x: x, y: y, width: size, height: size), quality: quality, timestamp: 0)
}

/// Shared blank frame source. The buffer is never mutated after creation.
struct FrameFactory: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let orientation: CGImagePropertyOrientation

    init(width: Int = 640, height: Int = 480, orientation: CGImagePropertyOrientation = .up) {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &out)
        precondition(status == kCVReturnSuccess && out != nil)
        buffer = out!
        self.orientation = orientation
    }

    func frame(_ index: Int) -> VideoFrame {
        frame(at: Double(index) * frameDuration)
    }

    func frame(at t: TimeInterval) -> VideoFrame {
        VideoFrame(pixelBuffer: buffer, orientation: orientation, timestamp: t)
    }
}

struct FakeError: Error {}

/// Detector scripted by the test before each frame. `hold()` parks every call until the test
/// calls `release()` (a deterministic "slow detector", no sleeps).
final class FakeDetector: FrameFaceDetecting {
    private struct State {
        var faces: [FaceObservation] = []
        var held = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var fails = false
        var calls = 0
        var calledOnMainThread = false
    }
    private let state = Mutex(State())

    var faces: [FaceObservation] {
        get { state.withLock { $0.faces } }
        set { state.withLock { $0.faces = newValue } }
    }
    func hold() { state.withLock { $0.held = true } }
    func release() {
        let waiters = state.withLock { s in
            s.held = false
            defer { s.waiters.removeAll() }
            return s.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    func setFails(_ fails: Bool) { state.withLock { $0.fails = fails } }
    var calls: Int { state.withLock { $0.calls } }
    var calledOnMainThread: Bool { state.withLock { $0.calledOnMainThread } }

    func detectFaces(in frame: VideoFrame) async throws -> [FaceObservation] {
        let onMain = pthread_main_np() != 0
        let (faces, fails) = state.withLock { s in
            s.calls += 1
            s.calledOnMainThread = s.calledOnMainThread || onMain
            return (s.faces, s.fails)
        }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let parked = state.withLock { s in
                guard s.held else { return false }
                s.waiters.append(waiter)
                return true
            }
            if !parked { waiter.resume() }
        }
        if fails { throw FakeError() }
        return faces.map {
            var f = $0
            f.timestamp = frame.timestamp
            return f
        }
    }
}

/// Embedder whose output for a face (by box position) is a scripted matcher code.
final class FakeEmbedder: FrameFaceEmbedding {
    struct Call: Sendable, Equatable {
        var time: TimeInterval
        var key: FaceKey
    }
    private struct State {
        var codes: [FaceKey: Float] = [:]
        var defaultCode: Float = 0
        var calls: [Call] = []
        var failing: Set<FaceKey> = []
        var wrongDimension = false
    }
    private let state = Mutex(State())
    let space = fakeSpace

    func setCode(_ code: Float, x: Double, y: Double = 0.3) {
        state.withLock { $0.codes[FaceKey(x: x, y: y)] = code }
    }
    func setFailing(x: Double, y: Double = 0.3) {
        state.withLock { _ = $0.failing.insert(FaceKey(x: x, y: y)) }
    }
    func setWrongDimension(_ on: Bool) { state.withLock { $0.wrongDimension = on } }
    var calls: [Call] { state.withLock { $0.calls } }
    func calls(x: Double, y: Double = 0.3) -> [Call] {
        let key = FaceKey(x: x, y: y)
        return calls.filter { $0.key == key }
    }

    func embed(face: FaceObservation, in frame: VideoFrame) async throws -> [Float] {
        let key = FaceKey(face.boundingBox)
        let (code, fails, wrong) = state.withLock { s in
            s.calls.append(Call(time: frame.timestamp, key: key))
            return (s.codes[key] ?? s.defaultCode, s.failing.contains(key), s.wrongDimension)
        }
        if fails { throw FakeError() }
        return wrong ? [code, 0] : [code]
    }
}

/// Decodes the fake embedding into a scripted `MatchResult`.
struct FakeMatcher: FaceMatching {
    func match(_ vector: [Float], policy: MatchPolicy) -> MatchResult {
        guard let code = vector.first else { return .unknown }
        if code < 0 { return .ambiguous }
        if code == 0 { return .unknown }
        return .known(person(Int(code)), similarity: 0.9, margin: 0.3)
    }
}

struct Harness {
    let detector = FakeDetector()
    let embedder = FakeEmbedder()
    let frames = FrameFactory()
    let pipeline: LensPipeline

    init(policy: MatchPolicy = testPolicy, config: LensConfig = LensConfig()) {
        pipeline = LensPipeline(
            detector: detector, embedder: embedder, matcher: FakeMatcher(), policy: policy, config: config)
    }

    /// Runs frames `range` with the given faces visible, returning each frame's output.
    @discardableResult
    func run(_ range: Range<Int>, faces: [FaceObservation]) async -> [[LensTrack]] {
        detector.faces = faces
        var outputs: [[LensTrack]] = []
        for i in range { outputs.append(await pipeline.process(frames.frame(i))) }
        return outputs
    }
}

/// Config that embeds every frame (no throttle), for vote-logic tests.
let everyFrame = LensConfig(embedInterval: 0, reverifyInterval: 1, maxEmbedsPerFrame: 8)

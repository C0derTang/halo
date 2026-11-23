import CoreGraphics
import CoreVideo
import Foundation
import HaloCore
import HaloMatching
import HaloTracking
import ImageIO
import Synchronization

/// The live lens: camera frame -> detect -> track -> throttled per-track embed -> match -> vote ->
/// labeled tracks.
///
/// Load-bearing rules (invariants 1, 4, 7):
/// - An identity is only ever shown through `TrackVoter`: a track is labeled only after
///   `policy.minVotes` agreeing matches, and the voter's drop rules apply on every re-check.
/// - Labeled tracks are re-embedded at least every `LensConfig.reverifyInterval` (when the face is
///   usable), and lose the label after `LensConfig.staleLabelTimeout` without evidence.
/// - Vote state is keyed by `TrackID`; lost tracks are removed from the voter, so an identity
///   never transfers to a new track. When a track reappears after a miss:
///   - unlabeled: its partial acquire streak is discarded (votes from before the miss may belong
///     to a different face), so it must earn `minVotes` from scratch;
///   - labeled, and the tracker KEPT its identity (tight IoU re-match within
///     `TrackerConfig.identityResetAfterMissed`): the label is kept but marked overdue, so it is
///     re-verified in the very next embed slot ahead of everything else; the voter's drop rules
///     apply to that result as usual;
///   - labeled, and the tracker CLEARED its identity (loose fallback re-match or long gap): all of
///     its vote state is discarded.
/// - Faces are only compared against the injected on-device `FaceMatching` gallery; nothing about
///   any face leaves this pipeline except the `LensTrack` output.
/// - Work runs on this actor (never the main actor). At most one frame is in flight: a frame that
///   arrives while another is processing is dropped, never queued.
public actor LensPipeline {
    /// Latest labeled tracks after each processed frame. Buffers only the newest value, so a slow
    /// consumer never builds a backlog.
    public nonisolated let tracks: AsyncStream<[LensTrack]>
    private nonisolated let continuation: AsyncStream<[LensTrack]>.Continuation

    private struct Gate {
        var busy = false
        var dropped = 0
    }
    /// Frame-drop gate. A lock rather than actor state so `submit` can refuse a frame without
    /// creating a task for it.
    private nonisolated let gate = Mutex(Gate())

    public let config: LensConfig
    public let policy: MatchPolicy
    private let detector: any FrameFaceDetecting
    private let embedder: any FrameFaceEmbedding
    private var matcher: any FaceMatching
    private var tracker: IoUTracker
    private var voter: TrackVoter
    private var schedule = EmbedSchedule()
    /// Tracks that were coasting (not seen) in the previous processed frame.
    private var coastingLastFrame: Set<TrackID> = []
    private var metricsState = LensMetrics()
    private var lastOutput: [LensTrack] = []
    private let clock = ContinuousClock()

    public init(
        detector: any FrameFaceDetecting, embedder: any FrameFaceEmbedding, matcher: any FaceMatching,
        policy: MatchPolicy, tracker: IoUTracker = IoUTracker(), config: LensConfig = LensConfig()
    ) {
        self.detector = detector
        self.embedder = embedder
        self.matcher = matcher
        self.policy = policy
        self.tracker = tracker
        self.voter = TrackVoter(policy: policy)
        self.config = config
        (tracks, continuation) = AsyncStream.makeStream(
            of: [LensTrack].self, bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        continuation.finish()
    }

    /// Rolling fps / latency numbers for a debug overlay.
    public var metrics: LensMetrics {
        var m = metricsState
        m.droppedFrames = gate.withLock { $0.dropped }
        return m
    }

    /// The tracks produced by the most recent processed frame.
    public var currentTracks: [LensTrack] { lastOutput }

    /// Tracks holding vote state (for tests: lost tracks must not linger).
    var voterTrackCount: Int { voter.trackCount }
    /// Tracks holding embed-schedule state (for tests).
    var scheduledTrackCount: Int { schedule.trackedCount }

    /// Fire-and-forget entry point for the capture callback. Returns false (and creates no task)
    /// when a frame is already in flight; the frame is dropped. Results arrive on `tracks`.
    @discardableResult
    public nonisolated func submit(_ frame: VideoFrame) -> Bool {
        guard claim() else { return false }
        Task { await self.run(frame) }
        return true
    }

    /// Processes one frame and returns the resulting tracks (also yielded on `tracks`). If a frame
    /// is already in flight this frame is dropped and the previous result is returned unchanged.
    @discardableResult
    public func process(_ frame: VideoFrame) async -> [LensTrack] {
        guard claim() else { return lastOutput }
        return await run(frame)
    }

    /// Swap the gallery matcher (e.g. after enrolling or forgetting someone). Every current label is
    /// cleared immediately and must be re-earned against the new gallery, so a forgotten person's
    /// name disappears at once (invariant 3).
    public func setMatcher(_ matcher: any FaceMatching) {
        self.matcher = matcher
        voter.removeAll()
        for track in tracker.tracks where track.identity != .unknown {
            tracker.setIdentity(.unknown, for: track.id)
        }
        lastOutput = lastOutput.map {
            LensTrack(trackID: $0.trackID, smoothedBox: $0.smoothedBox, identity: .unknown, state: $0.state)
        }
        continuation.yield(lastOutput)
    }

    // MARK: - Frame gate

    private nonisolated func claim() -> Bool {
        gate.withLock { g in
            if g.busy {
                g.dropped += 1
                return false
            }
            g.busy = true
            return true
        }
    }

    private nonisolated func release() {
        gate.withLock { $0.busy = false }
    }

    // MARK: - Processing

    /// Must only be called after a successful `claim()`; releases the gate when done.
    @discardableResult
    private func run(_ frame: VideoFrame) async -> [LensTrack] {
        defer { release() }
        let now = frame.timestamp
        let start = clock.now

        // 1. Detect. A detector failure counts as "no faces": tracks coast and then drop, so
        // persistent failures can never keep a stale label alive.
        let observations: [FaceObservation]
        do {
            observations = try await detector.detectFaces(in: frame)
        } catch {
            metricsState.recordDetectorError()
            observations = []
        }
        let detected = clock.now
        metricsState.recordLatency(.detect, detected - start)

        // 2. Track, and reconcile vote state with the live tracks.
        let current = tracker.update(observations: observations, timestamp: now)
        let live = Set(current.map(\.id))
        voter.retain(only: live)
        schedule.retain(only: live)
        for track in current {
            let reappeared = track.framesSinceSeen == 0 && coastingLastFrame.contains(track.id)
            if Self.isKnown(voter.identity(for: track.id)) {
                if !Self.isKnown(track.identity)
                    || schedule.isStale(track.id, now: now, timeout: config.staleLabelTimeout)
                {
                    // The tracker cleared the identity (fallback re-match or long gap: possibly a
                    // different face), or evidence stopped. Discard everything.
                    voter.forget(trackID: track.id)
                } else if reappeared {
                    // Tight re-match after a short blip: keep the label, re-check it first.
                    schedule.markOverdue(track.id)
                }
            } else if reappeared {
                // Partial streak from before the miss must not count toward this face.
                voter.forget(trackID: track.id)
            }
        }
        coastingLastFrame = Set(current.lazy.filter { $0.framesSinceSeen > 0 }.map(\.id))
        let tracked = clock.now
        metricsState.recordLatency(.track, tracked - detected)

        // 3. Throttled embedding.
        let size = Self.uprightPixelSize(of: frame)
        let candidates = current.map { track in
            EmbedSchedule.Candidate(
                id: track.id, labeled: Self.isKnown(voter.identity(for: track.id)),
                eligible: isEmbeddable(track, frameSize: size))
        }
        let chosen = schedule.select(candidates, now: now, config: config)
        let faces = chosen.compactMap { id in current.first { $0.id == id }.map { (id, $0.latest) } }
        let vectors = await embed(faces, in: frame)
        let embedded = clock.now
        metricsState.recordLatency(.embed, embedded - tracked)

        // 4. Match + vote. Only tracks still live get votes.
        let stillLive = Set(tracker.tracks.map(\.id))
        for (id, vector) in vectors {
            guard let vector else {
                metricsState.recordEmbedderError()
                continue
            }
            guard stillLive.contains(id) else { continue }
            let result = matcher.match(vector, policy: policy)
            voter.record(result, for: id)
            schedule.recordEvidence(for: id, at: now)
        }

        // 5. Identity flows into the tracker; build the output from the tracker's view.
        for track in tracker.tracks {
            let identity = voter.identity(for: track.id)
            if identity != track.identity { tracker.setIdentity(identity, for: track.id) }
        }
        let output = tracker.tracks
            .map { track in
                LensTrack(
                    trackID: track.id, smoothedBox: track.smoothedBox, identity: track.identity,
                    state: state(of: track))
            }
            .sorted { $0.trackID.rawValue < $1.trackID.rawValue }
        let matched = clock.now
        metricsState.recordLatency(.match, matched - embedded)
        metricsState.recordLatency(.total, matched - start)
        metricsState.recordProcessed(timestamp: now, embeds: faces.count)

        lastOutput = output
        continuation.yield(output)
        return output
    }

    /// Embeds the faces concurrently. Returns one entry per face, in input order; nil marks a
    /// failed or unusable embedding (no vote is cast for it).
    private func embed(_ faces: [(TrackID, FaceObservation)], in frame: VideoFrame) async -> [(
        TrackID, [Float]?
    )] {
        guard !faces.isEmpty else { return [] }
        let embedder = self.embedder
        let dimension = embedder.space.dimension
        let results = await withTaskGroup(of: (Int, [Float]?).self) { group in
            for (index, face) in faces.enumerated() {
                let observation = face.1
                group.addTask {
                    let vector = try? await embedder.embed(face: observation, in: frame)
                    guard let vector, vector.count == dimension, vector.allSatisfy(\.isFinite) else {
                        return (index, nil)
                    }
                    return (index, vector)
                }
            }
            var out = [[Float]?](repeating: nil, count: faces.count)
            for await (index, vector) in group { out[index] = vector }
            return out
        }
        return zip(faces, results).map { ($0.0, $1) }
    }

    private func isEmbeddable(_ track: FaceTrack, frameSize: CGSize) -> Bool {
        guard track.framesSinceSeen == 0 else { return false }  // stale observation
        let face = track.latest
        guard face.quality >= config.minFaceQuality else { return false }
        let side = min(
            Double(face.boundingBox.width * frameSize.width),
            Double(face.boundingBox.height * frameSize.height))
        return side >= config.minFaceSide
    }

    private func state(of track: FaceTrack) -> LensTrack.State {
        if track.framesSinceSeen > 0 { return .lost }
        return track.age < config.stableAfterFrames ? .appearing : .stable
    }

    private static func isKnown(_ result: MatchResult) -> Bool {
        if case .known = result { return true }
        return false
    }

    /// Pixel size of the frame once `orientation` is applied (the space observations live in).
    static func uprightPixelSize(of frame: VideoFrame) -> CGSize {
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        switch frame.orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: height, height: width)
        default:
            return CGSize(width: width, height: height)
        }
    }
}

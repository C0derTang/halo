import CoreGraphics
import Foundation
import HaloCore

/// Tracker tuning. Defaults suit ~30 fps normalized face boxes.
public struct TrackerConfig: Sendable {
    /// Minimum IoU for a primary match.
    public var iouThreshold: Double
    /// Frames a track may go unseen before it is dropped.
    public var maxMissedFrames: Int
    /// Fallback match: center distance must be <= this factor * the track's mean box side.
    public var maxCenterDistanceFactor: Double
    /// Fallback match: width/height ratio between track and observation must lie in 1/r...r.
    public var maxSizeRatio: Double
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double

    public init(
        iouThreshold: Double = 0.3, maxMissedFrames: Int = 10,
        maxCenterDistanceFactor: Double = 1.0, maxSizeRatio: Double = 1.6,
        minCutoff: Double = 1.0, beta: Double = 20.0, dCutoff: Double = 1.0
    ) {
        self.iouThreshold = iouThreshold
        self.maxMissedFrames = maxMissedFrames
        self.maxCenterDistanceFactor = maxCenterDistanceFactor
        self.maxSizeRatio = maxSizeRatio
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }
}

/// Greedy IoU tracker with constant-velocity prediction, center-distance fallback and One Euro
/// box smoothing. Pure value type. TrackIDs are monotonic and never reused, so a dropped face's
/// label can never attach to a different face (a re-appearing face is a NEW track, identity
/// `.unknown`). The tracker never sets identity; use `setIdentity(_:for:)` (HaloLens does).
public struct IoUTracker: FaceTracking, Sendable {
    private struct Entry: Sendable {
        var track: FaceTrack
        var rawBox: CGRect
        var velocity: CGPoint  // raw center displacement per frame
        var fx: OneEuroFilter
        var fy: OneEuroFilter
        var fw: OneEuroFilter
        var fh: OneEuroFilter

        /// Raw box extrapolated by velocity, for association.
        var predicted: CGRect {
            let m = CGFloat(min(track.framesSinceSeen + 1, IoUTracker.maxExtrapolationFrames))
            return rawBox.offsetBy(dx: velocity.x * m, dy: velocity.y * m)
        }
    }

    private typealias Pair = (score: Double, t: Int, o: Int)

    public var config: TrackerConfig
    private var entries: [Entry] = []
    private var nextID: UInt64 = 1
    /// Cap on how many frames of velocity extrapolation a coasting track gets.
    static let maxExtrapolationFrames = 3

    public init(config: TrackerConfig = TrackerConfig()) { self.config = config }

    /// Live tracks (including ones coasting through brief misses).
    public var tracks: [FaceTrack] { entries.map(\.track) }

    /// Attach an identity decision to a live track. Ignored for unknown/dropped IDs.
    public mutating func setIdentity(_ identity: MatchResult, for id: TrackID) {
        if let i = entries.firstIndex(where: { $0.track.id == id }) {
            entries[i].track.identity = identity
        }
    }

    public mutating func update(observations: [FaceObservation], timestamp: TimeInterval)
        -> [FaceTrack]
    {
        var obsUsed = Array(repeating: false, count: observations.count)
        var trackUsed = Array(repeating: false, count: entries.count)

        // Pass 1: IoU against predicted boxes, best pairs first.
        var pairs: [Pair] = []
        for (ti, e) in entries.enumerated() {
            for (oi, o) in observations.enumerated() {
                let iou = Self.iou(e.predicted, o.boundingBox)
                if iou >= config.iouThreshold { pairs.append((iou, ti, oi)) }
            }
        }
        assign(pairs, &trackUsed, &obsUsed, observations, timestamp, fallback: false)

        // Pass 2: center-distance fallback for fast motion, with a size-consistency guard.
        pairs.removeAll()
        for (ti, e) in entries.enumerated() where !trackUsed[ti] {
            let p = e.predicted
            let side = Double(p.width + p.height) / 2
            guard side > 0 else { continue }
            for (oi, o) in observations.enumerated() where !obsUsed[oi] {
                let b = o.boundingBox
                let d = hypot(Double(b.midX - p.midX), Double(b.midY - p.midY))
                let wr = Double(b.width / max(p.width, 1e-9))
                let hr = Double(b.height / max(p.height, 1e-9))
                let r = config.maxSizeRatio
                guard d <= config.maxCenterDistanceFactor * side,
                    wr <= r, wr >= 1 / r, hr <= r, hr >= 1 / r
                else { continue }
                pairs.append((-d, ti, oi))  // nearer is better
            }
        }
        assign(pairs, &trackUsed, &obsUsed, observations, timestamp, fallback: true)

        // Unmatched tracks coast, then drop.
        for ti in entries.indices where !trackUsed[ti] {
            entries[ti].track.framesSinceSeen += 1
            entries[ti].track.age += 1
        }
        entries.removeAll { $0.track.framesSinceSeen > config.maxMissedFrames }

        // Unmatched observations start new tracks (fresh, never-reused IDs; identity unknown).
        for (oi, o) in observations.enumerated() where !obsUsed[oi] {
            entries.append(makeEntry(o, timestamp: timestamp))
        }
        return tracks
    }

    // MARK: - Internals

    private mutating func assign(
        _ candidates: [Pair], _ trackUsed: inout [Bool], _ obsUsed: inout [Bool],
        _ observations: [FaceObservation], _ timestamp: TimeInterval, fallback: Bool
    ) {
        // Best score first; deterministic tie-break on indices.
        let sorted = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.t != $1.t { return $0.t < $1.t }
            return $0.o < $1.o
        }
        for p in sorted where !trackUsed[p.t] && !obsUsed[p.o] {
            trackUsed[p.t] = true
            obsUsed[p.o] = true
            apply(observations[p.o], to: p.t, timestamp: timestamp, fallback: fallback)
        }
    }

    private mutating func apply(
        _ o: FaceObservation, to i: Int, timestamp: TimeInterval, fallback: Bool
    ) {
        var e = entries[i]
        // Invariant: a track re-associated after a miss by the loose fallback may be a different
        // face, so it must not keep a previous identity.
        if fallback && e.track.framesSinceSeen > 0 { e.track.identity = .unknown }
        let b = o.boundingBox
        let missed = CGFloat(e.track.framesSinceSeen + 1)
        let dx = (b.midX - e.rawBox.midX) / missed
        let dy = (b.midY - e.rawBox.midY) / missed
        // Light smoothing of velocity so one noisy frame doesn't fling the prediction.
        e.velocity = CGPoint(x: 0.5 * e.velocity.x + 0.5 * dx, y: 0.5 * e.velocity.y + 0.5 * dy)
        e.rawBox = b
        let cx = e.fx.filter(Double(b.midX), timestamp: timestamp)
        let cy = e.fy.filter(Double(b.midY), timestamp: timestamp)
        let w = e.fw.filter(Double(b.width), timestamp: timestamp)
        let h = e.fh.filter(Double(b.height), timestamp: timestamp)
        e.track.smoothedBox = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        e.track.latest = o
        e.track.age += 1
        e.track.framesSinceSeen = 0
        entries[i] = e
    }

    private mutating func makeEntry(_ o: FaceObservation, timestamp: TimeInterval) -> Entry {
        let c = config
        var fx = OneEuroFilter(minCutoff: c.minCutoff, beta: c.beta, dCutoff: c.dCutoff)
        var fy = fx
        var fw = fx
        var fh = fx
        let b = o.boundingBox
        _ = fx.filter(Double(b.midX), timestamp: timestamp)
        _ = fy.filter(Double(b.midY), timestamp: timestamp)
        _ = fw.filter(Double(b.width), timestamp: timestamp)
        _ = fh.filter(Double(b.height), timestamp: timestamp)
        let id = TrackID(nextID)
        nextID += 1
        let track = FaceTrack(id: id, smoothedBox: b, latest: o, age: 1, framesSinceSeen: 0)
        return Entry(track: track, rawBox: b, velocity: .zero, fx: fx, fy: fy, fw: fw, fh: fh)
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = Double(i.width * i.height)
        let union = Double(a.width * a.height + b.width * b.height) - inter
        return union > 0 ? inter / union : 0
    }
}

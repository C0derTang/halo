import CoreGraphics
import Foundation
import HaloCore
import Testing

@testable import HaloTracking

private func obs(_ cx: Double, _ cy: Double, _ s: Double, t: Double) -> FaceObservation {
    FaceObservation(
        boundingBox: CGRect(x: cx - s / 2, y: cy - s / 2, width: s, height: s), quality: 1,
        timestamp: t)
}

private let dt = 1.0 / 30

@Test func steadyFaceKeepsID() {
    var tr = IoUTracker()
    var ids = Set<TrackID>()
    for f in 0..<60 {
        let t = Double(f) * dt
        let out = tr.update(observations: [obs(0.5 + 0.001 * Double(f), 0.5, 0.2, t: t)], timestamp: t)
        #expect(out.count == 1)
        ids.insert(out[0].id)
    }
    #expect(ids.count == 1)
}

@Test func parallelFacesKeepIDs() {
    var tr = IoUTracker()
    var first: [TrackID] = []
    for f in 0..<60 {
        let t = Double(f) * dt
        let x = 0.2 + 0.005 * Double(f)
        let out = tr.update(
            observations: [obs(x, 0.3, 0.15, t: t), obs(x, 0.7, 0.15, t: t)], timestamp: t)
        #expect(out.count == 2)
        let ordered = out.sorted { $0.latest.boundingBox.midY < $1.latest.boundingBox.midY }.map(\.id)
        if f == 0 { first = ordered } else { #expect(ordered == first) }
    }
}

@Test func crossingFacesWithDistinctSizesKeepIDs() {
    var tr = IoUTracker()
    var bigID: TrackID?
    var smallID: TrackID?
    let frames = 60
    for f in 0...frames {
        let t = Double(f) * dt
        let p = Double(f) / Double(frames)
        // Big face goes left->right, small face right->left, same row.
        let big = obs(0.2 + 0.6 * p, 0.5, 0.24, t: t)
        let small = obs(0.8 - 0.6 * p, 0.5, 0.12, t: t)
        let out = tr.update(observations: [big, small], timestamp: t)
        #expect(out.count == 2)
        let b = out.first { $0.latest.boundingBox.width > 0.18 }!
        let s = out.first { $0.latest.boundingBox.width < 0.18 }!
        if f == 0 {
            bigID = b.id
            smallID = s.id
        } else {
            #expect(b.id == bigID)
            #expect(s.id == smallID)
        }
    }
}

@Test func faceLeavingLongerThanMaxMissedGetsNewID() {
    var tr = IoUTracker(config: TrackerConfig(maxMissedFrames: 10))
    var t = 0.0
    let first = tr.update(observations: [obs(0.5, 0.5, 0.2, t: t)], timestamp: t)[0].id
    tr.setIdentity(.ambiguous, for: first)
    for _ in 0..<11 {
        t += dt
        _ = tr.update(observations: [], timestamp: t)
    }
    #expect(tr.tracks.isEmpty)
    t += dt
    let again = tr.update(observations: [obs(0.5, 0.5, 0.2, t: t)], timestamp: t)[0]
    #expect(again.id != first)
    #expect(again.id.rawValue > first.rawValue)
    #expect(again.identity == .unknown)
}

@Test func iouRematchAfterLongGapResetsIdentity() {
    var tr = IoUTracker(config: TrackerConfig(maxMissedFrames: 10, identityResetAfterMissed: 5))
    var t = 0.0
    let id = tr.update(observations: [obs(0.5, 0.5, 0.2, t: t)], timestamp: t)[0].id
    tr.setIdentity(.known(PersonID(), similarity: 0.9, margin: 0.2), for: id)
    for _ in 0..<6 {
        t += dt
        _ = tr.update(observations: [], timestamp: t)
    }
    t += dt
    let out = tr.update(observations: [obs(0.5, 0.5, 0.2, t: t)], timestamp: t)
    #expect(out.count == 1)
    #expect(out[0].id == id)  // exact IoU re-match keeps the track...
    #expect(out[0].identity == .unknown)  // ...but not the name
}

@Test func shortOcclusionKeepsIDAndIdentity() {
    var tr = IoUTracker(config: TrackerConfig(maxMissedFrames: 10))
    var t = 0.0
    let id = tr.update(observations: [obs(0.5, 0.5, 0.2, t: t)], timestamp: t)[0].id
    let who = MatchResult.known(PersonID(), similarity: 0.9, margin: 0.2)
    tr.setIdentity(who, for: id)
    for _ in 0..<5 {
        t += dt
        let out = tr.update(observations: [], timestamp: t)
        #expect((out.first?.framesSinceSeen ?? 0) > 0)
    }
    t += dt
    let out = tr.update(observations: [obs(0.5, 0.5, 0.2, t: t)], timestamp: t)
    #expect(out.count == 1)
    #expect(out[0].id == id)
    #expect(out[0].identity == who)
    #expect(out[0].framesSinceSeen == 0)
}

@Test func identityPreservedAcrossUpdates() {
    var tr = IoUTracker()
    var t = 0.0
    let id = tr.update(observations: [obs(0.5, 0.5, 0.2, t: t)], timestamp: t)[0].id
    #expect(tr.tracks[0].identity == .unknown)
    tr.setIdentity(.ambiguous, for: id)
    for _ in 0..<5 {
        t += dt
        let out = tr.update(observations: [obs(0.5, 0.5, 0.2, t: t)], timestamp: t)
        #expect(out[0].identity == .ambiguous)
    }
}

@Test func fastMotionUsesCenterDistanceFallback() {
    var tr = IoUTracker()
    let a = tr.update(observations: [obs(0.3, 0.5, 0.1, t: 0)], timestamp: 0)[0].id
    // Jump of 0.08 with 0.1 box: zero IoU, but within center-distance fallback.
    let out = tr.update(observations: [obs(0.38, 0.5, 0.1, t: dt)], timestamp: dt)
    #expect(out.count == 1)
    #expect(out[0].id == a)
}

@Test func distantNewFaceGetsNewTrack() {
    var tr = IoUTracker()
    let a = tr.update(observations: [obs(0.2, 0.2, 0.1, t: 0)], timestamp: 0)[0].id
    let out = tr.update(observations: [obs(0.8, 0.8, 0.1, t: dt)], timestamp: dt)
    #expect(out.contains { $0.id != a })
    #expect(out.count == 2)
}

// MARK: - One Euro

private struct LCG {
    var s: UInt64 = 42
    mutating func next() -> Double {  // uniform in -1...1
        s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(s >> 11) / Double(1 << 53) * 2 - 1
    }
}

private func variance(_ xs: [Double]) -> Double {
    let m = xs.reduce(0, +) / Double(xs.count)
    return xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
}

@Test func oneEuroReducesJitterVariance() {
    var f = OneEuroFilter(minCutoff: 1.0, beta: 0.5, dCutoff: 1.0)
    var rng = LCG()
    var raw: [Double] = []
    var out: [Double] = []
    for i in 0..<300 {
        let v = 0.5 + 0.01 * rng.next()
        raw.append(v)
        out.append(f.filter(v, timestamp: Double(i) * dt))
    }
    #expect(variance(Array(out.dropFirst(10))) < 0.5 * variance(Array(raw.dropFirst(10))))
}

@Test func oneEuroLagsStepByFewFrames() {
    var f = OneEuroFilter(minCutoff: 1.0, beta: 20.0, dCutoff: 1.0)
    var t = 0.0
    for _ in 0..<30 {
        _ = f.filter(0.2, timestamp: t)
        t += dt
    }
    var frames = 0
    while frames < 100 {
        let v = f.filter(0.6, timestamp: t)
        t += dt
        frames += 1
        if abs(v - 0.6) < 0.02 { break }
    }
    #expect(frames <= 10)
}

@Test func oneEuroHandlesVariableDtAndBadTimestamps() {
    var f = OneEuroFilter()
    #expect(f.filter(1.0, timestamp: 0) == 1.0)
    let a = f.filter(2.0, timestamp: 0.5)  // long gap: moves most of the way
    #expect(a > 1.5 && a <= 2.0)
    #expect(f.filter(9.0, timestamp: 0.5) == a)  // dt == 0
    #expect(f.filter(9.0, timestamp: 0.1) == a)  // backwards
    #expect(f.filter(3.0, timestamp: 0.5001).isFinite)
}

@Test func smoothedBoxTracksSteadyInput() {
    var tr = IoUTracker()
    var last: FaceTrack?
    for f in 0..<30 {
        let t = Double(f) * dt
        last = tr.update(observations: [obs(0.5, 0.5, 0.2, t: t)], timestamp: t)[0]
    }
    let b = last!.smoothedBox
    #expect(abs(b.midX - 0.5) < 1e-6 && abs(b.width - 0.2) < 1e-6)
}

// MARK: - Identity safety while coasting

@Test func fallbackRematchAfterMissResetsIdentity() {
    var tr = IoUTracker()
    let id = tr.update(observations: [obs(0.3, 0.5, 0.1, t: 0)], timestamp: 0)[0].id
    tr.setIdentity(.known(PersonID(), similarity: 0.9, margin: 0.2), for: id)
    _ = tr.update(observations: [], timestamp: dt)
    // Zero IoU, within center-distance: fallback re-match after a miss.
    let out = tr.update(observations: [obs(0.38, 0.5, 0.1, t: 2 * dt)], timestamp: 2 * dt)
    #expect(out.count == 1)
    #expect(out[0].id == id)
    #expect(out[0].identity == .unknown)
}

@Test func swappedFacesDuringCoastingCarryNoIdentity() {
    var tr = IoUTracker()
    let out0 = tr.update(
        observations: [obs(0.3, 0.5, 0.1, t: 0), obs(0.7, 0.5, 0.1, t: 0)], timestamp: 0)
    let left = out0.first { $0.latest.boundingBox.midX < 0.5 }!.id
    let right = out0.first { $0.latest.boundingBox.midX > 0.5 }!.id
    tr.setIdentity(.known(PersonID(), similarity: 0.9, margin: 0.2), for: left)
    tr.setIdentity(.known(PersonID(), similarity: 0.9, margin: 0.2), for: right)
    _ = tr.update(observations: [], timestamp: dt)
    // Both reappear slightly displaced (no IoU overlap); any carried identity would be unsafe.
    let out = tr.update(
        observations: [obs(0.38, 0.5, 0.1, t: 2 * dt), obs(0.62, 0.5, 0.1, t: 2 * dt)],
        timestamp: 2 * dt)
    #expect(out.count == 2)
    for t in out { #expect(t.identity == .unknown) }
}

@Test func extrapolationIsCapped() {
    var tr = IoUTracker(config: TrackerConfig(maxMissedFrames: 20))
    var t = 0.0
    for f in 0..<5 {
        t = Double(f) * dt
        _ = tr.update(observations: [obs(0.2 + 0.03 * Double(f), 0.5, 0.1, t: t)], timestamp: t)
    }
    let id = tr.tracks[0].id
    for _ in 0..<15 {
        t += dt
        _ = tr.update(observations: [], timestamp: t)
    }
    // Uncapped extrapolation would predict far right (~0.8); a face near the last position
    // must match the track, a face at the uncapped prediction must not.
    t += dt
    let out = tr.update(observations: [obs(0.8, 0.5, 0.1, t: t)], timestamp: t)
    #expect(!out.contains { $0.id == id && $0.framesSinceSeen == 0 })
}

@Test func setIdentityOnUnknownOrDroppedIDIsNoOp() {
    var tr = IoUTracker(config: TrackerConfig(maxMissedFrames: 1))
    let id = tr.update(observations: [obs(0.5, 0.5, 0.2, t: 0)], timestamp: 0)[0].id
    tr.setIdentity(.ambiguous, for: TrackID(9999))
    #expect(tr.tracks[0].identity == .unknown)
    _ = tr.update(observations: [], timestamp: dt)
    _ = tr.update(observations: [], timestamp: 2 * dt)
    #expect(tr.tracks.isEmpty)
    tr.setIdentity(.ambiguous, for: id)
    #expect(tr.tracks.isEmpty)
    let n = tr.update(observations: [obs(0.5, 0.5, 0.2, t: 3 * dt)], timestamp: 3 * dt)
    #expect(n[0].identity == .unknown)
}

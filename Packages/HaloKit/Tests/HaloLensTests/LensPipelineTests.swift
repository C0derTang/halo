import CoreGraphics
import Foundation
import HaloCore
import Testing

@testable import HaloLens

// MARK: - Voting (invariant 4)

@Test func labelAppearsOnlyAfterMinVotes() async {
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    let outputs = await h.run(0..<5, faces: [face(x: 0.3)])

    for frame in 0..<2 {
        #expect(outputs[frame].count == 1)
        #expect(outputs[frame][0].identity == .unknown, "frame \(frame) must not be labeled yet")
        #expect(outputs[frame][0].personID == nil)
    }
    for frame in 2..<5 {
        #expect(outputs[frame][0].personID == person(1))
    }
    // Exactly one embed per frame: the label came from minVotes agreeing matches.
    #expect(h.embedder.calls.count == 5)
}

@Test func minVotesHonoredForLargerPolicy() async {
    let policy = MatchPolicy(minSimilarity: 0.5, minMargin: 0.1, minVotes: 5)
    let h = Harness(policy: policy, config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    let outputs = await h.run(0..<6, faces: [face(x: 0.3)])
    #expect(outputs[0..<4].allSatisfy { $0[0].personID == nil })
    #expect(outputs[4][0].personID == person(1))
}

@Test func interruptedStreakDoesNotLabel() async {
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    var outputs = await h.run(0..<2, faces: [face(x: 0.3)])
    h.embedder.setCode(-1, x: 0.3)  // ambiguous breaks the streak
    outputs += await h.run(2..<3, faces: [face(x: 0.3)])
    h.embedder.setCode(1, x: 0.3)
    outputs += await h.run(3..<6, faces: [face(x: 0.3)])
    #expect(outputs[0..<5].allSatisfy { $0[0].personID == nil })
    #expect(outputs[5][0].personID == person(1))
}

@Test func wrongPersonEvidenceDropsLabel() async {
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    await h.run(0..<3, faces: [face(x: 0.3)])
    #expect(await h.pipeline.currentTracks[0].personID == person(1))

    h.embedder.setCode(2, x: 0.3)
    let after = await h.run(3..<9, faces: [face(x: 0.3)])
    // Person 2 needs its own full streak; person 1 must be gone once person 2 is shown.
    #expect(after[0][0].personID != person(2))
    #expect(after[1][0].personID != person(2))
    #expect(after.last?[0].personID == person(2))
    let firstTwo = after.firstIndex { $0[0].personID == person(2) }!
    #expect(after[firstTwo...].allSatisfy { $0[0].personID == person(2) })
}

@Test func unknownEvidenceDropsLabel() async {
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    await h.run(0..<3, faces: [face(x: 0.3)])
    h.embedder.setCode(0, x: 0.3)
    let after = await h.run(3..<6, faces: [face(x: 0.3)])
    #expect(after.last?[0].identity == .unknown)
    #expect(after.last?[0].personID == nil)
}

@Test func identityFlowsIntoTrackerAndOutput() async {
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    let outputs = await h.run(0..<3, faces: [face(x: 0.3)])
    guard case .known(let p, let similarity, _) = outputs[2][0].identity else {
        Issue.record("expected a known identity")
        return
    }
    #expect(p == person(1))
    #expect(similarity == 0.9)
}

// MARK: - Embedding throttle (invariant 7)

@Test func embedThrottlePerTrack() async {
    let h = Harness()  // default 0.25 s
    await h.run(0..<60, faces: [face(x: 0.3)])
    let times = h.embedder.calls.map(\.time)
    #expect(times.count >= 7 && times.count <= 8, "about 4 embeds per second, got \(times.count)")
    for (a, b) in zip(times, times.dropFirst()) {
        #expect(b - a >= 0.25 - 1e-9)
    }
}

@Test func maxEmbedsPerFrameHonored() async {
    let config = LensConfig(embedInterval: 0, reverifyInterval: 1, maxEmbedsPerFrame: 2)
    let h = Harness(config: config)
    let faces = (0..<5).map { face(x: 0.05 + Double($0) * 0.18, size: 0.15) }
    for i in 0..<10 {
        h.detector.faces = faces
        let before = h.embedder.calls.count
        await h.pipeline.process(h.frames.frame(i))
        #expect(h.embedder.calls.count - before <= 2)
    }
    // Budget is shared fairly: every face got embedded.
    #expect(Set(h.embedder.calls.map(\.key)).count == 5)
    #expect(await h.pipeline.metrics.embedsLastFrame == 2)
}

@Test func unlabeledTracksPrioritizedOverLabeled() async {
    let config = LensConfig(embedInterval: 0, reverifyInterval: 1, maxEmbedsPerFrame: 1)
    let h = Harness(config: config)
    h.embedder.setCode(1, x: 0.1)
    await h.run(0..<3, faces: [face(x: 0.1, size: 0.15)])
    #expect(await h.pipeline.currentTracks[0].personID == person(1))

    // A newcomer appears: while the label is not overdue, the newcomer gets the single slot.
    let before = h.embedder.calls(x: 0.1).count
    await h.run(3..<10, faces: [face(x: 0.1, size: 0.15), face(x: 0.6, size: 0.15)])
    #expect(h.embedder.calls(x: 0.1).count == before)
    #expect(h.embedder.calls(x: 0.6).count == 7)
}

@Test func lowQualityAndTinyFacesNeverEmbedded() async {
    let h = Harness(config: everyFrame)
    // 640x480 frame: 0.05 * 480 = 24 px < 48 px minimum side.
    let tiny = face(x: 0.1, size: 0.05)
    let blurry = face(x: 0.5, quality: 0.1)
    let outputs = await h.run(0..<10, faces: [tiny, blurry])
    #expect(h.embedder.calls.isEmpty)
    #expect(outputs.last?.count == 2)
    #expect(outputs.last?.allSatisfy { $0.identity == .unknown } == true)
}

@Test func coastingTrackNotEmbedded() async {
    let h = Harness(config: everyFrame)
    await h.run(0..<2, faces: [face(x: 0.3)])
    let before = h.embedder.calls.count
    let outputs = await h.run(2..<5, faces: [])
    #expect(h.embedder.calls.count == before)
    #expect(outputs.allSatisfy { $0.first?.state == .lost })
}

// MARK: - Re-verification

@Test func labeledTrackReverifiedUnderContention() async {
    // One slot per frame, three always-due unlabeled newcomers competing for it.
    let config = LensConfig(embedInterval: 0, reverifyInterval: 1, maxEmbedsPerFrame: 1)
    let h = Harness(config: config)
    h.embedder.setCode(1, x: 0.05)
    await h.run(0..<3, faces: [face(x: 0.05, size: 0.15)])
    let crowd = [face(x: 0.05, size: 0.15), face(x: 0.3, size: 0.15), face(x: 0.55, size: 0.15)]
    let outputs = await h.run(3..<93, faces: crowd + [face(x: 0.8, size: 0.15)])

    let labeled = h.embedder.calls(x: 0.05).map(\.time)
    #expect(labeled.count >= 4)
    for (a, b) in zip(labeled, labeled.dropFirst()) {
        #expect(b - a <= 1.0 + frameDuration + 1e-9, "re-verify gap \(b - a)")
    }
    // The label held through the whole run because it kept being re-verified.
    #expect(outputs.allSatisfy { $0.first { $0.smoothedBox.minX < 0.1 }?.personID == person(1) })
}

@Test func labelDropsWhenEvidenceStops() async {
    let h = Harness()  // default: reverify 1 s, stale after 2 s
    h.embedder.setCode(1, x: 0.3)
    let acquire = await h.run(0..<75, faces: [face(x: 0.3)])
    #expect(acquire.last?[0].personID == person(1))

    // Face still detected but now too blurry to embed: no new evidence.
    let outputs = await h.run(75..<150, faces: [face(x: 0.3, quality: 0.05)])
    let lastEmbed = h.embedder.calls.last!.time
    for (offset, out) in outputs.enumerated() {
        let t = Double(75 + offset) * frameDuration
        if t - lastEmbed > 2.0 + 1e-9 {
            #expect(out[0].personID == nil, "label must drop after the stale timeout (t=\(t))")
        }
    }
    #expect(outputs.last?[0].identity == .unknown)
    // And it never comes back without new votes.
    let more = await h.run(150..<160, faces: [face(x: 0.3, quality: 0.05)])
    #expect(more.allSatisfy { $0[0].personID == nil })
}

// MARK: - Track lifecycle

@Test func lostTrackClearedFromVoter() async {
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    await h.run(0..<3, faces: [face(x: 0.3)])
    #expect(await h.pipeline.voterTrackCount == 1)

    // Default tracker drops a track after 10 missed frames.
    let outputs = await h.run(3..<20, faces: [])
    #expect(outputs[0].first?.state == .lost)
    #expect(outputs.last?.isEmpty == true)
    #expect(await h.pipeline.voterTrackCount == 0)
    #expect(await h.pipeline.scheduledTrackCount == 0)
}

@Test func identityNeverTransfersToNewTrack() async {
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    let first = await h.run(0..<3, faces: [face(x: 0.3)])
    let oldID = first[2][0].trackID
    #expect(first[2][0].personID == person(1))

    await h.run(3..<20, faces: [])  // track lost and dropped
    h.embedder.setCode(2, x: 0.3)  // a different person at the same spot
    let second = await h.run(20..<25, faces: [face(x: 0.3)])
    #expect(second.allSatisfy { $0[0].trackID != oldID })
    #expect(second.allSatisfy { $0[0].personID != person(1) })
    #expect(second[0][0].identity == .unknown)
    #expect(second[1][0].identity == .unknown)
    #expect(second[2][0].personID == person(2))
}

@Test func sameTrackSameFaceDoesNotReacquireAfterTrackerClearsIdentity() async {
    // A loose (center-distance) re-association after a miss makes the tracker clear identity;
    // the pipeline must then discard the voter state instead of re-applying the old label.
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    h.embedder.setCode(1, x: 0.45)
    let first = await h.run(0..<3, faces: [face(x: 0.3)])
    #expect(first[2][0].personID == person(1))
    await h.run(3..<4, faces: [])
    let jumped = await h.run(4..<5, faces: [face(x: 0.45)])
    #expect(jumped[0].count == 1)
    if jumped[0][0].trackID == first[2][0].trackID {
        #expect(jumped[0][0].identity == .unknown)
    }
    #expect(jumped[0][0].personID == nil)
}

@Test func partialStreakDiscardedWhenTrackReappearsAfterMiss() async {
    // Two votes for person 1 on face A, a missed frame, then a loose re-match to face B that
    // also reads as person 1 once: that single vote must not complete A's streak.
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    h.embedder.setCode(1, x: 0.45)
    let before = await h.run(0..<2, faces: [face(x: 0.3)])
    #expect(before.allSatisfy { $0[0].personID == nil })
    await h.run(2..<3, faces: [])
    let jumped = await h.run(3..<4, faces: [face(x: 0.45)])
    #expect(jumped[0].count == 1)
    #expect(jumped[0][0].trackID == before[0][0].trackID, "fixture expects the tracker to re-associate")
    #expect(jumped[0][0].personID == nil)
    // A full fresh streak on the new face is still needed.
    let more = await h.run(4..<6, faces: [face(x: 0.45)])
    #expect(more[0][0].personID == nil)
    #expect(more[1][0].personID == person(1))
}

@Test func labelRequiresFreshVotesAfterMissEvenOnIoUMatch() async {
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    await h.run(0..<3, faces: [face(x: 0.3)])
    await h.run(3..<4, faces: [])
    let back = await h.run(4..<7, faces: [face(x: 0.3)])
    #expect(back[0][0].personID == nil)
    #expect(back[1][0].personID == nil)
    #expect(back[2][0].personID == person(1))
}

@Test func twoFacesKeepSeparateIdentities() async {
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.1)
    h.embedder.setCode(2, x: 0.6)
    let outputs = await h.run(0..<4, faces: [face(x: 0.1), face(x: 0.6)])
    let last = outputs.last!
    #expect(last.count == 2)
    #expect(Set(last.compactMap(\.personID)) == [person(1), person(2)])
    let left = last.first { $0.smoothedBox.minX < 0.3 }!
    #expect(left.personID == person(1))
}

@Test func trackStatesProgress() async {
    let h = Harness()
    let outputs = await h.run(0..<4, faces: [face(x: 0.3)])
    #expect(outputs[0][0].state == .appearing)
    #expect(outputs[1][0].state == .appearing)
    #expect(outputs[2][0].state == .stable)
    let lost = await h.run(4..<5, faces: [])
    #expect(lost[0][0].state == .lost)
}

// MARK: - Failure paths

@Test func embedderFailureCastsNoVote() async {
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    h.embedder.setFailing(x: 0.3)
    let outputs = await h.run(0..<6, faces: [face(x: 0.3)])
    #expect(outputs.allSatisfy { $0[0].identity == .unknown })
    #expect(await h.pipeline.metrics.embedderErrors == 6)
}

@Test func wrongDimensionEmbeddingRejected() async {
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    h.embedder.setWrongDimension(true)
    let outputs = await h.run(0..<6, faces: [face(x: 0.3)])
    #expect(outputs.allSatisfy { $0[0].identity == .unknown })
}

@Test func detectorFailureFailsClosed() async {
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    await h.run(0..<3, faces: [face(x: 0.3)])
    h.detector.setFails(true)
    let outputs = await h.run(3..<20, faces: [face(x: 0.3)])
    #expect(outputs.last?.isEmpty == true)
    #expect(await h.pipeline.metrics.detectorErrors == 17)
}

@Test func setMatcherClearsLabelsImmediately() async {
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    await h.run(0..<3, faces: [face(x: 0.3)])
    #expect(await h.pipeline.currentTracks[0].personID == person(1))

    await h.pipeline.setMatcher(NullMatcher())
    #expect(await h.pipeline.currentTracks[0].identity == .unknown)
    let outputs = await h.run(3..<8, faces: [face(x: 0.3)])
    #expect(outputs.allSatisfy { $0[0].identity == .unknown })
}

// MARK: - Frame dropping + concurrency (invariant 7)

@Test func framesDroppedWhileBusyNoBacklog() async {
    let h = Harness(config: everyFrame)
    h.detector.faces = [face(x: 0.3)]
    h.detector.hold()  // the first frame stays in flight until released

    #expect(h.pipeline.submit(h.frames.frame(0)))
    var accepted = 0
    for i in 1...100 where h.pipeline.submit(h.frames.frame(i)) { accepted += 1 }
    #expect(accepted == 0, "frames arriving while busy must be dropped, not queued")

    // Concurrent `process` calls are dropped too and return without waiting.
    await withTaskGroup(of: Void.self) { group in
        for i in 101...120 {
            group.addTask { _ = await h.pipeline.process(h.frames.frame(i)) }
        }
    }
    #expect(await h.pipeline.metrics.processedFrames == 0)

    h.detector.release()
    var iterator = h.pipeline.tracks.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first?.count == 1)
    #expect(h.detector.calls == 1)
    let metrics = await h.pipeline.metrics
    #expect(metrics.droppedFrames == 120)
    #expect(metrics.processedFrames == 1)

    // Once idle, the next frame is processed normally.
    let next = await h.pipeline.process(h.frames.frame(121))
    #expect(next.count == 1)
    #expect(h.detector.calls == 2)
}

@Test func droppedProcessCallReturnsPreviousResult() async {
    let h = Harness(config: everyFrame)
    var iterator = h.pipeline.tracks.makeAsyncIterator()
    await h.run(0..<1, faces: [face(x: 0.3)])
    let previous = await iterator.next()
    #expect(previous?.count == 1)

    h.detector.hold()
    h.detector.faces = [face(x: 0.3), face(x: 0.7)]
    #expect(h.pipeline.submit(h.frames.frame(1)))
    let dropped = await h.pipeline.process(h.frames.frame(2))
    #expect(dropped == previous)

    h.detector.release()
    let next = await iterator.next()
    #expect(next?.count == 2)
    #expect(h.detector.calls == 2)
}

@MainActor
@Test func detectionNeverRunsOnMainThread() async {
    let h = Harness(config: everyFrame)
    await h.run(0..<3, faces: [face(x: 0.3)])
    #expect(h.detector.calls == 3)
    #expect(!h.detector.calledOnMainThread)
}

@Test func outputStreamYieldsEachProcessedFrame() async {
    let h = Harness(config: everyFrame)
    h.embedder.setCode(1, x: 0.3)
    var iterator = h.pipeline.tracks.makeAsyncIterator()
    await h.run(0..<3, faces: [face(x: 0.3)])
    // Newest-only buffering: the consumer sees the latest state, not a backlog.
    let latest = await iterator.next()
    #expect(latest?.first?.personID == person(1))
}

@Test func metricsTrackFpsAndStages() async {
    let h = Harness(config: everyFrame)
    await h.run(0..<30, faces: [face(x: 0.3)])
    let m = await h.pipeline.metrics
    #expect(m.processedFrames == 30)
    #expect(abs(m.fps - 30) < 0.5)
    #expect(Set(m.latencyMilliseconds.keys) == Set(LensMetrics.Stage.allCases))
    #expect(m.totalEmbeds == 30)
}

@Test func uprightPixelSizeHonorsOrientation() {
    let portrait = FrameFactory(width: 1280, height: 720, orientation: .right)
    #expect(LensPipeline.uprightPixelSize(of: portrait.frame(0)) == CGSize(width: 720, height: 1280))
    let up = FrameFactory(width: 1280, height: 720, orientation: .up)
    #expect(LensPipeline.uprightPixelSize(of: up.frame(0)) == CGSize(width: 1280, height: 720))
}

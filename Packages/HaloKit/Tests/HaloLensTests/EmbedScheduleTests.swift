import Foundation
import HaloCore
import Testing

@testable import HaloLens

private func candidate(_ id: UInt64, labeled: Bool = false, eligible: Bool = true) -> EmbedSchedule.Candidate
{
    EmbedSchedule.Candidate(id: TrackID(id), labeled: labeled, eligible: eligible)
}

@Test func scheduleRespectsBudgetAndEligibility() {
    var s = EmbedSchedule()
    let config = LensConfig(embedInterval: 0.25, maxEmbedsPerFrame: 2)
    let chosen = s.select(
        [candidate(1), candidate(2, eligible: false), candidate(3), candidate(4)], now: 0, config: config)
    #expect(chosen == [TrackID(1), TrackID(3)])
    // Track 4 has waited longest (never attempted) next frame; 1 and 3 are throttled.
    #expect(s.select([candidate(1), candidate(3), candidate(4)], now: 0.1, config: config) == [TrackID(4)])
    #expect(s.select([candidate(1), candidate(3), candidate(4)], now: 0.2, config: config).isEmpty)
    #expect(s.select([candidate(1), candidate(3)], now: 0.25, config: config) == [TrackID(1), TrackID(3)])
}

@Test func scheduleZeroBudgetSelectsNothing() {
    var s = EmbedSchedule()
    let config = LensConfig(maxEmbedsPerFrame: 0)
    #expect(s.select([candidate(1)], now: 0, config: config).isEmpty)
}

@Test func schedulePriorityOrder() {
    let config = LensConfig(embedInterval: 0.25, reverifyInterval: 1, maxEmbedsPerFrame: 1)
    // At t=1.0: track 1 is overdue for re-verify (tier 0), 3 is unlabeled (tier 1), 2 is a
    // labeled track that is due but not overdue (tier 2).
    var fresh = EmbedSchedule()
    _ = fresh.select([candidate(1, labeled: true)], now: 0, config: config)
    _ = fresh.select([candidate(2, labeled: true)], now: 0.7, config: config)
    let order = [candidate(2, labeled: true), candidate(3), candidate(1, labeled: true)]
    #expect(fresh.select(order, now: 1.0, config: config) == [TrackID(1)])
    #expect(fresh.select(order, now: 1.05, config: config) == [TrackID(3)])
    #expect(fresh.select(order, now: 1.1, config: config) == [TrackID(2)])
}

@Test func scheduleClockGoingBackwardsMakesTrackDue() {
    var s = EmbedSchedule()
    let config = LensConfig(embedInterval: 0.25)
    _ = s.select([candidate(1)], now: 10, config: config)
    #expect(s.select([candidate(1)], now: 1, config: config) == [TrackID(1)])
}

@Test func scheduleStalenessAndRetain() {
    var s = EmbedSchedule()
    #expect(s.isStale(TrackID(1), now: 0, timeout: 2))
    s.recordEvidence(for: TrackID(1), at: 1)
    #expect(!s.isStale(TrackID(1), now: 3, timeout: 2))
    #expect(s.isStale(TrackID(1), now: 3.01, timeout: 2))
    _ = s.select([candidate(2)], now: 0, config: LensConfig())
    #expect(s.trackedCount == 2)
    s.retain(only: [TrackID(2)])
    #expect(s.trackedCount == 1)
    #expect(s.isStale(TrackID(1), now: 1, timeout: 2))
}

@Test func metricsFpsWindowAndReset() {
    var m = LensMetrics()
    for i in 0..<60 { m.recordProcessed(timestamp: Double(i) / 15, embeds: 1) }
    #expect(abs(m.fps - 15) < 1e-6)
    #expect(m.processedFrames == 60)
    #expect(m.totalEmbeds == 60)
    m.recordProcessed(timestamp: 0, embeds: 0)  // clock reset (camera restart)
    #expect(m.fps == 0)
    m.recordLatency(.detect, .milliseconds(10))
    m.recordLatency(.detect, .milliseconds(20))
    #expect(abs((m.latencyMilliseconds[.detect] ?? 0) - 11) < 1e-6)
}

@Test func staleLabelTimeoutAlwaysExceedsReverifyInterval() {
    #expect(LensConfig().staleLabelTimeout == 2)
    #expect(LensConfig(reverifyInterval: 1, staleLabelTimeout: 1.5).staleLabelTimeout == 1.5)
    #expect(LensConfig(reverifyInterval: 1, staleLabelTimeout: 1).staleLabelTimeout == 2)
    #expect(LensConfig(reverifyInterval: 1, staleLabelTimeout: 0.2).staleLabelTimeout == 2)
    #expect(LensConfig(reverifyInterval: 0, staleLabelTimeout: 0).staleLabelTimeout == 0.1)
    // Enforced after mutation too.
    var config = LensConfig(reverifyInterval: 1, staleLabelTimeout: 3)
    config.reverifyInterval = 4
    #expect(config.staleLabelTimeout > config.reverifyInterval)
    config.staleLabelTimeout = 0.5
    #expect(config.staleLabelTimeout == 8)
}

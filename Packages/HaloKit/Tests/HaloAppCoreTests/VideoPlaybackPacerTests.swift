import Foundation
import Testing

@testable import HaloAppCore

/// `VideoPlaybackPacer` with fake host times: no real clock, no timing flakiness.
struct VideoPlaybackPacerTests {
    let interval = 1.0 / 30

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test func firstFrameIsImmediateAndLaterFramesFollowTheirTimestamps() {
        var pacer = VideoPlaybackPacer(minimumInterval: interval)
        let accepted = [0, interval, 2 * interval].map { pacer.accept(mediaTime: $0) }
        #expect(accepted == [true, true, true])
        let first = pacer.delay(for: 0, now: 100)
        let second = pacer.delay(for: interval, now: 100.001)
        let third = pacer.delay(for: 2 * interval, now: 100.04)
        #expect(first == 0)
        #expect(close(second, interval - 0.001))
        #expect(close(third, 2 * interval - 0.04))
    }

    @Test func aLateFrameDoesNotShiftTheClock() {
        var pacer = VideoPlaybackPacer(minimumInterval: interval)
        _ = pacer.delay(for: 0, now: 100)
        // Frame at 0.1 s shown 20 ms late: shown now, and the next one catches up.
        let late = pacer.delay(for: 0.1, now: 100.12)
        let next = pacer.delay(for: 0.1 + interval, now: 100.12)
        #expect(late == 0)
        #expect(close(next, interval - 0.02))
    }

    @Test func fallingFarBehindReanchorsInsteadOfBursting() {
        var pacer = VideoPlaybackPacer(minimumInterval: interval)
        _ = pacer.delay(for: 0, now: 100)
        // 0.4 s late (more than maxLag): restart the clock at "now".
        let late = pacer.delay(for: 0.1, now: 100.5)
        let next = pacer.delay(for: 0.1 + interval, now: 100.5)
        #expect(late == 0)
        #expect(close(next, interval))
    }

    @Test func aNewPassStartsOneIntervalAfterTheLastFrame() {
        var pacer = VideoPlaybackPacer(minimumInterval: interval)
        _ = pacer.accept(mediaTime: 0)
        _ = pacer.delay(for: 0, now: 100)
        _ = pacer.accept(mediaTime: 0.1)
        _ = pacer.delay(for: 0.1, now: 100.05)  // scheduled for 100.1
        pacer.beginLoop()
        let acceptedAgain = pacer.accept(mediaTime: 0)  // the skip rule restarts too
        let loopStart = pacer.delay(for: 0, now: 100.1)
        #expect(acceptedAgain)
        #expect(close(loopStart, interval))

        // Already past that point: show at once.
        var late = VideoPlaybackPacer(minimumInterval: interval)
        _ = late.delay(for: 0, now: 100)
        late.beginLoop()
        let immediate = late.delay(for: 0, now: 101)
        #expect(immediate == 0)
    }

    @Test func timeGoingBackwardsWithinAPassReanchors() {
        var pacer = VideoPlaybackPacer(minimumInterval: interval)
        _ = pacer.accept(mediaTime: 1)
        _ = pacer.delay(for: 1, now: 100)
        let accepted = pacer.accept(mediaTime: 0.5)
        let delay = pacer.delay(for: 0.5, now: 100.01)
        #expect(accepted)
        #expect(delay == 0)
    }

    @Test func capsTheFrameRate() {
        // 60 fps file, 15 fps cap: every fourth frame.
        var pacer = VideoPlaybackPacer(minimumInterval: 1.0 / 15)
        let accepted = (0..<24).filter { pacer.accept(mediaTime: Double($0) / 60) }
        #expect(accepted == [0, 4, 8, 12, 16, 20])
    }

    @Test func keepsEveryFrameAtTheCap() {
        // A 30 fps file under a 30 fps cap, with timestamp jitter: nothing is thinned.
        var pacer = VideoPlaybackPacer(minimumInterval: interval)
        let times = (0..<30).map { Double($0) * interval + ($0.isMultiple(of: 2) ? 0.001 : -0.001) }
        let accepted = times.filter { pacer.accept(mediaTime: $0) }
        #expect(accepted.count == 30)
    }
}

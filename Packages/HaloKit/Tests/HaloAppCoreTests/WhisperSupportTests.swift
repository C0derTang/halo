import Testing

@testable import HaloAppCore

@MainActor
struct WhisperSupportTests {
    @Test func portTypeMapping() {
        #expect(AudioOutput.Kind(portType: "Headphones") == .wiredHeadphones)
        for bt in ["BluetoothA2DPOutput", "BluetoothHFP", "BluetoothLE"] {
            #expect(AudioOutput.Kind(portType: bt) == .bluetooth)
        }
        for other in ["Speaker", "Receiver", "AirPlay", "HDMI", "USBAudio", "CarAudio", "LineOut", ""] {
            #expect(AudioOutput.Kind(portType: other) == .other)
        }
    }

    @Test func lateFinishOfOldUtteranceDoesNotCompleteTheCurrentOne() {
        let gate = WhisperUtteranceGate()
        var results: [String] = []
        let a = gate.begin { _ in results.append("A") }
        gate.cancel()  // A stopped
        let b = gate.begin { _ in results.append("B") }
        gate.end(a, .finished)  // late finish of A
        #expect(results.isEmpty)
        gate.end(b, .finished)
        #expect(results == ["B"])
        gate.end(b, .finished)  // duplicate
        #expect(results == ["B"])
    }

    @Test func newUtteranceReplacesTheOldWithoutCompletingIt() {
        let gate = WhisperUtteranceGate()
        var results: [String] = []
        let a = gate.begin { _ in results.append("A") }
        let b = gate.begin { _ in results.append("B") }
        gate.end(a, .interrupted)
        #expect(results.isEmpty)
        gate.end(b, .finished)
        #expect(results == ["B"])
    }

    @Test func watchdogEndsAHungUtterance() async throws {
        let gate = WhisperUtteranceGate(timeout: .milliseconds(20))
        var results: [WhisperSpeechResult] = []
        var timedOut = false
        gate.onTimeout = { timedOut = true }
        _ = gate.begin { results.append($0) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(timedOut)
        #expect(results == [.interrupted])
    }

    @Test func finishBeforeTimeoutCancelsTheWatchdog() async throws {
        let gate = WhisperUtteranceGate(timeout: .milliseconds(50))
        var results: [WhisperSpeechResult] = []
        let id = gate.begin { results.append($0) }
        gate.end(id, .finished)
        try await Task.sleep(for: .milliseconds(300))
        #expect(results == [.finished])
    }
}

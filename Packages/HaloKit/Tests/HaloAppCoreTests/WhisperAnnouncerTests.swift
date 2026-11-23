import CoreGraphics
import Foundation
import HaloCore
import HaloUI
import Testing

@testable import HaloAppCore

@MainActor final class WhisperTestClock {
    var date = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

final class WhisperTestRoute: AudioRouteChecking, @unchecked Sendable {
    var outputs: [AudioOutput]
    init(_ outputs: [AudioOutput]) { self.outputs = outputs }
}

let whisperWired = AudioOutput(portUID: "wired", name: "Headphones", kind: .wiredHeadphones)
let whisperPods = AudioOutput(portUID: "pods", name: "Pods", kind: .bluetooth)
let whisperCar = AudioOutput(portUID: "car", name: "Car", kind: .bluetooth)
let whisperSpeaker = AudioOutput(portUID: "spk", name: "Speaker", kind: .other)

@MainActor final class WhisperTestSpeech: WhisperSpeaking {
    var spoken: [String] = []
    var stops = 0
    var completion: (@MainActor (WhisperSpeechResult) -> Void)?
    func speak(_ text: String, completion: @escaping @MainActor (WhisperSpeechResult) -> Void) {
        spoken.append(text)
        self.completion = completion
    }
    func stop() {
        stops += 1
        completion = nil
    }
    func finish(_ result: WhisperSpeechResult = .finished) {
        let c = completion
        completion = nil
        c?(result)
    }
}

@MainActor final class WhisperTestHaptics: WhisperHaptics {
    var taps = 0
    func tap() { taps += 1 }
}

@MainActor
struct WhisperAnnouncerTests {
    let speech = WhisperTestSpeech()
    let haptics = WhisperTestHaptics()
    let ada = PersonID()
    let ben = PersonID()
    let clock = WhisperTestClock()

    func item(_ track: Int, _ person: PersonID?, name: String = "Ada", state: HologramState = .stable)
        -> LensOverlayItem
    {
        LensOverlayItem(
            trackID: TrackID(UInt64(track)), rect: .zero, state: state,
            label: person.map {
                LabelData(
                    personID: $0, title: name,
                    chips: [
                        LabelChip(kind: .lastInteraction, text: "low", priority: 1),
                        LabelChip(kind: .upcoming, text: "lunch Friday", priority: 5),
                    ])
            })
    }

    func make(
        enabled: Bool = true, route: WhisperTestRoute, chip: Bool = true,
        trusted: Set<String> = []
    ) -> WhisperAnnouncer {
        WhisperAnnouncer(
            settings: WhisperSettings(isEnabled: enabled, speaksChip: chip), route: route,
            devices: InMemoryTrustedAudioDeviceStore(trusted), speech: speech, haptics: haptics,
            now: { [clock] in clock.date })
    }

    @Test func defaultsOff() {
        #expect(WhisperSettings().isEnabled == false)
        let a = WhisperAnnouncer(
            route: WhisperTestRoute([whisperWired]), speech: speech, haptics: haptics)
        a.update([item(1, ada)])
        #expect(speech.spoken.isEmpty && haptics.taps == 0)
    }

    @Test func speakerRouteIsSilent() {
        let a = make(route: WhisperTestRoute([whisperSpeaker]))
        a.update([item(1, ada)])
        #expect(speech.spoken.isEmpty)
    }

    @Test func mixedSpeakerAndHeadphonesIsSilent() {
        let a = make(route: WhisperTestRoute([whisperWired, whisperSpeaker]))
        a.update([item(1, ada)])
        #expect(speech.spoken.isEmpty)
    }

    @Test func wiredAnnouncesOncePerPersonSerialized() {
        let a = make(route: WhisperTestRoute([whisperWired]))
        a.update([item(1, ada), item(2, ben, name: "Ben")])
        #expect(speech.spoken == ["Ada — lunch Friday"])  // one at a time
        speech.finish()
        #expect(speech.spoken == ["Ada — lunch Friday", "Ben — lunch Friday"])
        speech.finish()
        a.update([item(1, ada), item(2, ben, name: "Ben"), item(7, ada)])
        #expect(speech.spoken.count == 2)
        #expect(haptics.taps == 2)
    }

    @Test func unknownAndUnstableAreSilent() {
        let a = make(route: WhisperTestRoute([whisperWired]))
        a.update([item(1, nil), item(2, ada, state: .appearing), item(3, ada, state: .lost)])
        #expect(speech.spoken.isEmpty && haptics.taps == 0)
    }

    @Test func chipCanBeDisabled() {
        let a = make(route: WhisperTestRoute([whisperWired]), chip: false)
        a.update([item(1, ada)])
        #expect(speech.spoken == ["Ada"])
    }

    @Test func routeFlipMidQueueStopsAndReannouncesLater() {
        let route = WhisperTestRoute([whisperWired])
        let a = make(route: route)
        a.update([item(1, ada), item(2, ben, name: "Ben")])
        #expect(speech.spoken.count == 1)
        route.outputs = [whisperSpeaker]
        a.routeDidChange()
        #expect(speech.stops == 1)
        speech.finish()  // stale completion must do nothing
        #expect(speech.spoken.count == 1)
        a.update([item(1, ada), item(2, ben, name: "Ben")])
        #expect(speech.spoken.count == 1)
        route.outputs = [whisperWired]
        a.routeDidChange()
        a.update([item(1, ada), item(2, ben, name: "Ben")])
        #expect(speech.spoken.count == 2)
        #expect(speech.spoken[1].hasPrefix("Ada"))
        speech.finish()
        #expect(speech.spoken.count == 3)
        #expect(speech.spoken[2].hasPrefix("Ben"))
    }

    @Test func routeCheckedBeforeEachUtteranceEvenWithoutNotification() {
        let route = WhisperTestRoute([whisperWired])
        let a = make(route: route)
        a.update([item(1, ada), item(2, ben, name: "Ben")])
        route.outputs = [whisperSpeaker]
        speech.finish()
        #expect(speech.spoken.count == 1)
        route.outputs = [whisperWired]
        a.update([item(2, ben, name: "Ben")])
        #expect(speech.spoken.count == 2)
    }

    @Test func unconfirmedBluetoothIsSilentAndPending() {
        let a = make(route: WhisperTestRoute([whisperCar]))
        a.update([item(1, ada)])
        #expect(speech.spoken.isEmpty)
        #expect(a.pendingDeviceConfirmation == whisperCar)
    }

    @Test func confirmedBluetoothAnnounces() {
        let route = WhisperTestRoute([whisperPods])
        let a = make(route: route)
        a.update([item(1, ada)])
        #expect(speech.spoken.isEmpty && a.pendingDeviceConfirmation == whisperPods)
        a.confirmPendingDevice()
        #expect(a.pendingDeviceConfirmation == nil)
        a.update([item(1, ada)])
        #expect(speech.spoken.count == 1)
    }

    @Test func previouslyTrustedBluetoothAnnouncesAndOthersStillBlocked() {
        let a = make(route: WhisperTestRoute([whisperPods]), trusted: ["pods"])
        a.update([item(1, ada)])
        #expect(speech.spoken.count == 1)
        let b = make(route: WhisperTestRoute([whisperCar]), trusted: ["pods"])
        b.update([item(1, ben)])
        #expect(speech.spoken.count == 1)
    }

    @Test func dismissedDeviceStaysSilent() {
        let a = make(route: WhisperTestRoute([whisperCar]))
        a.update([item(1, ada)])
        a.dismissPendingDevice()
        a.update([item(1, ada)])
        #expect(a.pendingDeviceConfirmation == nil && speech.spoken.isEmpty)
    }

    @Test func interruptedUtteranceIsReannounced() {
        let a = make(route: WhisperTestRoute([whisperWired]))
        a.update([item(1, ada)])
        speech.finish(.interrupted)
        clock.advance(WhisperAnnouncer.retryBackoff)
        a.update([item(1, ada)])
        #expect(speech.spoken.count == 2)
    }

    @Test func interruptedRetryWaitsForBackoff() {
        let a = make(route: WhisperTestRoute([whisperWired]))
        a.update([item(1, ada)])
        speech.finish(.interrupted)
        a.update([item(1, ada)])
        #expect(speech.spoken.count == 1)
        clock.advance(4.9)
        a.update([item(1, ada)])
        #expect(speech.spoken.count == 1)
        clock.advance(0.2)
        a.update([item(1, ada)])
        #expect(speech.spoken.count == 2)
    }

    @Test func interruptedRetriesAreCappedPerSession() {
        let a = make(route: WhisperTestRoute([whisperWired]))
        for _ in 0..<WhisperAnnouncer.maxInterruptedAttempts + 2 {
            a.update([item(1, ada)])
            speech.finish(.interrupted)
            clock.advance(WhisperAnnouncer.retryBackoff + 1)
        }
        a.update([item(1, ada)])
        #expect(speech.spoken.count == WhisperAnnouncer.maxInterruptedAttempts)

        // A new lens session starts fresh.
        a.resetSession()
        a.update([item(1, ada)])
        #expect(speech.spoken.count == WhisperAnnouncer.maxInterruptedAttempts + 1)
    }

    @Test func disablingCancelsImmediately() {
        let a = make(route: WhisperTestRoute([whisperWired]))
        a.update([item(1, ada), item(2, ben, name: "Ben")])
        a.settings.isEnabled = false
        #expect(speech.stops == 1)
        speech.finish()
        #expect(speech.spoken.count == 1)
        a.settings.isEnabled = true
        a.update([item(2, ben, name: "Ben")])
        #expect(speech.spoken.count == 2)
    }

    @Test func newSessionAnnouncesAgain() {
        let a = make(route: WhisperTestRoute([whisperWired]))
        a.update([item(1, ada)])
        speech.finish()
        a.resetSession()
        a.update([item(1, ada)])
        #expect(speech.spoken.count == 2)
    }
}

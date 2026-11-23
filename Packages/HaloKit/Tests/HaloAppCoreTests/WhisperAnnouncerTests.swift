import CoreGraphics
import HaloCore
import HaloUI
import Testing

@testable import HaloAppCore

struct WhisperTestRoute: AudioRouteChecking { var isPrivateRoute: Bool }

@MainActor final class WhisperTestSpeech: WhisperSpeaking {
    var spoken: [String] = []
    func speak(_ text: String) { spoken.append(text) }
    func stop() {}
}

@MainActor final class WhisperTestHaptics: WhisperHaptics {
    var taps = 0
    func tap() { taps += 1 }
}

final class WhisperTestMutableRoute: AudioRouteChecking, @unchecked Sendable {
    var isPrivateRoute = false
}

@MainActor
struct WhisperAnnouncerTests {
    let speech = WhisperTestSpeech()
    let haptics = WhisperTestHaptics()
    let ada = PersonID()
    let ben = PersonID()

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

    func make(enabled: Bool = true, headphones: Bool = true, chip: Bool = true) -> WhisperAnnouncer {
        WhisperAnnouncer(
            settings: WhisperSettings(isEnabled: enabled, speaksChip: chip),
            route: WhisperTestRoute(isPrivateRoute: headphones), speech: speech, haptics: haptics)
    }

    @Test func defaultsOff() {
        #expect(WhisperSettings().isEnabled == false)
        let a = WhisperAnnouncer(
            route: WhisperTestRoute(isPrivateRoute: true), speech: speech, haptics: haptics)
        a.update([item(1, ada)])
        #expect(speech.spoken.isEmpty && haptics.taps == 0)
    }

    @Test func speakerRouteIsSilent() {
        let a = make(headphones: false)
        a.update([item(1, ada)])
        #expect(speech.spoken.isEmpty)
    }

    @Test func headphonesAnnounceOncePerPerson() {
        let a = make()
        a.update([item(1, ada), item(2, ben, name: "Ben")])
        a.update([item(1, ada), item(2, ben, name: "Ben")])
        a.update([item(7, ada)])  // new track, same person
        #expect(speech.spoken == ["Ada — lunch Friday", "Ben — lunch Friday"])
        #expect(haptics.taps == 2)
    }

    @Test func unknownAndUnstableAreSilent() {
        let a = make()
        a.update([item(1, nil), item(2, ada, state: .appearing), item(3, ada, state: .lost)])
        #expect(speech.spoken.isEmpty && haptics.taps == 0)
    }

    @Test func chipCanBeDisabled() {
        let a = make(chip: false)
        a.update([item(1, ada)])
        #expect(speech.spoken == ["Ada"])
    }

    @Test func speakerThenHeadphonesAnnouncesLater() {
        let route = WhisperTestMutableRoute()
        let a = WhisperAnnouncer(
            settings: WhisperSettings(isEnabled: true), route: route, speech: speech, haptics: haptics)
        a.update([item(1, ada)])
        #expect(speech.spoken.isEmpty)
        route.isPrivateRoute = true
        a.update([item(1, ada)])
        #expect(speech.spoken.count == 1)
        #expect(haptics.taps == 1)
    }

    @Test func newSessionAnnouncesAgain() {
        let a = make()
        a.update([item(1, ada)])
        a.resetSession()
        a.update([item(1, ada)])
        #expect(speech.spoken.count == 2)
    }
}

import Foundation
import HaloCore
import HaloUI

/// Whisper-mode settings. Off by default.
public struct WhisperSettings: Equatable, Sendable {
    public var isEnabled: Bool
    /// Also speak the person's top chip ("Name — chip").
    public var speaksChip: Bool

    public init(isEnabled: Bool = false, speaksChip: Bool = true) {
        self.isEnabled = isEnabled
        self.speaksChip = speaksChip
    }
}

/// Whether audio currently goes to a private route (headphones). Never true for the speaker.
public protocol AudioRouteChecking: Sendable {
    var isPrivateRoute: Bool { get }
}

@MainActor public protocol WhisperSpeaking: AnyObject {
    func speak(_ text: String)
    func stop()
}

@MainActor public protocol WhisperHaptics: AnyObject {
    func tap()
}

/// Discreetly announces known people through headphones.
///
/// Invariants: never speaks unless the route is private (headphones, AirPods, wired); never
/// speaks for a track without a confirmed-person label (unknown faces); speaks once per person per
/// lens session.
@MainActor
public final class WhisperAnnouncer {
    public var settings: WhisperSettings
    private let route: any AudioRouteChecking
    private let speech: any WhisperSpeaking
    private let haptics: any WhisperHaptics
    private var spoken: Set<PersonID> = []
    private var tapped: Set<PersonID> = []

    public init(
        settings: WhisperSettings = WhisperSettings(), route: any AudioRouteChecking,
        speech: any WhisperSpeaking, haptics: any WhisperHaptics
    ) {
        self.settings = settings
        self.route = route
        self.speech = speech
        self.haptics = haptics
    }

    /// Call with every lens overlay update.
    public func update(_ items: [LensOverlayItem]) {
        guard settings.isEnabled else { return }
        for item in items where item.state == .stable {
            guard let label = item.label else { continue }  // unknown / ambiguous: silent
            let person = label.personID
            if tapped.insert(person).inserted { haptics.tap() }
            // Not marked as spoken while on the speaker, so it can be whispered once headphones connect.
            guard !spoken.contains(person), route.isPrivateRoute else { continue }
            let name = label.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            spoken.insert(person)
            var text = name
            if settings.speaksChip, let chip = label.chips.max(by: { $0.priority < $1.priority }) {
                text += " — \(chip.text)"
            }
            speech.speak(text)
        }
    }

    /// Start of a new lens session: everyone may be announced again.
    public func resetSession() {
        spoken.removeAll()
        tapped.removeAll()
        speech.stop()
    }
}

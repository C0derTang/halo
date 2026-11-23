import Foundation

extension AudioOutput.Kind {
    // `AVAudioSession.Port` raw values (asserted against the SDK in `SystemAudioRouteChecker.init`).
    static let headphonesPort = "Headphones"
    static let bluetoothA2DPPort = "BluetoothA2DPOutput"
    static let bluetoothHFPPort = "BluetoothHFP"
    static let bluetoothLEPort = "BluetoothLE"

    /// Pure mapping from an `AVAudioSession.Port` raw value. Anything unknown is `.other`.
    public init(portType: String) {
        switch portType {
        case Self.headphonesPort: self = .wiredHeadphones
        case Self.bluetoothA2DPPort, Self.bluetoothHFPPort, Self.bluetoothLEPort: self = .bluetooth
        default: self = .other
        }
    }
}

/// Tracks the single in-flight utterance. Events for any other (stale) utterance are ignored, and a
/// watchdog ends an utterance that never reports back so it can't stall the queue.
@MainActor
public final class WhisperUtteranceGate {
    private let timeout: Duration
    private var nextID = 0
    private var currentID: Int?
    private var completion: (@MainActor (WhisperSpeechResult) -> Void)?
    private var watchdog: Task<Void, Never>?
    /// Called when the watchdog fires, so the owner can stop the synthesizer.
    public var onTimeout: (@MainActor () -> Void)?

    public init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    /// Registers the new current utterance (replacing any previous one) and returns its id.
    public func begin(_ completion: @escaping @MainActor (WhisperSpeechResult) -> Void) -> Int {
        watchdog?.cancel()
        nextID += 1
        let id = nextID
        currentID = id
        self.completion = completion
        watchdog = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.currentID == id else { return }
            self.onTimeout?()
            self.end(id, .interrupted)
        }
        return id
    }

    /// An utterance ended. Ignored unless `id` is the current utterance.
    public func end(_ id: Int, _ result: WhisperSpeechResult) {
        guard id == currentID else { return }
        let done = completion
        cancel()
        done?(result)
    }

    /// Drops the current utterance without calling its completion.
    public func cancel() {
        watchdog?.cancel()
        watchdog = nil
        currentID = nil
        completion = nil
    }
}

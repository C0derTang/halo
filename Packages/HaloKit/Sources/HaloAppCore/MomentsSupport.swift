import AVFoundation
import Foundation
import HaloCore
import HaloMemory
import HaloUI
import Speech

/// Bridges the HaloMemory hook policy to Moments, which allow longer text than a generated hook.
public enum MomentsPolicy {
    /// Collapses whitespace; rejects sensitive topics, links, emails, domains and phone numbers.
    /// `MemoryHookPolicy.sanitize` caps text at its hook length, so the note is checked in
    /// overlapping word windows no longer than that cap: any link or number token fits in one.
    public static let sanitize: MomentsSanitizer = { raw in
        let words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        for start in words.indices {
            var window: [String] = []
            var length = 0
            for word in words[start...] {
                let added = length + word.count + (window.isEmpty ? 0 : 1)
                if added > MemoryHookPolicy.maxLength { break }
                window.append(word)
                length = added
            }
            // A single word over the cap leaves an empty window: reject (probably a link or junk).
            guard !window.isEmpty, !MemoryHookPolicy.sanitize([window.joined(separator: " ")]).isEmpty
            else { return nil }
        }
        return words.joined(separator: " ")
    }
}

/// Dictation with `SFSpeechRecognizer`, ON DEVICE ONLY: `requiresOnDeviceRecognition = true`, and
/// reported unavailable when the recognizer does not support on-device recognition.
public final class OnDeviceSpeechTranscriber: SpeechTranscribing {
    private let localeIdentifier: String

    public init(locale: Locale = .current) { localeIdentifier = locale.identifier }

    public var isOnDeviceAvailable: Bool {
        get async {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
            else { return false }
            return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
        }
    }

    public func transcribe() -> AsyncThrowingStream<String, Error> {
        let identifier = localeIdentifier
        return AsyncThrowingStream { continuation in
            let session = DictationSession(localeIdentifier: identifier, continuation: continuation)
            continuation.onTermination = { _ in session.stop() }
            Task { await session.start() }
        }
    }
}

private enum DictationError: Error { case notPermitted, unsupported }

/// Owns the audio engine and recognition task for one dictation. All mutable state is guarded by
/// `lock`; the Speech/AVFoundation objects are not Sendable.
private final class DictationSession: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let localeIdentifier: String
    private var engine: AVAudioEngine?
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var stopped = false

    init(localeIdentifier: String, continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.localeIdentifier = localeIdentifier
        self.continuation = continuation
    }

    func start() async {
        let speechStatus = await withCheckedContinuation {
            (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard speechStatus == .authorized, micGranted else { return fail(DictationError.notPermitted) }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
            recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
        else { return fail(DictationError.unsupported) }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true  // never leaves the device
        request.shouldReportPartialResults = true
        let engine = AVAudioEngine()
        do {
            #if os(iOS)
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
                try audio.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) {
                buffer, _ in request.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            return fail(error)
        }
        let task = recognizer.recognitionTask(with: request) { [continuation] result, error in
            if let result {
                continuation.yield(result.bestTranscription.formattedString)
                if result.isFinal { continuation.finish() }
            } else if let error {
                continuation.finish(throwing: error)
            }
        }
        if !install(engine: engine, task: task, request: request) {
            task.cancel()
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    /// Returns false when `stop()` already ran, in which case the caller tears everything down.
    private func install(
        engine: AVAudioEngine, task: SFSpeechRecognitionTask,
        request: SFSpeechAudioBufferRecognitionRequest
    ) -> Bool {
        lock.withLock {
            if stopped { return false }
            self.engine = engine
            self.task = task
            self.request = request
            return true
        }
    }

    func stop() {
        let (engine, task, request) = lock.withLock {
            stopped = true
            let taken = (self.engine, self.task, self.request)
            self.engine = nil
            self.task = nil
            self.request = nil
            return taken
        }
        request?.endAudio()
        task?.cancel()
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func fail(_ error: Error) { continuation.finish(throwing: error) }
}

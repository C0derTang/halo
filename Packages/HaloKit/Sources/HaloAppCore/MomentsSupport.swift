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

#if os(iOS)
    private struct SavedSession {
        var category: AVAudioSession.Category
        var mode: AVAudioSession.Mode
        var options: AVAudioSession.CategoryOptions
    }
#else
    private struct SavedSession {}
#endif

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
    private var previous: SavedSession?

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
                saveSession(
                    SavedSession(category: audio.category, mode: audio.mode, options: audio.categoryOptions))
                try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
                try audio.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) {
                buffer, _ in request.append(buffer)
            }
            // Visible to stop() from here on, so any failure or stop tears the tap down.
            if !installEngine(engine, request) {
                return teardown(engine: engine, task: nil, request: request)
            }
            engine.prepare()
            try engine.start()
        } catch {
            stop()
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
        if !installTask(task) { task.cancel() }
    }

    /// Returns false when `stop()` already ran; the caller then tears down what it created.
    private func installEngine(_ engine: AVAudioEngine, _ request: SFSpeechAudioBufferRecognitionRequest)
        -> Bool
    {
        lock.withLock {
            if stopped { return false }
            self.engine = engine
            self.request = request
            return true
        }
    }

    private func installTask(_ task: SFSpeechRecognitionTask) -> Bool {
        lock.withLock {
            if stopped { return false }
            self.task = task
            return true
        }
    }

    private func saveSession(_ saved: SavedSession) { lock.withLock { previous = saved } }

    /// Idempotent: tears down tap, engine, recognition and the audio session exactly once.
    func stop() {
        let taken = lock.withLock { () -> Taken? in
            if stopped && engine == nil && task == nil && request == nil && previous == nil { return nil }
            stopped = true
            let t = Taken(engine: engine, task: task, request: request, previous: previous)
            engine = nil
            task = nil
            request = nil
            previous = nil
            return t
        }
        guard let taken else { return }
        teardown(engine: taken.engine, task: taken.task, request: taken.request, previous: taken.previous)
    }

    private struct Taken {
        var engine: AVAudioEngine?
        var task: SFSpeechRecognitionTask?
        var request: SFSpeechAudioBufferRecognitionRequest?
        var previous: SavedSession?
    }

    private func teardown(
        engine: AVAudioEngine?, task: SFSpeechRecognitionTask?,
        request: SFSpeechAudioBufferRecognitionRequest?, previous: SavedSession? = nil
    ) {
        request?.endAudio()
        task?.cancel()
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        #if os(iOS)
            let audio = AVAudioSession.sharedInstance()
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            if let previous {
                try? audio.setCategory(previous.category, mode: previous.mode, options: previous.options)
            }
        #endif
    }

    private func fail(_ error: Error) { continuation.finish(throwing: error) }
}

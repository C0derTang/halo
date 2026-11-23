import Foundation

/// Rolling performance numbers for the lens debug overlay. Metadata only (no face data).
public struct LensMetrics: Sendable, Equatable {
    public enum Stage: String, Sendable, CaseIterable {
        case detect, track, embed, match, total
    }

    /// Frames over which fps is measured.
    public static let fpsWindow = 30
    /// Weight of the newest sample in the latency moving average.
    public static let latencySmoothing = 0.1

    /// Processed frames per second over the last `fpsWindow` processed frames (frame time).
    public private(set) var fps: Double = 0
    /// Exponential moving average of each stage's wall-clock latency, in milliseconds.
    public private(set) var latencyMilliseconds: [Stage: Double] = [:]
    public private(set) var processedFrames = 0
    /// Frames dropped because a previous frame was still being processed.
    public internal(set) var droppedFrames = 0
    public private(set) var embedsLastFrame = 0
    public private(set) var totalEmbeds = 0
    public private(set) var detectorErrors = 0
    public private(set) var embedderErrors = 0

    private var timestamps: [TimeInterval] = []

    public init() {}

    mutating func recordProcessed(timestamp: TimeInterval, embeds: Int) {
        processedFrames += 1
        embedsLastFrame = embeds
        totalEmbeds += embeds
        if let last = timestamps.last, timestamp < last { timestamps.removeAll() }
        timestamps.append(timestamp)
        if timestamps.count > Self.fpsWindow { timestamps.removeFirst(timestamps.count - Self.fpsWindow) }
        if let first = timestamps.first, let last = timestamps.last, last > first {
            fps = Double(timestamps.count - 1) / (last - first)
        } else {
            fps = 0
        }
    }

    mutating func recordLatency(_ stage: Stage, _ duration: Duration) {
        let ms =
            Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        if let old = latencyMilliseconds[stage] {
            latencyMilliseconds[stage] = old + Self.latencySmoothing * (ms - old)
        } else {
            latencyMilliseconds[stage] = ms
        }
    }

    mutating func recordDetectorError() { detectorErrors += 1 }
    mutating func recordEmbedderError() { embedderErrors += 1 }
}

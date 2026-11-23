import Foundation

/// One Euro filter (Casiez et al. 2012): adaptive low-pass that smooths jitter at low speed and
/// reduces lag at high speed. Timestamp-driven, so safe for variable frame rates.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double

    private var lastTime: TimeInterval?
    private var lastRaw: Double = 0
    private var lastFiltered: Double = 0
    private var lastDerivative: Double = 0

    public init(minCutoff: Double = 1.0, beta: Double = 0.5, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    public mutating func reset() { lastTime = nil }

    /// Filter `value` observed at `timestamp`. Non-increasing timestamps return the last output.
    public mutating func filter(_ value: Double, timestamp: TimeInterval) -> Double {
        guard let t0 = lastTime else {
            lastTime = timestamp
            lastRaw = value
            lastFiltered = value
            lastDerivative = 0
            return value
        }
        let dt = timestamp - t0
        guard dt > 0 else { return lastFiltered }

        let derivative = (value - lastRaw) / dt
        let aD = Self.alpha(cutoff: dCutoff, dt: dt)
        let dHat = aD * derivative + (1 - aD) * lastDerivative
        let cutoff = minCutoff + beta * abs(dHat)
        let a = Self.alpha(cutoff: cutoff, dt: dt)
        let out = a * value + (1 - a) * lastFiltered

        lastTime = timestamp
        lastRaw = value
        lastFiltered = out
        lastDerivative = dHat
        return out
    }

    static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * max(cutoff, 1e-6))
        return 1.0 / (1.0 + tau / dt)
    }
}

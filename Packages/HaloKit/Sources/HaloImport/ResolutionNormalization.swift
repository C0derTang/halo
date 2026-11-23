import Foundation
import HaloBridgeKit

/// Thin app-side wrapper over HaloBridgeKit's `HandleNormalizer`, so the bridge and the app
/// normalize handles identically. Adds validity checks (is it a phone? an email?).
public struct HandleNormalization: Sendable {
    public var normalizer: HandleNormalizer

    public init(normalizer: HandleNormalizer) { self.normalizer = normalizer }

    /// Region defaults to the device locale (falls back to US).
    public init(region: String? = Locale.current.region?.identifier) {
        self.init(normalizer: HandleNormalizer(region: region ?? "US"))
    }

    /// E.164 phone, or nil when the input is not phone-like.
    public func e164(_ raw: String) -> String? {
        let n = normalizer.normalize(raw)
        guard n.hasPrefix("+"), n.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        guard (7...15).contains(n.count - 1), n.dropFirst().first != "0" else { return nil }
        return n
    }

    public func email(_ raw: String) -> String? {
        let v = normalizer.normalize(raw)
        guard let at = v.firstIndex(of: "@"), at != v.startIndex, v.index(after: at) != v.endIndex
        else { return nil }
        return v
    }
}

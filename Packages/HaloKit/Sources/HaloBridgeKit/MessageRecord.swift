import Foundation

/// One message reduced to metadata. There is deliberately no text field (invariant 6).
public struct MessageRecord: Hashable, Sendable {
    public var handle: String
    public var isFromMe: Bool
    public var date: Date

    public init(handle: String, isFromMe: Bool, date: Date) {
        self.handle = handle
        self.isFromMe = isFromMe
        self.date = date
    }
}

public enum AppleDate {
    /// Seconds between the Unix epoch and the Apple epoch (2001-01-01).
    static let appleEpochOffset: TimeInterval = 978_307_200

    /// chat.db stores seconds since 2001-01-01 on old macOS and nanoseconds on modern macOS.
    /// Second values stay below 1e11 for thousands of years; nanosecond values are above it
    /// after the first ~100 seconds past 2001.
    public static func convert(_ raw: Int64) -> Date {
        let seconds = abs(raw) >= 100_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSince1970: appleEpochOffset + seconds)
    }
}

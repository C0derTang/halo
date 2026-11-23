import Foundation

/// Handle normalization. Mirrors the bridge's rules; to be deduped with HaloBridgeKit later.
public enum HandleNormalization {
    /// Best-effort E.164. 10 digits assume NANP (+1). Returns nil when it can't be a phone number.
    public static func e164(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var digits = trimmed.filter { $0.isASCII && $0.isNumber }
        if !trimmed.hasPrefix("+") {
            if digits.hasPrefix("00") {
                digits.removeFirst(2)
            } else if digits.count == 10 {
                digits = "1" + digits
            }
        }
        guard (7...15).contains(digits.count), digits.first != "0" else { return nil }
        return "+" + digits
    }

    public static func email(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = v.firstIndex(of: "@"), at != v.startIndex, v.index(after: at) != v.endIndex
        else { return nil }
        return v
    }
}

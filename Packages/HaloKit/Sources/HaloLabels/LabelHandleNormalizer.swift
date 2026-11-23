import Foundation

/// Local handle normalizer. HaloLabels depends only on HaloCore, so this MUST stay behaviorally
/// identical to `HandleNormalization` (HaloImport) and the bridge's `HandleNormalizer`
/// (HaloBridgeKit); `normalizerSharedExpectations` in the tests pins the shared expectations.
enum LabelHandleNormalizer {
    /// Best-effort E.164. 10 digits assume NANP (+1). nil when it can't be a phone number.
    static func e164(_ raw: String) -> String? {
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

    static func email(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = v.firstIndex(of: "@"), at != v.startIndex, v.index(after: at) != v.endIndex
        else { return nil }
        return v
    }

    /// Canonical key for any phone/email/iMessage handle; nil when unusable.
    static func key(_ raw: String) -> String? {
        raw.contains("@") ? email(raw) : e164(raw)
    }
}

import Foundation

/// Normalizes chat.db / Contacts handles so the bridge and the app agree on identity values.
/// Emails are lowercased; phone numbers become E.164 on a best-effort basis.
public struct HandleNormalizer: Sendable {
    /// Calling code (no "+") applied to numbers without an international prefix. Default US = "1".
    public var defaultCountryCode: String

    public init(defaultCountryCode: String = "1") {
        self.defaultCountryCode = defaultCountryCode
    }

    /// Convenience for a few common ISO regions; unknown regions fall back to US.
    public init(region: String) {
        let codes = [
            "US": "1", "CA": "1", "GB": "44", "AU": "61", "DE": "49", "FR": "33", "IN": "91",
            "JP": "81", "CN": "86", "MX": "52", "BR": "55", "ES": "34", "IT": "39", "NL": "31",
        ]
        self.init(defaultCountryCode: codes[region.uppercased()] ?? "1")
    }

    public func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") { return trimmed.lowercased() }

        let hasPlus = trimmed.hasPrefix("+")
        let digits = trimmed.filter { $0.isASCII && $0.isNumber }
        // Not phone-like (short codes, business ids, empty): keep as-is, lowercased.
        let hasLetters = trimmed.contains { $0.isLetter }
        guard !hasLetters, digits.count >= 7 else { return trimmed.lowercased() }

        if hasPlus { return "+" + digits }
        if digits.hasPrefix("00") { return "+" + digits.dropFirst(2) }

        if defaultCountryCode == "1" {
            if digits.count == 10 { return "+1" + digits }
            if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
            return "+" + digits  // unknown shape; best effort
        }
        if digits.hasPrefix(defaultCountryCode), digits.count > 10 { return "+" + digits }
        let national = digits.hasPrefix("0") ? String(digits.dropFirst()) : digits
        return "+" + defaultCountryCode + national
    }
}

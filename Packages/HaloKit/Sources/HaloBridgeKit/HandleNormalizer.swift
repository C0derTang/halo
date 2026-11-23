import Foundation

/// Normalizes chat.db / Contacts handles so the bridge and the app agree on identity values.
/// Emails are lowercased; phone numbers become E.164 on a best-effort basis.
///
/// Numbers already in international form (`+…` or `00…`) always normalize to E.164. National
/// numbers get the default calling code only when one is known: for a region outside the
/// built-in table they are left as bare digits (no "+"), never guessed as +1, because a wrong
/// calling code can make a handle collide with a different person's number.
public struct HandleNormalizer: Sendable {
    /// Calling code (no "+") applied to numbers without an international prefix. Default US = "1".
    /// Empty when the normalizer was made for an unknown region (see `isKnownRegion`).
    public var defaultCountryCode: String

    /// False when built for a region outside the built-in table: national-format numbers are
    /// then left unnormalized (digits only).
    public var isKnownRegion: Bool { !defaultCountryCode.isEmpty }

    public init(defaultCountryCode: String = "1") {
        self.defaultCountryCode = defaultCountryCode
    }

    /// ISO 3166-1 alpha-2 region -> E.164 calling code (no "+"). The supported set is deliberately
    /// small and fixed: add a region only with its code verified, because a wrong code can make a
    /// handle collide with another person's number (invariant 4). Anything not listed, including
    /// "ZZ" (unknown region), is unknown: national-format numbers stay unnormalized.
    /// Shared calling codes (US and CA are both "1") are intentional.
    static let callingCodes = [
        "US": "1", "CA": "1", "GB": "44", "AU": "61", "DE": "49", "FR": "33", "IN": "91",
        "JP": "81", "CN": "86", "MX": "52", "BR": "55", "ES": "34", "IT": "39", "NL": "31",
    ]

    /// Convenience for a few common ISO regions (case-insensitive). For any other region,
    /// national-format numbers are left unnormalized; see `isKnownRegion(_:)`.
    public init(region: String) {
        self.init(defaultCountryCode: Self.callingCodes[region.uppercased()] ?? "")
    }

    /// Whether `init(region:)` knows `region`'s calling code.
    public static func isKnownRegion(_ region: String) -> Bool {
        callingCodes[region.uppercased()] != nil
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

        // Unknown region: there is no safe calling code to assume.
        guard isKnownRegion else { return digits }

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

import Foundation
import HaloCore

/// Single source of truth for what an on-device summary hook may look like.
///
/// Every generated hook passes through `sanitize(_:)` before it is stored, whatever produced it:
/// `FoundationModelsHookGenerator` applies it, and `MemoryHookRefresher` applies it again.
public enum MemoryHookPolicy {
    /// At most this many `.onDeviceSummary` hooks per person.
    public static let maxHooks = 3
    /// Hook text limit in characters (the chip has room for about this much).
    public static let maxLength = 40
    /// Generated hooks go stale after 30 days.
    public static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    /// When a hook generated at `now` stops being shown.
    public static func expiry(from now: Date) -> Date { now.addingTimeInterval(lifetime) }

    /// Trims, drops empty / over-long / sensitive / duplicate texts, and keeps the first
    /// `maxHooks`. Over-long texts are dropped rather than truncated so a hook never ends mid-word.
    public static func sanitize(_ texts: [String]) -> [String] {
        var seen: Set<String> = []
        var kept: [String] = []
        for raw in texts {
            let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty, text.count <= maxLength else { continue }
            guard !SensitiveTopicFilter.isSensitive(text) else { continue }
            guard seen.insert(text.lowercased()).inserted else { continue }
            kept.append(text)
            if kept.count == maxHooks { break }
        }
        return kept
    }

    /// Builds the stored hooks for `person` from generated texts, enforcing the policy: sanitized
    /// text, `.onDeviceSummary` source, created `now`, expiring after `lifetime`.
    public static func makeHooks(for person: PersonID, texts: [String], now: Date) -> [MemoryHook] {
        sanitize(texts).map {
            MemoryHook(
                personID: person, text: $0, source: .onDeviceSummary, createdAt: now,
                expiresAt: expiry(from: now))
        }
    }
}

/// Post-filter for generated hooks: rejects anything touching health, religion, sexuality or
/// money. The model is instructed to avoid these too; this list is the backstop. It errs on the side
/// of dropping a hook: a missing hook is harmless, a sensitive one floating over someone's head is not.
public enum SensitiveTopicFilter {
    /// Matched against the START of each word ("hospital" catches "hospitalized"), except the
    /// entries in `exactOnly`.
    static let stems: [String] = [
        // Health
        "sick", "ill", "illness", "hospital", "doctor", "clinic", "diagnos", "cancer", "tumor", "chemo",
        "therap", "medic", "surgery", "surgeon", "pregnan", "miscarr", "depress", "anxiety", "anxious",
        "disease", "disorder", "covid", "virus", "infection", "rehab", "mental", "diabet", "injur",
        "symptom", "prescription", "psychiatr", "addict", "overdose", "allerg", "disab", "dementia",
        "alzheimer", "adhd", "autis", "fertil", "ivf", "abortion", "std", "hiv", "aids", "funeral",
        // Religion
        "relig", "church", "mosque", "synagogue", "pray", "bible", "quran", "koran", "torah",
        "christian", "catholic", "protestant", "muslim", "islam", "jewish", "judaism", "hindu",
        "buddhis", "sikh", "atheis", "god", "faith", "baptis", "mormon", "ramadan", "passover",
        "sermon", "worship",
        // Sexuality
        "sex", "sexy", "sexual", "gay", "lesbian", "bisexual", "queer", "lgbt", "transgender",
        "nonbinary", "homosex", "heterosex", "asexual", "hookup", "tinder", "grindr", "porn",
        // Finances
        "debt", "loan", "mortgage", "salary", "salaries", "wage", "bankrupt", "money", "broke",
        "paycheck", "income", "credit", "owe", "owes", "owed", "owing", "investm", "investing",
        "investor", "stock", "crypto", "bitcoin", "rent", "rented", "renting", "finance", "financial",
        "tax", "taxes", "afford", "savings", "inheritance", "payment", "bills", "unemploy", "laid",
        "layoff", "fired", "welfare",
    ]

    /// Stems short or common enough that prefix matching would misfire ("ill" vs "illustrator",
    /// "god" vs "godzilla", "owe" vs "owen", "sex" vs "sextet", "tax" vs "taxi").
    static let exactOnly: Set<String> = [
        "ill", "god", "owe", "owes", "owed", "std", "aids", "laid", "broke", "sex", "gay", "rent",
        "stock", "bills", "tax", "ivf", "hiv", "sikh", "wage",
    ]

    /// Characters that on their own mark a money detail.
    static let currencySymbols: Set<Character> = ["$", "€", "£", "¥", "₹", "₩", "₽", "₿"]

    public static func isSensitive(_ text: String) -> Bool {
        if text.contains(where: { currencySymbols.contains($0) }) { return true }
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        for word in words {
            for stem in stems {
                if exactOnly.contains(stem) {
                    if word == stem || word == stem + "s" { return true }
                } else if word.hasPrefix(stem) {
                    return true
                }
            }
        }
        return false
    }
}

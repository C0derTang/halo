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
            guard !SensitiveTopicFilter.isSensitive(text), !containsContactOrLink(text) else { continue }
            guard seen.insert(text.lowercased()).inserted else { continue }
            kept.append(text)
            if kept.count == maxHooks { break }
        }
        return kept
    }

    /// True for anything that looks like a URL, email, domain or phone number. Hooks are about the
    /// person, never a way to reach a site or a number (this also blunts prompt-injected links).
    static func containsContactOrLink(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("://") || lowered.contains("www.") || lowered.contains("@") { return true }
        let patterns = [
            // Five or more digits, optionally separated by single spaces, dots, dashes or parens.
            #"\d(?:[\s().-]?\d){4,}"#
        ]
        if containsDomainLikeToken(lowered) { return true }
        return patterns.contains { lowered.range(of: $0, options: .regularExpression) != nil }
    }

    /// Suffixes of dotted tokens that are language / framework / file names, not sites ("Node.js").
    /// Everything else after a dot ("acme.com", "acme.pro", "bob.xxx") is treated as a link.
    static let exemptSuffixes: Set<String> = [
        "js", "jsx", "ts", "tsx", "py", "rb", "rs", "go", "kt", "sh", "md", "cs", "swift", "java", "php",
        "cpp", "hs", "ex", "exs", "lua", "json", "yml", "yaml", "toml", "html", "css", "txt", "pdf",
        "png", "jpg", "gif", "csv",
    ]

    /// True for any `word.suffix` token whose suffix is not in `exemptSuffixes`. Scanning resumes at
    /// the START of each suffix, so chained tokens ("x.js.com", "blog.joe.com") are all examined.
    static func containsDomainLikeToken(_ lowered: String) -> Bool {
        var rest = lowered[...]
        while let range = rest.range(of: #"[a-z0-9-]+\.[a-z]{2,}\b"#, options: .regularExpression) {
            let token = rest[range]
            guard let dot = token.lastIndex(of: ".") else { return true }
            let suffixStart = token.index(after: dot)
            if !exemptSuffixes.contains(String(token[suffixStart...])) { return true }
            rest = rest[suffixStart...]
        }
        return false
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
        "meds", "drug", "died", "death", "sober", "flu",
        // Religion
        "relig", "church", "mosque", "synagogue", "pray", "bible", "quran", "koran", "torah",
        "christian", "catholic", "protestant", "muslim", "islam", "jewish", "judaism", "hindu",
        "buddhis", "sikh", "atheis", "god", "faith", "baptis", "mormon", "ramadan", "passover",
        "sermon", "worship", "jesus", "temple", "pastor", "priest", "rabbi", "imam", "spiritu",
        // Sexuality
        "sex", "sexy", "sexual", "gay", "lesbian", "bisexual", "queer", "lgbt", "transgender",
        "nonbinary", "homosex", "heterosex", "asexual", "hookup", "tinder", "grindr", "porn", "trans",
        "dating", "boyfriend", "girlfriend", "divorc",
        // Finances
        "debt", "loan", "mortgage", "salary", "salaries", "wage", "bankrupt", "money", "broke",
        "paycheck", "income", "credit", "owe", "owes", "owed", "owing", "investm", "investing",
        "investor", "stock", "crypto", "bitcoin", "rent", "rented", "renting", "finance", "financial",
        "tax", "taxes", "afford", "savings", "inheritance", "payment", "bills", "unemploy", "laid",
        "layoff", "fired", "welfare", "dollar", "bank", "cash", "bonus",
    ]

    /// Stems short or common enough that prefix matching would misfire ("ill" vs "illustrator",
    /// "god" vs "godzilla", "owe" vs "owen", "sex" vs "sextet", "tax" vs "taxi").
    static let exactOnly: Set<String> = [
        "ill", "god", "owe", "owes", "owed", "std", "aids", "laid", "broke", "sex", "gay", "rent",
        "stock", "bills", "tax", "ivf", "hiv", "sikh", "wage", "trans", "meds", "died", "flu", "imam",
        "cash", "rabbi",
    ]

    /// Money amounts like "50k", "2.5m", "3bn".
    static let amountPattern = #"\b(\d+(?:[.,]\d+)?)\s?(k|m|bn|mil)\b"#

    /// Race distances ("a 5k", "the 10k") that are not money when written with an article.
    static let raceDistancesK: Set<String> = ["5", "10", "15", "21", "42"]

    /// A word right after "5k" that makes it money again ("a 5k raise").
    static let moneyWords: Set<String> = [
        "raise", "bonus", "salary", "loan", "fee", "fine", "bill", "tip", "rent", "debt", "price",
        "pay", "payment", "income", "mortgage", "budget", "cost", "fees", "bills", "tips",
    ]

    /// True when the text contains a money-looking amount. A "k" amount is NOT money when it is
    /// followed by "run"/"race" ("5k run"), or is a standard race distance preceded by "a"/"the"
    /// ("ran a 10k"). Deliberately narrower than "any k after a/the": "got a 50k raise" stays sensitive.
    static func containsMoneyAmount(_ lowered: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: amountPattern) else { return true }
        let ns = lowered as NSString
        for match in regex.matches(in: lowered, range: NSRange(location: 0, length: ns.length)) {
            let number = ns.substring(with: match.range(at: 1))
            let unit = ns.substring(with: match.range(at: 2))
            guard unit == "k" else { return true }
            let after = lowered[Range(match.range, in: lowered)!.upperBound...]
                .split(whereSeparator: { !$0.isLetter }).first.map(String.init)
            guard raceDistancesK.contains(number) else { return true }
            if let after, moneyWords.contains(after) { return true }
            if after == "run" || after == "runs" || after == "race" || after == "races" { continue }
            let before = lowered[..<Range(match.range, in: lowered)!.lowerBound]
                .split(whereSeparator: { !$0.isLetter }).last.map(String.init)
            if before == "a" || before == "the" { continue }
            return true
        }
        return false
    }

    /// Characters that on their own mark a money detail.
    static let currencySymbols: Set<Character> = ["$", "€", "£", "¥", "₹", "₩", "₽", "₿"]

    public static func isSensitive(_ text: String) -> Bool {
        if text.contains(where: { currencySymbols.contains($0) }) { return true }
        let lowered = text.lowercased()
        if containsMoneyAmount(lowered) { return true }
        // Match both the hyphen-joined form ("non-binary" -> "nonbinary") and each part
        // ("ex-boyfriend" -> "boyfriend").
        let split: (String) -> [String] = {
            $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let joined = lowered.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "\u{2010}", with: "")
        let parts = split(lowered)
        // Space-separated compounds ("non binary") are matched as exact whole stems only, so
        // prefix stems cannot fire across a word boundary ("the rapids" is not "therap...").
        let stemSet = Set(stems)
        // Single-letter words are never joined ("a ids" is not "aids").
        for (a, b) in zip(parts, parts.dropFirst())
        where a.count > 1 && b.count > 1 && stemSet.contains(a + b) { return true }
        let words = Set(parts + split(joined))
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

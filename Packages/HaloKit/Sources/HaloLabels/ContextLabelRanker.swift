import Foundation
import HaloBridgeKit
import HaloCore

/// Turns a person + identities + iMessage digest into the `LabelData` the hologram renders.
///
/// Invariant: a digest entry contributes only when its handle, after normalization, exactly equals
/// a handle among THIS person's phone/email/imessage identities. Identities belonging to another
/// person are ignored, and a handle claimed by identities of two different people is dropped.
/// Chip text is built only from digest metadata (dates, flags); never from message content.
public struct ContextLabelRanker: LabelRanking {
    public static let upcomingWindowDays = 14
    public static let memoryHookMaxLength = 40
    public static let staleAfterDays = 365

    private let calendar: Calendar
    private let locale: Locale
    private let normalizer: HandleNormalizer

    /// - Parameters:
    ///   - calendar: callers inject the Calendar (including its time zone) for deterministic output.
    ///   - normalizer: MUST be the same normalizer (same region) the importer used to store
    ///     identities, otherwise local-format numbers will not match across sides.
    public init(
        calendar: Calendar = Calendar(identifier: .gregorian),
        locale: Locale = Locale(identifier: "en_US_POSIX"),
        normalizer: HandleNormalizer = HandleNormalizer(
            region: Locale.current.region?.identifier ?? "US")
    ) {
        self.normalizer = normalizer
        var cal = calendar
        cal.locale = locale
        self.calendar = cal
        self.locale = locale
    }

    public func label(for person: Person, identities: [Identity], digest: InteractionDigest?, now: Date)
        -> LabelData
    {
        var chips: [LabelChip] = []
        if let chip = birthdayChip(person.birthday, now: now) { chips.append(chip) }
        if let digest {
            let entries = matchingEntries(person: person, identities: identities, digest: digest)
            if let chip = openLoopChip(entries, now: now) { chips.append(chip) }
            if let chip = lastInteractionChip(entries, now: now) { chips.append(chip) }
        }
        if let chip = memoryHookChip(person.notes) { chips.append(chip) }

        chips.sort {
            $0.priority != $1.priority ? $0.priority > $1.priority : $0.kind.rawValue < $1.kind.rawValue
        }
        return LabelData(
            personID: person.id, title: person.displayName, subtitle: person.relationship, chips: chips)
    }

    // MARK: Attribution

    /// `identities` must include other people's identities too (e.g. the store-wide set) for the
    /// ambiguity guard to work; identities of other people are used only to drop shared handles.
    func matchingEntries(person: Person, identities: [Identity], digest: InteractionDigest)
        -> [InteractionDigest.Entry]
    {
        let handleKinds: Set<Identity.Kind> = [.phone, .email, .imessageHandle]
        var mine: Set<String> = []
        var others: Set<String> = []
        for identity in identities where handleKinds.contains(identity.kind) {
            let key = normalizer.normalize(identity.value)
            guard !key.isEmpty else { continue }
            if identity.personID == person.id { mine.insert(key) } else { others.insert(key) }
        }
        let owned = mine.subtracting(others)  // ambiguous handles contribute nothing
        return digest.entries.filter { entry in
            let key = normalizer.normalize(entry.handle)
            return !key.isEmpty && owned.contains(key)
        }
    }

    // MARK: Chips

    private func birthdayChip(_ birthday: DateComponents?, now: Date) -> LabelChip? {
        guard let month = birthday?.month, let day = birthday?.day else { return nil }
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: today)
        for candidateYear in [year, year + 1] {
            guard let date = occurrence(month: month, day: day, year: candidateYear), date >= today
            else { continue }
            let days = calendar.dateComponents([.day], from: today, to: date).day ?? Int.max
            guard days <= Self.upcomingWindowDays else { return nil }
            let text: String
            switch days {
            case 0: text = "Birthday today"
            case 1: text = "Birthday tomorrow"
            default: text = "Birthday in \(days) days"
            }
            let closeness = Double(Self.upcomingWindowDays - days) / Double(Self.upcomingWindowDays)
            return LabelChip(kind: .upcoming, text: text, priority: 0.7 + 0.3 * closeness)
        }
        return nil
    }

    /// Feb 29 birthdays are observed on Feb 28 in non-leap years.
    private func occurrence(month: Int, day: Int, year: Int) -> Date? {
        if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
            calendar.component(.month, from: date) == month,
            calendar.component(.day, from: date) == day
        {
            return date
        }
        if month == 2, day == 29 {
            return calendar.date(from: DateComponents(year: year, month: 2, day: 28))
        }
        return nil
    }

    private func openLoopChip(_ entries: [InteractionDigest.Entry], now: Date) -> LabelChip? {
        let since = entries.filter(\.awaitingMyReply)
            .compactMap { $0.lastFromThemAt ?? $0.lastMessageAt }.max()
        guard let since else { return nil }
        let days = daysBetween(since, now)
        return LabelChip(
            kind: .openLoop, text: "Waiting on your reply · \(compact(days: days))", priority: 0.8)
    }

    private func lastInteractionChip(_ entries: [InteractionDigest.Entry], now: Date) -> LabelChip? {
        guard let last = entries.compactMap(\.lastMessageAt).max() else { return nil }
        let days = daysBetween(last, now)
        if days == 0 { return LabelChip(kind: .lastInteraction, text: "Talked today", priority: 0.5) }
        if days < 30 {
            return LabelChip(kind: .lastInteraction, text: "Texted \(num(days))d ago", priority: 0.5)
        }
        let stale = days >= Self.staleAfterDays
        let text: String
        if !stale {
            text = "Last texted \(num(max(1, days / 30))) mo ago"
        } else {
            text = "Last texted \(num(max(1, days / 365))) y ago"
        }
        return LabelChip(kind: .lastInteraction, text: text, priority: stale ? 0.2 : 0.45)
    }

    private func memoryHookChip(_ notes: String?) -> LabelChip? {
        guard let notes else { return nil }
        let chars = Array(notes.trimmingCharacters(in: .whitespacesAndNewlines))
        var end = chars.count
        for (i, c) in chars.enumerated() {
            let isEnd = ".!?".contains(c) && (i + 1 == chars.count || chars[i + 1].isWhitespace)
            if c.isNewline || isEnd {
                end = i
                break
            }
        }
        var sentence = String(chars[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return nil }
        if sentence.count > Self.memoryHookMaxLength {
            let cut = String(sentence.prefix(Self.memoryHookMaxLength - 1))
            sentence = cut.trimmingCharacters(in: .whitespaces) + "…"
        }
        return LabelChip(kind: .memoryHook, text: sentence, priority: 0.4)
    }

    // MARK: Formatting

    /// Whole calendar days from `date` to `now`, clamped at 0 for future dates.
    private func daysBetween(_ date: Date, _ now: Date) -> Int {
        let a = calendar.startOfDay(for: date)
        let b = calendar.startOfDay(for: now)
        return max(0, calendar.dateComponents([.day], from: a, to: b).day ?? 0)
    }

    private func compact(days: Int) -> String {
        switch days {
        case 0: return "today"
        case 1..<14: return "\(num(days))d"
        case 14..<60: return "\(num(days / 7))w"
        case 60..<365: return "\(num(days / 30))mo"
        default: return "\(num(days / 365))y"
        }
    }

    private func num(_ n: Int) -> String { n.formatted(.number.locale(locale)) }
}

import Foundation
import HaloCore

/// Aggregates message metadata into per-handle `InteractionDigest` entries.
public struct DigestBuilder: Sendable {
    public var normalizer: HandleNormalizer

    public init(normalizer: HandleNormalizer = HandleNormalizer()) {
        self.normalizer = normalizer
    }

    /// The 30-day window is `[now - 30d, now]`, inclusive on both ends; messages dated after
    /// `now` count toward all-time only. Handles that normalize equally are merged.
    public func build(records: [MessageRecord], now: Date) -> InteractionDigest {
        let windowStart = now.addingTimeInterval(-30 * 24 * 60 * 60)

        struct Acc {
            var lastMe: Date?
            var lastThem: Date?
            var last30 = 0
            var all = 0
        }
        var byHandle: [String: Acc] = [:]
        for r in records {
            let key = normalizer.normalize(r.handle)
            var a = byHandle[key] ?? Acc()
            a.all += 1
            if r.date >= windowStart && r.date <= now { a.last30 += 1 }
            if r.isFromMe {
                if a.lastMe.map({ r.date > $0 }) ?? true { a.lastMe = r.date }
            } else {
                if a.lastThem.map({ r.date > $0 }) ?? true { a.lastThem = r.date }
            }
            byHandle[key] = a
        }

        let entries = byHandle.map { handle, a -> InteractionDigest.Entry in
            let last = [a.lastMe, a.lastThem].compactMap { $0 }.max()
            let awaiting = a.lastThem.map { them in a.lastMe.map { them > $0 } ?? true } ?? false
            return InteractionDigest.Entry(
                handle: handle, lastMessageAt: last, lastFromMeAt: a.lastMe,
                lastFromThemAt: a.lastThem, messagesLast30Days: a.last30,
                messagesAllTime: a.all, awaitingMyReply: awaiting)
        }.sorted { $0.handle < $1.handle }

        return InteractionDigest(generatedAt: now, entries: entries)
    }
}

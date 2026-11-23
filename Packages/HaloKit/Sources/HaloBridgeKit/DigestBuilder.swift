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
    ///
    /// `excerpts` is nil unless the user opted in to message text (`--with-messages`); then every
    /// entry gets `recentMessages`: excerpts in the same window, newest first, at most
    /// `MessageExcerptPolicy.maxPerHandle`, each at most `MessageExcerptPolicy.maxCharacters`.
    /// With nil, the output is metadata only (`recentMessages` stays nil).
    public func build(records: [MessageRecord], excerpts: [MessageExcerpt]? = nil, now: Date)
        -> InteractionDigest
    {
        let windowStart = now.addingTimeInterval(-MessageExcerptPolicy.window)

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

        let recent = excerpts.map { recentMessages($0, windowStart: windowStart, now: now) }

        let entries = byHandle.map { handle, a -> InteractionDigest.Entry in
            let last = [a.lastMe, a.lastThem].compactMap { $0 }.max()
            let awaiting = a.lastThem.map { them in a.lastMe.map { them > $0 } ?? true } ?? false
            return InteractionDigest.Entry(
                handle: handle, lastMessageAt: last, lastFromMeAt: a.lastMe,
                lastFromThemAt: a.lastThem, messagesLast30Days: a.last30,
                messagesAllTime: a.all, awaitingMyReply: awaiting,
                recentMessages: recent.map { $0[handle] ?? [] })
        }.sorted { $0.handle < $1.handle }

        return InteractionDigest(generatedAt: now, entries: entries)
    }

    /// Bounded excerpts per normalized handle. Input is in chat.db `ROWID` order; reversing before
    /// the stable date sort puts the later row first when two messages share a timestamp.
    func recentMessages(_ excerpts: [MessageExcerpt], windowStart: Date, now: Date)
        -> [String: [InteractionDigest.DigestMessage]]
    {
        var byHandle: [String: [MessageExcerpt]] = [:]
        for e in excerpts where e.date >= windowStart && e.date <= now {
            byHandle[normalizer.normalize(e.handle), default: []].append(e)
        }
        return byHandle.mapValues { list in
            Array(
                list.reversed().sorted { $0.date > $1.date }
                    .lazy
                    .compactMap { e in
                        MessageExcerptPolicy.excerptText(e.text).map {
                            InteractionDigest.DigestMessage(date: e.date, fromMe: e.isFromMe, text: $0)
                        }
                    }
                    .prefix(MessageExcerptPolicy.maxPerHandle))
        }
    }
}

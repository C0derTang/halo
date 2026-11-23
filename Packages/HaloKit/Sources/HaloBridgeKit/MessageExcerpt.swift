import Foundation

/// Bounds for opt-in message excerpts (`halo-bridge export --with-messages`). One place only.
public enum MessageExcerptPolicy {
    /// At most this many excerpts per handle, newest first.
    public static let maxPerHandle = 20
    /// Only messages dated within `[now - window, now]`.
    public static let window: TimeInterval = 30 * 24 * 60 * 60
    /// Each excerpt is cut to this many characters (grapheme clusters).
    public static let maxCharacters = 500

    /// The text an excerpt should carry, or nil when nothing readable is left.
    /// U+FFFC (the attachment placeholder) is removed, so attachment-only messages yield nil.
    public static func excerptText(_ raw: String) -> String? {
        let cleaned = raw.replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maxCharacters))
    }

    /// The message's text: the `text` column when it holds something readable, else the decoded
    /// `attributedBody`. Nil when neither yields readable text.
    public static func messageText(text: String?, attributedBody: Data?) -> String? {
        if let text, let t = excerptText(text) { return t }
        guard let body = attributedBody, let decoded = TypedStreamDecoder.plainText(from: body) else {
            return nil
        }
        return excerptText(decoded)
    }
}

/// One 1:1 message WITH its text. Produced only when the user opts in (`--with-messages`).
///
/// MESSAGE CONTENT (invariant 6): never logged and never written to disk outside the sealed
/// `DigestEnvelope`. `description` is redacted so accidental interpolation leaks nothing.
public struct MessageExcerpt: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var handle: String
    public var isFromMe: Bool
    public var date: Date
    public var text: String

    public init(handle: String, isFromMe: Bool, date: Date, text: String) {
        self.handle = handle
        self.isFromMe = isFromMe
        self.date = date
        self.text = text
    }

    public var description: String { "MessageExcerpt(<redacted>)" }
    public var debugDescription: String { description }
}

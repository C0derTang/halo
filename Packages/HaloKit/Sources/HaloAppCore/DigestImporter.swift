import Foundation
import HaloBridgeKit
import HaloCore
import HaloImport

/// Why a `.halodigest` import failed. Nothing is saved for any of these.
public enum DigestImportError: Error, Equatable, CustomStringConvertible {
    /// This phone has no pairing key yet (never opened the pairing screen).
    case notPaired
    /// The file could not be read.
    case unreadable
    /// Not a `.halodigest` file, or truncated.
    case malformed
    /// Sealed to a different pairing key (the Mac is paired with another key; re-pair).
    case wrongKey
    /// Failed authentication: modified in transit, or sealed to another key.
    case tampered
    /// Unsupported envelope or digest version (too old / too new for this app).
    case unsupportedVersion
    /// Authenticated but the content is not a valid digest.
    case invalidDigest
    /// The Keychain could not be read.
    case keychainUnavailable
    /// The digest was valid but could not be saved.
    case saveFailed

    public var description: String { userMessage }

    /// Text for the UI. Never includes digest content.
    public var userMessage: String {
        switch self {
        case .notPaired:
            return "This iPhone is not paired yet. Show the pairing code and pair your Mac first."
        case .unreadable: return "The file could not be read."
        case .malformed: return "That is not a valid Halo digest file."
        case .wrongKey:
            return "This digest was made for a different pairing. Pair your Mac again and re-export."
        case .tampered: return "The digest failed its security check and was discarded."
        case .unsupportedVersion:
            return "This digest uses a version Halo does not support. Update Halo or halo-bridge."
        case .invalidDigest: return "The digest content is invalid."
        case .keychainUnavailable: return "The pairing key could not be read from the Keychain."
        case .saveFailed: return "The digest could not be saved."
        }
    }
}

/// What a successful import did.
public struct DigestImportReport: Equatable, Sendable {
    /// Distinct handles in the saved digest.
    public var entryCount: Int
    /// Entries whose handle resolved to exactly one known person.
    public var resolvedPeople: Int
    public var generatedAt: Date
}

/// Phone side of the iMessage bridge: opens a `.halodigest` with the Keychain pairing key and saves
/// the digest.
///
/// Invariants:
/// - Only authenticated digests are accepted (`DigestEnvelope.open` is HPKE-authenticated; any
///   failure saves nothing).
/// - The private key stays in the Keychain: this type only sees it through `PairingKey`, whose
///   private half is not public API.
/// - No plaintext is written to disk: the file is read into memory, decrypted in memory, and saved
///   only through `PeopleStoring` (the encrypted store).
/// - The input file is deleted after the attempt, on success AND on failure (the app's Inbox copy).
///
/// Handle normalization: the Mac normalized handles with the region it sealed into the (authenticated)
/// header. Here each handle is normalized again with `HandleNormalizer(region: opened.normalizerRegion)`,
/// i.e. the sender's region, never the phone's. That is idempotent for E.164 and emails, and canonicalizes
/// anything left in a national format using the region it was actually written in. Applying the phone's
/// region instead could attach a wrong country code. The app side (`ContextLabelRanker`, `HandleResolver`)
/// normalizes stored identities with the phone's normalizer, so both sides meet at E.164. Entries that
/// collapse to the same handle are merged.
public struct DigestImporter: Sendable {
    private let keyStore: any KeyStore
    private let store: any PeopleStoring
    private let resolver: HandleResolver

    public init(
        keyStore: any KeyStore, store: any PeopleStoring,
        normalization: HandleNormalization = HandleNormalization()
    ) {
        self.keyStore = keyStore
        self.store = store
        self.resolver = HandleResolver(store: store, normalization: normalization)
    }

    /// Imports the file at `url`, then deletes it (security-scoped access is honored).
    public func importDigest(url: URL) async throws -> DigestImportReport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            Self.removeQuietly(url)
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw DigestImportError.unreadable }
        return try await importDigest(data: data)
    }

    /// Imports sealed envelope bytes already in memory.
    public func importDigest(data: Data) async throws -> DigestImportReport {
        let key: PairingKey?
        do {
            key = try PairingKey.load(from: keyStore)
        } catch {
            throw DigestImportError.keychainUnavailable
        }
        guard let key else { throw DigestImportError.notPaired }

        let opened: OpenedDigest
        do {
            opened = try DigestEnvelope.open(data, with: key)
        } catch {
            throw Self.map(error)
        }
        guard opened.digest.version == InteractionDigest.currentVersion else {
            throw DigestImportError.unsupportedVersion
        }

        let digest = Self.renormalized(opened.digest, region: opened.normalizerRegion)
        do {
            try await store.saveDigest(digest)
        } catch {
            throw DigestImportError.saveFailed
        }

        var resolved = 0
        for entry in digest.entries {
            if (try? await resolver.resolve(entry)) != nil { resolved += 1 }
        }
        return DigestImportReport(
            entryCount: digest.entries.count, resolvedPeople: resolved, generatedAt: digest.generatedAt)
    }

    static func map(_ error: DigestEnvelopeError) -> DigestImportError {
        switch error {
        case .malformed, .invalidRegion: return .malformed
        case .unsupportedVersion: return .unsupportedVersion
        case .wrongKey: return .wrongKey
        case .authenticationFailed: return .tampered
        case .invalidDigest: return .invalidDigest
        }
    }

    static func renormalized(_ digest: InteractionDigest, region: String) -> InteractionDigest {
        let normalizer = HandleNormalizer(region: region)
        var merged: [String: InteractionDigest.Entry] = [:]
        var order: [String] = []
        for entry in digest.entries {
            let handle = normalizer.normalize(entry.handle)
            var e = entry
            e.handle = handle
            if let existing = merged[handle] {
                merged[handle] = merge(existing, e)
            } else {
                merged[handle] = e
                order.append(handle)
            }
        }
        var out = digest
        out.entries = order.compactMap { merged[$0] }
        return out
    }

    private static func merge(_ a: InteractionDigest.Entry, _ b: InteractionDigest.Entry)
        -> InteractionDigest.Entry
    {
        func latest(_ x: Date?, _ y: Date?) -> Date? {
            switch (x, y) {
            case (let x?, let y?): return max(x, y)
            default: return x ?? y
            }
        }
        let fromMe = latest(a.lastFromMeAt, b.lastFromMeAt)
        let fromThem = latest(a.lastFromThemAt, b.lastFromThemAt)
        let awaiting: Bool
        switch (fromThem, fromMe) {
        case (let them?, let me?): awaiting = them > me
        case (.some, nil): awaiting = true
        default: awaiting = false
        }
        return InteractionDigest.Entry(
            handle: a.handle, lastMessageAt: latest(a.lastMessageAt, b.lastMessageAt),
            lastFromMeAt: fromMe, lastFromThemAt: fromThem,
            messagesLast30Days: a.messagesLast30Days + b.messagesLast30Days,
            messagesAllTime: a.messagesAllTime + b.messagesAllTime, awaitingMyReply: awaiting)
    }

    private static func removeQuietly(_ url: URL) {
        guard url.isFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

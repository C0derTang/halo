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
    /// Authenticated, but older than the digest already stored (replay of an old export).
    case staleDigest

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
        case .staleDigest: return "This digest is older than the one already imported, so it was ignored."
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
    /// Entries dropped because their handle is a bare phone-like number from a sender region this
    /// app cannot normalize (ambiguous: a missed match beats a wrong one).
    public var droppedAmbiguous: Int = 0
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
/// - The file is deleted only when it lives inside the app's own container (Inbox / tmp / caches); a
///   user's original file picked from elsewhere is never removed.
/// - A digest older than the stored one is rejected (`staleDigest`).
///
/// Handle normalization: the Mac normalized handles with the region it sealed into the (authenticated)
/// header. Here each handle is normalized again with `HandleNormalizer(region: opened.normalizerRegion)`,
/// i.e. the sender's region, never the phone's. That is idempotent for E.164 and emails, and canonicalizes
/// national-format numbers using the region they were written in. If the sender's region is not in
/// `HandleNormalizer`'s table, phone-like numbers without a `+` cannot be made E.164 safely, and
/// downstream `HandleResolver`/`ContextLabelRanker` would re-normalize bare digits with the PHONE's
/// region and could match a different person. Such entries are therefore DROPPED (a missed match beats a
/// wrong one). Entries that collapse to the same handle are merged, recomputing `awaitingMyReply`.
public struct DigestImporter: Sendable {
    private let keyStore: any KeyStore
    private let store: any PeopleStoring
    private let resolver: HandleResolver
    private let deletableRoots: [URL]

    public init(
        keyStore: any KeyStore, store: any PeopleStoring,
        normalization: HandleNormalization = HandleNormalization(),
        deletableRoots: [URL] = DigestImporter.defaultDeletableRoots
    ) {
        self.deletableRoots = deletableRoots
        self.keyStore = keyStore
        self.store = store
        self.resolver = HandleResolver(store: store, normalization: normalization)
    }

    /// Where imported files may be deleted from: the app container's temporary, Inbox and cache folders.
    public static var defaultDeletableRoots: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return [
            FileManager.default.temporaryDirectory,
            home.appendingPathComponent("tmp", isDirectory: true),
            home.appendingPathComponent("Documents/Inbox", isDirectory: true),
            home.appendingPathComponent("Library/Caches", isDirectory: true),
        ]
    }

    /// Imports the file at `url`, then deletes it if it is inside the app container
    /// (security-scoped access is honored).
    public func importDigest(url: URL) async throws -> DigestImportReport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            removeIfOwned(url)
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

        let (digest, droppedAmbiguous) = Self.renormalizedCountingDropped(
            opened.digest, region: opened.normalizerRegion)
        if let stored = try? await store.latestDigest(), digest.generatedAt < stored.generatedAt {
            throw DigestImportError.staleDigest
        }
        do {
            try await store.saveDigest(digest)
        } catch {
            throw DigestImportError.saveFailed
        }

        var resolved = Set<PersonID>()
        for entry in digest.entries {
            if let id = try? await resolver.resolve(entry) { resolved.insert(id) }
        }
        return DigestImportReport(
            entryCount: digest.entries.count, resolvedPeople: resolved.count, generatedAt: digest.generatedAt,
            droppedAmbiguous: droppedAmbiguous)
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
        renormalizedCountingDropped(digest, region: region).digest
    }

    /// `renormalized` plus how many entries were dropped as ambiguous bare numbers.
    static func renormalizedCountingDropped(_ digest: InteractionDigest, region: String)
        -> (digest: InteractionDigest, dropped: Int)
    {
        var dropped = 0
        let normalizer = HandleNormalizer(region: region)
        let known = HandleNormalizer.isKnownRegion(region)
        var merged: [String: InteractionDigest.Entry] = [:]
        var order: [String] = []
        for entry in digest.entries {
            let handle = normalizer.normalize(entry.handle)
            if !known, isBarePhoneLike(handle) {
                dropped += 1
                continue
            }
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
        return (out, dropped)
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

    /// Phone-like (no letters, >= 7 digits) but without a "+": ambiguous without a known region.
    static func isBarePhoneLike(_ handle: String) -> Bool {
        guard !handle.hasPrefix("+"), !handle.contains("@"), !handle.contains(where: \.isLetter) else {
            return false
        }
        return handle.filter { $0.isASCII && $0.isNumber }.count >= 7
    }

    private func removeIfOwned(_ url: URL) {
        guard url.isFileURL else { return }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let owned = deletableRoots.contains { root in
            let r = root.resolvingSymlinksInPath().standardizedFileURL.path
            return path.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        }
        guard owned else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

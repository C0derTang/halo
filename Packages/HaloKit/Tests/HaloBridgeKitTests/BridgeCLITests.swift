import CryptoKit
import Foundation
import HaloCore
import Testing

@testable import HaloBridgeKit

/// Every CLI test injects an `InMemoryKeyStore` and a synthetic `--db`: the real Keychain and
/// the real chat.db are never touched.
@Suite struct BridgeCLITests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func fixture() throws -> SyntheticChatDB {
        let db = try SyntheticChatDB()
        let alice = try db.addHandle("(415) 555-0132")
        let bob = try db.addHandle("bob@example.com")
        let a = try db.addChat(handles: [alice])
        let b = try db.addChat(handles: [bob])
        try db.addMessage(chat: a, handle: alice, fromMe: false, at: now.addingTimeInterval(-86_400))
        try db.addMessage(chat: b, handle: bob, fromMe: true, at: now.addingTimeInterval(-86_400))
        return db
    }

    struct Run {
        var code: Int32
        var out: [String] = []
        var err: [String] = []
    }

    func run(_ args: [String], store: InMemoryKeyStore) -> Run {
        var out: [String] = []
        var err: [String] = []
        let code = BridgeCLI.run(
            arguments: args, keyStore: store, output: { out.append($0) }, errorOutput: { err.append($0) })
        return Run(code: code, out: out, err: err)
    }

    @Test func pairStoresPhonePublicKeyOnly() throws {
        let store = InMemoryKeyStore()
        let phone = PairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey())
        let r = run(["pair", phone.pairingPayload], store: store)
        #expect(r.code == 0)
        #expect(r.out.first?.contains(phone.keyID.description) == true)
        #expect(store.accounts == [PairedPhone.keychainAccount])
        #expect(try PairedPhone.load(from: store) == phone.payload)
    }

    @Test func pairRejectsBadPayload() throws {
        let store = InMemoryKeyStore()
        #expect(run(["pair", "garbage!"], store: store).code == 1)
        #expect(run(["pair"], store: store).code == 64)
        #expect(store.accounts.isEmpty)
    }

    @Test func exportSealsToPairedPhone() throws {
        let db = try fixture()
        let store = InMemoryKeyStore()
        let phone = PairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey())
        #expect(run(["pair", phone.pairingPayload], store: store).code == 0)
        let out = db.dir.appendingPathComponent("digest.halodigest")
        let r = run(
            [
                "export", "--db", db.url.path, "--out", out.path, "--now", "2027-01-15T08:00:00Z", "--region",
                "us",
            ], store: store)
        #expect(r.code == 0, "\(r.err)")

        let data = try Data(contentsOf: out)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(SyntheticChatDB.secretText))
        #expect(!text.contains("bob@example.com"))  // not plaintext
        let perms = try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: db.dir.path)
            .filter { $0.hasPrefix(SecureFileWriter.tempPrefix) }
        #expect(leftovers.isEmpty)

        let opened = try DigestEnvelope.open(data, with: phone)
        #expect(opened.normalizerRegion == "US")
        #expect(opened.digest.version == InteractionDigest.currentVersion)
        #expect(opened.digest.entries.map(\.handle) == ["+14155550132", "bob@example.com"])
        #expect(opened.digest.generatedAt == ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
    }

    @Test func exportRecordsRegionUsedForNormalization() throws {
        let db = try SyntheticChatDB()
        let h = try db.addHandle("070-123 45 67")
        let c = try db.addChat(handles: [h])
        try db.addMessage(chat: c, handle: h, fromMe: false, at: now)
        let store = InMemoryKeyStore()
        let phone = PairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey())
        try PairedPhone.save(phone.payload, in: store)
        let out = db.dir.appendingPathComponent("se.halodigest")
        let r = run(["export", "--db", db.url.path, "--out", out.path, "--region", "SE"], store: store)
        #expect(r.code == 0)
        #expect(r.err.contains { $0.contains("SE") })  // unknown-region warning
        let opened = try DigestEnvelope.open(try Data(contentsOf: out), with: phone)
        #expect(opened.normalizerRegion == "SE")
        // The app re-normalizing with the recorded region gets the same keys.
        let app = HandleNormalizer(region: opened.normalizerRegion)
        #expect(opened.digest.entries.map(\.handle) == [app.normalize("070-123 45 67")])
        #expect(opened.digest.entries.map(\.handle) == ["0701234567"])
    }

    @Test func exportDefaultsRegionToLocale() throws {
        guard
            case .export(let o) = try BridgeCLI.parse(
                ["export", "--out", "x.halodigest"], defaultRegion: "gb")
        else {
            Issue.record("expected export")
            return
        }
        #expect(o.region == "GB")
        guard case .export(let real) = try BridgeCLI.parse(["export", "--out", "x.halodigest"]) else {
            Issue.record("expected export")
            return
        }
        #expect(real.region == (BridgeCLI.localeRegion ?? BridgeCLI.unknownRegion))
    }

    @Test func missingLocaleRegionIsUnknownNotUS() throws {
        guard
            case .export(let o) = try BridgeCLI.parse(
                ["export", "--out", "x.halodigest"], defaultRegion: nil)
        else {
            Issue.record("expected export")
            return
        }
        #expect(o.region == BridgeCLI.unknownRegion)
        #expect(o.regionMissing)
        #expect(!HandleNormalizer.isKnownRegion(o.region))
        // National numbers are not guessed as +1.
        #expect(HandleNormalizer(region: o.region).normalize("(415) 555-0132") == "4155550132")
        var warnings: [String] = []
        BridgeCLI.warnOnUnknownRegion(o, { warnings.append($0) })
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("--region"))

        // An explicit --region wins and needs no warning.
        guard
            case .export(let explicit) = try BridgeCLI.parse(
                ["export", "--out", "x.halodigest", "--region", "US"], defaultRegion: nil)
        else {
            Issue.record("expected export")
            return
        }
        #expect(explicit.region == "US" && !explicit.regionMissing)
        warnings = []
        BridgeCLI.warnOnUnknownRegion(explicit, { warnings.append($0) })
        #expect(warnings.isEmpty)
    }

    @Test func exportRequiresPairingBeforeReadingChatDB() throws {
        let store = InMemoryKeyStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-cli-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("d.halodigest")
        // The --db path does not exist: the notPaired error must come first.
        let r = run(["export", "--db", "/nonexistent/chat.db", "--out", out.path], store: store)
        #expect(r.code == 1)
        #expect(r.err.first?.contains("No phone paired") == true)
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func exportRequiresHalodigestExtension() {
        let r = run(["export", "--out", "digest.json"], store: InMemoryKeyStore())
        #expect(r.code == 64)
    }

    @Test func plaintextNeedsExplicitFlag() throws {
        let db = try fixture()
        let out = db.dir.appendingPathComponent("digest.json")
        let refused = run(["digest", "--db", db.url.path, "--out", out.path], store: InMemoryKeyStore())
        #expect(refused.code == 64)
        #expect(!FileManager.default.fileExists(atPath: out.path))

        let r = run(
            [
                "digest", "--plaintext", "--db", db.url.path, "--out", out.path, "--now",
                "2027-01-15T08:00:00Z",
            ],
            store: InMemoryKeyStore())
        #expect(r.code == 0)
        #expect(r.err.contains { $0.contains("UNENCRYPTED") })
        let data = try Data(contentsOf: out)
        #expect(!String(decoding: data, as: UTF8.self).contains(SyntheticChatDB.secretText))
        let digest = try DigestCoding.decoder().decode(InteractionDigest.self, from: data)
        #expect(digest.entries.count == 2)
        let perms = try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func usageErrors() {
        let store = InMemoryKeyStore()
        #expect(run([], store: store).code == 64)
        #expect(run(["bogus"], store: store).code == 64)
        #expect(run(["export"], store: store).code == 64)
        #expect(run(["export", "--out", "x.halodigest", "--now", "garbage"], store: store).code == 64)
        #expect(
            run(["export", "--out", "x.halodigest", "--region", "not a region"], store: store).code == 64)
        #expect(run(["export", "--out", "x.halodigest", "--plaintext"], store: store).code == 64)
        #expect(run(["export", "--out"], store: store).code == 64)
        #expect(store.accounts.isEmpty)
    }

    @Test func missingDatabaseIsRuntimeError() throws {
        let store = InMemoryKeyStore()
        try PairedPhone.save(PairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey()).payload, in: store)
        let r = run(
            ["export", "--db", "/nonexistent/chat.db", "--out", "/tmp/never.halodigest"], store: store)
        #expect(r.code == 1)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/never.halodigest"))
    }
}

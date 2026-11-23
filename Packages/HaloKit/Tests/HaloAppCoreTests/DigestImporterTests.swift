import CryptoKit
import Foundation
import HaloBridgeKit
import HaloCore
import HaloImport
import Testing

@testable import HaloAppCore

private func entry(_ handle: String, last: Date? = nil, n30: Int = 1, all: Int = 2) -> InteractionDigest.Entry
{
    InteractionDigest.Entry(
        handle: handle, lastMessageAt: last, lastFromMeAt: nil, lastFromThemAt: last,
        messagesLast30Days: n30, messagesAllTime: all, awaitingMyReply: last != nil)
}

private func digest(_ entries: [InteractionDigest.Entry], version: Int = InteractionDigest.currentVersion)
    -> InteractionDigest
{
    InteractionDigest(
        version: version, generatedAt: Date(timeIntervalSince1970: 1_700_000_000), entries: entries)
}

/// A paired phone (in-memory key store) plus a temp "Inbox".
private struct Harness {
    let keys = MemoryKeyStore()
    let store = RecordingStore()
    let inbox: URL
    let payload: PairingPayload

    init() throws {
        let key = try PairingKey.loadOrCreate(in: keys)
        payload = try PairingPayload(encoded: key.pairingPayload)
        inbox = FileManager.default.temporaryDirectory.appendingPathComponent(
            "halo-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    var importer: DigestImporter {
        DigestImporter(
            keyStore: keys, store: store, normalization: HandleNormalization(region: "US"))
    }

    func inboxFile(_ data: Data) throws -> URL {
        let url = inbox.appendingPathComponent("\(UUID().uuidString).halodigest")
        try data.write(to: url)
        return url
    }

    func sealed(_ d: InteractionDigest, region: String = "US") throws -> Data {
        try DigestEnvelope.seal(d, normalizerRegion: region, to: payload).serialized
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

private func expectImportError(
    _ h: Harness, _ data: Data, _ expected: DigestImportError
) async throws {
    let url = try h.inboxFile(data)
    await #expect(throws: expected) { try await h.importer.importDigest(url: url) }
    #expect(await h.store.saved.isEmpty, "nothing saved on failure")
    #expect(!h.exists(url), "inbox file deleted after failure")
}

@Suite struct DigestImporterTests {
    @Test func roundTripSavesAndReportsCounts() async throws {
        let h = try Harness()
        let alice = Person(displayName: "Alice", confirmed: true)
        await h.store.add(
            alice, identities: [Identity(personID: alice.id, kind: .phone, value: "+15551230001")])
        let d = digest([entry("+15551230001"), entry("+15551230002"), entry("bob@example.com")])
        let url = try h.inboxFile(try h.sealed(d))

        let report = try await h.importer.importDigest(url: url)

        #expect(report.entryCount == 3)
        #expect(report.resolvedPeople == 1)
        #expect(await h.store.saved == [d])
        #expect(!h.exists(url), "inbox file deleted after success")
    }

    @Test func wrongKeyRejected() async throws {
        let h = try Harness()
        let other = Curve25519.KeyAgreement.PrivateKey()
        let foreign = try DigestEnvelope.seal(
            digest([entry("+15551230001")]), normalizerRegion: "US",
            to: PairingPayload(publicKey: other.publicKey)
        ).serialized
        try await expectImportError(h, foreign, .wrongKey)
    }

    @Test func tamperedCiphertextRejected() async throws {
        let h = try Harness()
        var data = try h.sealed(digest([entry("+15551230001")]))
        data[data.count - 1] ^= 0x01
        try await expectImportError(h, data, .tampered)
    }

    @Test func tamperedHeaderRegionRejected() async throws {
        let h = try Harness()
        var data = try h.sealed(digest([entry("+15551230001")]), region: "US")
        // Header: magic(8) version(1) keyID(8) regionLen(1) region -> flip the region's first byte.
        let regionStart = 8 + 1 + 8 + 1
        data[regionStart] = Character("G").asciiValue!
        try await expectImportError(h, data, .tampered)
    }

    @Test func garbageIsMalformed() async throws {
        let h = try Harness()
        try await expectImportError(h, Data("not a digest".utf8), .malformed)
        try await expectImportError(h, Data(), .malformed)
    }

    @Test func oldEnvelopeVersionRejected() async throws {
        let h = try Harness()
        var data = try h.sealed(digest([entry("+15551230001")]))
        data[8] = 0  // version byte
        try await expectImportError(h, data, .unsupportedVersion)
    }

    @Test func oldDigestVersionRejected() async throws {
        let h = try Harness()
        let data = try h.sealed(digest([entry("+15551230001")], version: 0))
        try await expectImportError(h, data, .unsupportedVersion)
    }

    @Test func notPairedRejected() async throws {
        let h = try Harness()
        let data = try h.sealed(digest([entry("+15551230001")]))
        try PairingKey.delete(from: h.keys)
        try await expectImportError(h, data, .notPaired)
    }

    @Test func unreadableFileStillCleansUp() async throws {
        let h = try Harness()
        let missing = h.inbox.appendingPathComponent("missing.halodigest")
        await #expect(throws: DigestImportError.unreadable) {
            try await h.importer.importDigest(url: missing)
        }
        #expect(await h.store.saved.isEmpty)
    }

    @Test func saveFailureReportedAndFileDeleted() async throws {
        let h = try Harness()
        await h.store.setFailSave(true)
        let url = try h.inboxFile(try h.sealed(digest([entry("+15551230001")])))
        await #expect(throws: DigestImportError.saveFailed) { try await h.importer.importDigest(url: url) }
        #expect(!h.exists(url))
    }

    @Test func noPlaintextLeftOnDisk() async throws {
        let h = try Harness()
        let url = try h.inboxFile(try h.sealed(digest([entry("+15551230001")])))
        _ = try await h.importer.importDigest(url: url)
        let left = try FileManager.default.contentsOfDirectory(atPath: h.inbox.path)
        #expect(left.isEmpty)
    }

    // MARK: region handling

    @Test func nationalHandlesNormalizedWithSenderRegionNotPhoneRegion() async throws {
        let h = try Harness()  // phone region US
        let gb = Person(displayName: "Gary", confirmed: true)
        await h.store.add(gb, identities: [Identity(personID: gb.id, kind: .phone, value: "+447911123456")])
        // A national-format GB handle that the bridge left as-is; sealed with region GB.
        let data = try h.sealed(digest([entry("07911 123456")]), region: "GB")

        let report = try await h.importer.importDigest(data: data)

        #expect(await h.store.saved.first?.entries.map(\.handle) == ["+447911123456"])
        #expect(report.resolvedPeople == 1)
    }

    @Test func unknownSenderRegionNeverGuessesCountryCode() async throws {
        let h = try Harness()
        let data = try h.sealed(digest([entry("0791 1123456")]), region: "ZZ")
        _ = try await h.importer.importDigest(data: data)
        let handle = try #require(await h.store.saved.first?.entries.first?.handle)
        #expect(!handle.hasPrefix("+"))
    }

    @Test func entriesCollapsingToSameHandleAreMerged() async throws {
        let h = try Harness()
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        let data = try h.sealed(
            digest([
                entry("(555) 123-0001", last: t1, n30: 1, all: 5),
                entry("+1 555 123 0001", last: t2, n30: 2, all: 7),
            ]))
        let report = try await h.importer.importDigest(data: data)
        let saved = try #require(await h.store.saved.first)
        #expect(report.entryCount == 1)
        #expect(saved.entries.count == 1)
        #expect(saved.entries[0].handle == "+15551230001")
        #expect(saved.entries[0].messagesAllTime == 12)
        #expect(saved.entries[0].messagesLast30Days == 3)
        #expect(saved.entries[0].lastMessageAt == t2)
    }

    @Test func handleSharedByTwoPeopleDoesNotResolve() async throws {
        let h = try Harness()
        let a = Person(displayName: "A", confirmed: true)
        let b = Person(displayName: "B", confirmed: true)
        await h.store.add(
            a, identities: [Identity(personID: a.id, kind: .phone, value: "+15551230001")])
        await h.store.add(
            b, identities: [Identity(personID: b.id, kind: .imessageHandle, value: "+15551230001")])
        let report = try await h.importer.importDigest(data: try h.sealed(digest([entry("+15551230001")])))
        #expect(report.entryCount == 1)
        #expect(report.resolvedPeople == 0)
    }

    @MainActor @Test func modelReportsMessagesAndStatus() async throws {
        let h = try Harness()
        let importer = h.importer
        let model = DigestImportModel(importer: importer)
        let ok = try h.inboxFile(try h.sealed(digest([entry("+15551230001")])))
        await model.importDigest(url: ok)
        #expect(
            model.status
                == .succeeded(
                    DigestImportReport(
                        entryCount: 1, resolvedPeople: 0,
                        generatedAt: Date(timeIntervalSince1970: 1_700_000_000))))
        #expect(model.message?.contains("Imported 1") == true)

        await model.importDigest(url: try h.inboxFile(Data("junk".utf8)))
        #expect(model.status == .failed(.malformed))
        #expect(model.message == DigestImportError.malformed.userMessage)
    }
}

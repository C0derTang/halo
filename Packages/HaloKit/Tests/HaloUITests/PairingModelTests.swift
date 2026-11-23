import CoreGraphics
import Foundation
import Testing

@testable import HaloUI

private final class FakeProvider: PairingKeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    var failing = false
    struct Boom: Error {}

    func currentPayload() throws -> String {
        if failing { throw Boom() }
        return lock.withLock { "payload-\(generation)" }
    }
    func rotate() throws -> String {
        if failing { throw Boom() }
        return lock.withLock {
            generation += 1
            return "payload-\(generation)"
        }
    }
}

private struct StubAuth: Authenticating {
    let result: Bool
    func authenticate(reason: String) async -> Bool { result }
}

@MainActor
@Suite struct PairingModelTests {
    @Test func lockedUntilAuthenticated() async {
        let model = PairingModel(provider: FakeProvider(), authenticator: StubAuth(result: false))
        #expect(model.payload == nil)
        #expect(await model.unlock() == false)
        #expect(model.payload == nil)
    }

    @Test func unlockShowsPayloadAndLockHidesIt() async {
        let model = PairingModel(provider: FakeProvider(), authenticator: StubAuth(result: true))
        #expect(await model.unlock())
        #expect(model.payload == "payload-0")
        model.lock()
        #expect(model.payload == nil)
        #expect(!model.isUnlocked)
    }

    @Test func repairNeedsConfirmationThenRotates() async {
        let model = PairingModel(provider: FakeProvider(), authenticator: StubAuth(result: true))
        await model.unlock()
        model.confirmRepair()  // no confirmation requested yet: no-op
        #expect(model.payload == "payload-0")
        model.requestRepair()
        #expect(model.isConfirmingRepair)
        model.cancelRepair()
        model.confirmRepair()
        #expect(model.payload == "payload-0")
        model.requestRepair()
        model.confirmRepair()
        #expect(model.payload == "payload-1")
        #expect(!model.isConfirmingRepair)
    }

    @Test func cannotRepairWhileLocked() {
        let model = PairingModel(provider: FakeProvider(), authenticator: StubAuth(result: true))
        model.requestRepair()
        #expect(!model.isConfirmingRepair)
    }

    @Test func providerFailureKeepsLockedWithMessage() async {
        let provider = FakeProvider()
        provider.failing = true
        let model = PairingModel(provider: provider, authenticator: StubAuth(result: true))
        #expect(await model.unlock() == false)
        #expect(model.payload == nil)
        #expect(model.errorMessage != nil)
    }

    @Test func qrImageIsGenerated() throws {
        let image = try #require(PairingQR.image(for: "AbCdEf-_0123"))
        #expect(image.width > 20)
        #expect(image.width == image.height)
    }
}

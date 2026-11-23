import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
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

    @Test func repairSurvivesDialogResettingBinding() async {
        let model = PairingModel(provider: FakeProvider(), authenticator: StubAuth(result: true))
        await model.unlock()
        model.requestRepair()
        model.isConfirmingRepair = false  // SwiftUI dismisses the dialog before the action runs
        model.confirmRepair()
        #expect(model.payload == "payload-1")
    }

    @Test func lockBetweenRequestAndConfirmBlocksRepair() async {
        let provider = FakeProvider()
        let model = PairingModel(provider: provider, authenticator: StubAuth(result: true))
        await model.unlock()
        model.requestRepair()
        model.lock()
        await model.unlock()
        model.confirmRepair()
        #expect(model.payload == "payload-0")
    }

    @Test func qrCachedPerPayloadAndHasQuietZone() async throws {
        let model = PairingModel(provider: FakeProvider(), authenticator: StubAuth(result: true))
        #expect(model.qrImage == nil)
        await model.unlock()
        let image = try #require(model.qrImage)
        // The bare code, generated independently of `PairingQR`, at the same integer scale.
        let scale = 8
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("payload-0".utf8)
        filter.correctionLevel = "M"
        let bareWidth = Int(try #require(filter.outputImage).extent.width) * scale
        // Quiet zone: 4 modules on each side.
        #expect(image.width == bareWidth + 8 * scale)
        #expect(image.height == image.width)
        #expect(try Self.pixel(image, x: 0, y: 0) == [255, 255, 255, 255])
        model.lock()
        #expect(model.qrImage == nil)
    }

    /// RGBA of the pixel at (x, y) from the top-left, drawn into a known sRGB layout.
    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(
            CGContext(
                data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = (y * image.width + x) * 4  // bitmap rows start at the top
        return Array(data[offset..<offset + 4])
    }
}

import Foundation
import Observation

/// Seam over the pairing key (implemented in HaloAppCore with HaloBridgeKit + the Keychain).
/// Only public material crosses it: the private key never leaves the Keychain.
public protocol PairingKeyProviding: Sendable {
    /// The payload to show as a QR code; creates the key on first use.
    func currentPayload() throws -> String
    /// Replaces the key; the Mac must be paired again.
    func rotate() throws -> String
}

/// Pairing screen model. The QR/payload is exposed only while unlocked (device-owner auth).
@Observable @MainActor
public final class PairingModel {
    /// The payload to render and copy; nil while locked.
    public private(set) var payload: String?
    public private(set) var errorMessage: String?
    public var isConfirmingRepair = false

    public var isUnlocked: Bool { payload != nil }

    @ObservationIgnored private let provider: any PairingKeyProviding
    @ObservationIgnored private let authenticator: any Authenticating

    public init(provider: any PairingKeyProviding, authenticator: any Authenticating) {
        self.provider = provider
        self.authenticator = authenticator
    }

    @discardableResult
    public func unlock() async -> Bool {
        guard await authenticator.authenticate(reason: "Show the pairing code for your Mac") else {
            lock()
            return false
        }
        do {
            payload = try provider.currentPayload()
            errorMessage = nil
            return true
        } catch {
            lock()
            errorMessage = "The pairing key could not be read."
            return false
        }
    }

    /// Hide the code (call when the screen disappears or the app leaves the foreground).
    public func lock() {
        payload = nil
        isConfirmingRepair = false
    }

    public func requestRepair() {
        guard isUnlocked else { return }
        isConfirmingRepair = true
    }

    public func cancelRepair() { isConfirmingRepair = false }

    /// Rotates the key after the user confirmed. Old digests become unreadable.
    public func confirmRepair() {
        guard isUnlocked, isConfirmingRepair else { return }
        isConfirmingRepair = false
        do {
            payload = try provider.rotate()
            errorMessage = nil
        } catch {
            errorMessage = "The pairing key could not be replaced."
        }
    }
}

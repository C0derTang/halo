import Foundation
import LocalAuthentication

/// Device-owner authentication (Face ID, falling back to passcode). Injected so tests use a fake.
public protocol Authenticating: Sendable {
    /// Returns true only when the owner successfully authenticated. Any failure is `false`.
    func authenticate(reason: String) async -> Bool
}

/// Real implementation over LocalAuthentication. Fails closed when authentication is unavailable.
public struct LocalAuthenticator: Authenticating {
    public init() {}

    public func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

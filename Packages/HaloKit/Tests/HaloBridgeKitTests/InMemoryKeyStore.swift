import Foundation
import Synchronization

@testable import HaloBridgeKit

/// Test double for `KeyStore`. Tests never touch the real Keychain.
final class InMemoryKeyStore: KeyStore {
    private let items = Mutex<[String: Data]>([:])
    /// When set, every operation throws this.
    let failure: KeyStoreError?

    init(failure: KeyStoreError? = nil) { self.failure = failure }

    func read(account: String) throws -> Data? {
        if let failure { throw failure }
        return items.withLock { $0[account] }
    }

    func write(_ data: Data, account: String) throws {
        if let failure { throw failure }
        items.withLock { $0[account] = data }
    }

    func delete(account: String) throws {
        if let failure { throw failure }
        _ = items.withLock { $0.removeValue(forKey: account) }
    }

    var accounts: [String] { items.withLock { Array($0.keys).sorted() } }
}

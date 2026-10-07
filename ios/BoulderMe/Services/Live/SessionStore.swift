import Foundation
import Security

/// Where the signed-in session lives between launches.
protocol SessionStore: Sendable {
    func load() -> Session?
    func save(_ session: Session) throws
    func clear()
}

/// Keychain-backed store: one generic-password item holding the `Session` JSON,
/// readable after first unlock, never synced or migrated to another device.
struct KeychainSessionStore: SessionStore {
    var service = "com.zainpi.boulderme.session"
    var account = "current"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> Session? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? APICoding.makeDecoder().decode(Session.self, from: data)
    }

    func save(_ session: Session) throws {
        let data = try APICoding.makeEncoder().encode(session)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

struct KeychainError: Error, Equatable {
    let status: OSStatus
}

/// For tests and previews.
final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: Session?

    init(_ session: Session? = nil) { self.session = session }

    func load() -> Session? { lock.withLock { session } }
    func save(_ session: Session) throws { lock.withLock { self.session = session } }
    func clear() { lock.withLock { session = nil } }
}

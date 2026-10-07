import Foundation

/// Small per-account values kept on this device: the last `Me` (for offline
/// launches), the onboarding draft and onboarding choices. Every key is
/// prefixed with the account id, and `wipeAll` removes them on sign-out,
/// account deletion or an account switch. Demo mode never writes here.
struct AccountCache: @unchecked Sendable {
    static let keyPrefix = "account."

    let defaults: UserDefaults
    let accountId: EntityID

    private func key(_ name: String) -> String { "\(Self.keyPrefix)\(accountId).\(name)" }

    func value<Value: Decodable>(_ name: String, as type: Value.Type = Value.self) -> Value? {
        guard let data = defaults.data(forKey: key(name)) else { return nil }
        return try? APICoding.makeDecoder().decode(Value.self, from: data)
    }

    func set<Value: Encodable>(_ value: Value?, for name: String) {
        if let value, let data = try? APICoding.makeEncoder().encode(value) {
            defaults.set(data, forKey: key(name))
        } else {
            defaults.removeObject(forKey: key(name))
        }
    }

    static func wipeAll(in defaults: UserDefaults) {
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: name)
        }
    }
}

/// Per-install facts that are not tied to an account.
enum Installation {
    private static let idKey = "installation.id"
    private static let launchedKey = "installation.launched"

    /// Random per-install UUID sent with sign-in, used only for rate limiting.
    static func id(in defaults: UserDefaults) -> EntityID {
        if let raw = defaults.string(forKey: idKey), let id = EntityID(raw) { return id }
        let id = EntityID()
        defaults.set(id.description, forKey: idKey)
        return id
    }

    /// Keychain items survive deleting the app, UserDefaults don't. On the
    /// first launch of a fresh install, drop any session left by an old one.
    static func clearStaleSession(store: any SessionStore, defaults: UserDefaults) {
        guard !defaults.bool(forKey: launchedKey) else { return }
        store.clear()
        defaults.set(true, forKey: launchedKey)
    }
}

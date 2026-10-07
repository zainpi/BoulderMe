import Foundation

// Auth DTOs from the `auth` and `account` tags of docs/api/openapi.yaml.

struct AuthNonce: Codable, Hashable, Sendable {
    var nonce: String
    var expiresAt: Date
}

struct AppleSignInRequest: Codable, Hashable, Sendable {
    var identityToken: String
    var authorizationCode: String
    var nonce: String
    /// Only sent by Apple on the first authorization. Nullable, so encoded as `null`.
    var givenName: String?
    var clientInstallationId: EntityID

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identityToken, forKey: .identityToken)
        try container.encode(authorizationCode, forKey: .authorizationCode)
        try container.encode(nonce, forKey: .nonce)
        try container.encode(givenName, forKey: .givenName)
        try container.encode(clientInstallationId, forKey: .clientInstallationId)
    }
}

struct RefreshRequest: Codable, Hashable, Sendable {
    var refreshToken: String
}

/// `Session` from the contract. Also what the Keychain stores.
struct Session: Codable, Hashable, Sendable {
    var accessToken: String
    var accessTokenExpiresAt: Date
    var refreshToken: String
    var refreshTokenExpiresAt: Date
    var accountId: EntityID
    var isNewAccount: Bool
}

struct DeleteAccountRequest: Codable, Hashable, Sendable {
    var confirm = "DELETE"
}

struct DiscoverySetting: Codable, Hashable, Sendable {
    var discoverable: Bool
}

struct GymAccessInput: Codable, Hashable, Sendable {
    var accessType: AccessType
}

/// `{items}` wrapper for the unpaged lists (`/v1/me/gyms`, `/v1/me/availability`).
struct ItemList<Item: Codable & Sendable>: Codable, Sendable {
    var items: [Item]
}

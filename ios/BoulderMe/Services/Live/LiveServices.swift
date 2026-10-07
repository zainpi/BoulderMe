import Foundation

// The Worker-backed services for T6 areas (auth, account, profile, gyms,
// availability). Discovery, invitations, chats and safety stay on
// `PendingLiveServices` until T7.

extension APIClient: AuthService {
    func storedAccountId() async -> EntityID? { accountId }

    func nonce() async throws -> AuthNonce {
        try await send(Endpoint(method: .post, path: "/v1/auth/nonce", authenticated: false))
    }

    func signInWithApple(_ request: AppleSignInRequest) async throws -> Session {
        let session: Session = try await send(.write(.post, "/v1/auth/apple", body: request, authenticated: false))
        try adopt(session)
        return session
    }

    func signOut() async {
        if let refreshToken = currentRefreshToken,
           let endpoint = try? Endpoint.write(.post, "/v1/auth/sign-out", body: RefreshRequest(refreshToken: refreshToken)) {
            // Best effort: offline or already-revoked sessions still sign out locally.
            try? await sendNoContent(endpoint)
        }
        endSession()
    }
}

final class LiveServices: AccountService, ProfileService, GymService, AvailabilityService, Sendable {
    let client: APIClient
    private let pending: PendingLiveServices

    init(client: APIClient) {
        self.client = client
        self.pending = PendingLiveServices(baseURL: client.baseURL)
    }

    var container: ServiceContainer {
        ServiceContainer(account: self, profiles: self, gyms: self, availability: self,
                         discovery: pending, invitations: pending, chats: pending, safety: pending)
    }

    // MARK: AccountService

    func me() async throws -> Me {
        try await client.send(.get("/v1/me"))
    }

    func exportData() async throws -> Data {
        try await client.sendForData(.get("/v1/me/export"))
    }

    func deleteAccount() async throws {
        try await client.sendNoContent(.write(.delete, "/v1/me", body: DeleteAccountRequest()))
        await client.endSession()
    }

    // MARK: ProfileService

    func saveProfile(_ input: ProfileInput) async throws -> OwnProfile {
        try await client.send(.write(.put, "/v1/me/profile", body: input))
    }

    func setDiscoverable(_ discoverable: Bool) async throws -> OwnProfile {
        let _: DiscoverySetting = try await client.send(.write(.put, "/v1/me/discovery", body: DiscoverySetting(discoverable: discoverable)))
        return try await client.send(.get("/v1/me/profile"))
    }

    func profile(id: EntityID) async throws -> PublicProfile {
        try await client.send(.get("/v1/profiles/\(id)"))
    }

    // MARK: GymService

    func gyms(query: String?, region: String?, cursor: String?) async throws -> Page<Gym> {
        var items = [URLQueryItem(name: "limit", value: "50")]
        if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), query.count >= 2 {
            items.append(URLQueryItem(name: "q", value: String(query.prefix(60))))
        }
        if let region { items.append(URLQueryItem(name: "region", value: region)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await client.send(.get("/v1/gyms", query: items))
    }

    func myGyms() async throws -> [GymAccess] {
        let list: ItemList<GymAccess> = try await client.send(.get("/v1/me/gyms"))
        return list.items
    }

    func setAccess(gymId: EntityID, accessType: AccessType) async throws -> GymAccess {
        try await client.send(.write(.put, "/v1/me/gyms/\(gymId)", body: GymAccessInput(accessType: accessType)))
    }

    func removeGym(gymId: EntityID) async throws {
        try await client.sendNoContent(.delete("/v1/me/gyms/\(gymId)"))
    }

    func requestGym(_ input: GymRequestInput) async throws -> GymRequest {
        try await client.send(.write(.post, "/v1/gym-requests", body: input, idempotencyKey: UUID()))
    }

    // MARK: AvailabilityService

    func slots() async throws -> [AvailabilitySlot] {
        let list: ItemList<AvailabilitySlot> = try await client.send(.get("/v1/me/availability"))
        return list.items
    }

    func addSlot(_ input: AvailabilitySlotInput) async throws -> AvailabilitySlot {
        try await client.send(.write(.post, "/v1/me/availability", body: input, idempotencyKey: UUID()))
    }

    func removeSlot(id: EntityID) async throws {
        try await client.sendNoContent(.delete("/v1/me/availability/\(id)"))
    }
}

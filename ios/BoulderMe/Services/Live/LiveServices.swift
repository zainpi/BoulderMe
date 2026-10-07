import Foundation

// The Worker-backed services: auth, account, profile, gyms and availability (T6),
// discovery, invitations, chats and safety (T7). Every route and field follows
// docs/api/openapi.yaml.

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

final class LiveServices: AccountService, ProfileService, GymService, AvailabilityService,
    DiscoveryService, InvitationService, ChatService, SafetyService, Sendable {
    let client: APIClient

    /// Page size for list routes.
    static let pageSize = 30

    init(client: APIClient) {
        self.client = client
    }

    var container: ServiceContainer {
        ServiceContainer(account: self, profiles: self, gyms: self, availability: self,
                         discovery: self, invitations: self, chats: self, safety: self)
    }

    private func paging(_ cursor: String?, limit: Int = LiveServices.pageSize) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return items
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

    // MARK: DiscoveryService

    func discover(gymId: EntityID, filter: DiscoveryFilter, cursor: String?) async throws -> Page<ProfileCard> {
        var items = [URLQueryItem(name: "gym_id", value: gymId.description)]
        if let value = filter.gradeMin { items.append(URLQueryItem(name: "grade_min", value: String(value))) }
        if let value = filter.gradeMax { items.append(URLQueryItem(name: "grade_max", value: String(value))) }
        if let value = filter.accessType { items.append(URLQueryItem(name: "access_type", value: value.rawValue)) }
        if let value = filter.weekday { items.append(URLQueryItem(name: "weekday", value: String(value.rawValue))) }
        if let value = filter.timeOfDay { items.append(URLQueryItem(name: "time_of_day", value: value.rawValue)) }
        return try await client.send(.get("/v1/discovery", query: items + paging(cursor)))
    }

    // MARK: InvitationService

    func invitations(box: InvitationBox, cursor: String?) async throws -> Page<Invitation> {
        try await client.send(.get("/v1/invitations", query: [URLQueryItem(name: "box", value: box.rawValue)] + paging(cursor)))
    }

    func invitation(id: EntityID) async throws -> Invitation {
        try await client.send(.get("/v1/invitations/\(id)"))
    }

    func create(_ input: InvitationInput, idempotencyKey: UUID) async throws -> Invitation {
        try await client.send(.write(.post, "/v1/invitations", body: input, idempotencyKey: idempotencyKey))
    }

    func accept(id: EntityID) async throws -> Invitation {
        try await client.send(Endpoint(method: .post, path: "/v1/invitations/\(id)/accept"))
    }

    func decline(id: EntityID) async throws -> Invitation {
        try await client.send(Endpoint(method: .post, path: "/v1/invitations/\(id)/decline"))
    }

    func cancel(id: EntityID) async throws -> Invitation {
        try await client.send(Endpoint(method: .post, path: "/v1/invitations/\(id)/cancel"))
    }

    // MARK: ChatService

    func chats(cursor: String?) async throws -> Page<Chat> {
        try await client.send(.get("/v1/chats", query: paging(cursor)))
    }

    func chat(id: EntityID) async throws -> Chat {
        try await client.send(.get("/v1/chats/\(id)"))
    }

    func messages(chatId: EntityID, after: EntityID?, cursor: String?) async throws -> Page<Message> {
        var items = [URLQueryItem(name: "limit", value: "50")]
        // `after` and `cursor` can't be combined (polling vs. paging back).
        if let after {
            items.append(URLQueryItem(name: "after", value: after.description))
        } else if let cursor {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await client.send(.get("/v1/chats/\(chatId)/messages", query: items))
    }

    func send(chatId: EntityID, body: String, idempotencyKey: UUID) async throws -> Message {
        try await client.send(.write(.post, "/v1/chats/\(chatId)/messages", body: MessageInput(body: body),
                                     idempotencyKey: idempotencyKey))
    }

    // MARK: SafetyService

    func blocks(cursor: String?) async throws -> Page<Block> {
        try await client.send(.get("/v1/blocks", query: paging(cursor)))
    }

    func block(accountId: EntityID) async throws -> Block {
        try await client.send(Endpoint(method: .put, path: "/v1/blocks/\(accountId)"))
    }

    func unblock(accountId: EntityID) async throws {
        try await client.sendNoContent(.delete("/v1/blocks/\(accountId)"))
    }

    func report(_ input: ReportInput, idempotencyKey: UUID) async throws -> Report {
        try await client.send(.write(.post, "/v1/reports", body: input, idempotencyKey: idempotencyKey))
    }
}

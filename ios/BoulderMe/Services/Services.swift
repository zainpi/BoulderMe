import Foundation

// Protocol services, one per area of docs/api/openapi.yaml. Screens only talk to
// these protocols; the composition root (`AppModel.live`) picks demo fixtures or
// the live Worker client (`LiveServices`). Live implementations: T6 (account, profile,
// gyms, availability) and T7 (discovery, invitations, chats, safety).

/// Sign in with Apple and the stored session. Not part of `ServiceContainer`:
/// demo mode has no session, so only `AppModel` talks to it.
protocol AuthService: Sendable {
    /// The account with a stored session, if any.
    func storedAccountId() async -> EntityID?
    func nonce() async throws -> AuthNonce
    func signInWithApple(_ request: AppleSignInRequest) async throws -> Session
    /// Revokes the session on the server when reachable; always forgets it locally.
    func signOut() async
    /// Emits when the server ends the session without the member asking.
    var sessionEnded: AsyncStream<SessionEndReason> { get }
}

protocol AccountService: Sendable {
    func me() async throws -> Me
    func exportData() async throws -> Data
    /// Deletes the account and forgets the session on this device.
    func deleteAccount() async throws
}

protocol ProfileService: Sendable {
    func saveProfile(_ input: ProfileInput) async throws -> OwnProfile
    func setDiscoverable(_ discoverable: Bool) async throws -> OwnProfile
    func profile(id: EntityID) async throws -> PublicProfile
}

protocol GymService: Sendable {
    func gyms(query: String?, region: String?, cursor: String?) async throws -> Page<Gym>
    func myGyms() async throws -> [GymAccess]
    func setAccess(gymId: EntityID, accessType: AccessType) async throws -> GymAccess
    func removeGym(gymId: EntityID) async throws
    func requestGym(_ input: GymRequestInput) async throws -> GymRequest
}

protocol AvailabilityService: Sendable {
    func slots() async throws -> [AvailabilitySlot]
    func addSlot(_ input: AvailabilitySlotInput) async throws -> AvailabilitySlot
    func removeSlot(id: EntityID) async throws
}

protocol DiscoveryService: Sendable {
    func discover(gymId: EntityID, filter: DiscoveryFilter, cursor: String?) async throws -> Page<ProfileCard>
}

protocol InvitationService: Sendable {
    /// Newest first, all statuses.
    func invitations(box: InvitationBox, cursor: String?) async throws -> Page<Invitation>
    func invitation(id: EntityID) async throws -> Invitation
    func create(_ input: InvitationInput, idempotencyKey: UUID) async throws -> Invitation
    func accept(id: EntityID) async throws -> Invitation
    func decline(id: EntityID) async throws -> Invitation
    func cancel(id: EntityID) async throws -> Invitation
}

protocol ChatService: Sendable {
    func chats(cursor: String?) async throws -> Page<Chat>
    func chat(id: EntityID) async throws -> Chat
    /// Without `after`: newest first, paged back with `cursor`. With `after`: newer only, oldest first.
    func messages(chatId: EntityID, after: EntityID?, cursor: String?) async throws -> Page<Message>
    func send(chatId: EntityID, body: String, idempotencyKey: UUID) async throws -> Message
}

protocol SafetyService: Sendable {
    func blocks(cursor: String?) async throws -> Page<Block>
    func block(accountId: EntityID) async throws -> Block
    func unblock(accountId: EntityID) async throws
    func report(_ input: ReportInput, idempotencyKey: UUID) async throws -> Report
}

/// Everything a screen can depend on, built once by the composition root.
struct ServiceContainer: Sendable {
    var account: any AccountService
    var profiles: any ProfileService
    var gyms: any GymService
    var availability: any AvailabilityService
    var discovery: any DiscoveryService
    var invitations: any InvitationService
    var chats: any ChatService
    var safety: any SafetyService
}

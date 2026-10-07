import Foundation

/// A container where every call throws `AppError.notImplemented`. Used by
/// SwiftUI previews and tests that must never reach the network.
final class PendingLiveServices: AccountService, ProfileService, GymService, AvailabilityService,
    DiscoveryService, InvitationService, ChatService, SafetyService, @unchecked Sendable {
    let baseURL: URL

    init(baseURL: URL) { self.baseURL = baseURL }

    var container: ServiceContainer {
        ServiceContainer(account: self, profiles: self, gyms: self, availability: self,
                         discovery: self, invitations: self, chats: self, safety: self)
    }

    private func pending<T>() throws -> T { throw AppError.notImplemented }

    func me() async throws -> Me { try pending() }
    func exportData() async throws -> Data { try pending() }
    func deleteAccount() async throws { throw AppError.notImplemented }

    func saveProfile(_ input: ProfileInput) async throws -> OwnProfile { try pending() }
    func setDiscoverable(_ discoverable: Bool) async throws -> OwnProfile { try pending() }
    func profile(id: EntityID) async throws -> PublicProfile { try pending() }

    func gyms(query: String?, region: String?, cursor: String?) async throws -> Page<Gym> { try pending() }
    func myGyms() async throws -> [GymAccess] { try pending() }
    func setAccess(gymId: EntityID, accessType: AccessType) async throws -> GymAccess { try pending() }
    func removeGym(gymId: EntityID) async throws { throw AppError.notImplemented }
    func requestGym(_ input: GymRequestInput) async throws -> GymRequest { try pending() }

    func slots() async throws -> [AvailabilitySlot] { try pending() }
    func addSlot(_ input: AvailabilitySlotInput) async throws -> AvailabilitySlot { try pending() }
    func removeSlot(id: EntityID) async throws { throw AppError.notImplemented }

    func discover(gymId: EntityID, filter: DiscoveryFilter, cursor: String?) async throws -> Page<ProfileCard> { try pending() }

    func invitations(box: InvitationBox, cursor: String?) async throws -> Page<Invitation> { try pending() }
    func invitation(id: EntityID) async throws -> Invitation { try pending() }
    func create(_ input: InvitationInput, idempotencyKey: UUID) async throws -> Invitation { try pending() }
    func accept(id: EntityID) async throws -> Invitation { try pending() }
    func decline(id: EntityID) async throws -> Invitation { try pending() }
    func cancel(id: EntityID) async throws -> Invitation { try pending() }

    func chats(cursor: String?) async throws -> Page<Chat> { try pending() }
    func chat(id: EntityID) async throws -> Chat { try pending() }
    func messages(chatId: EntityID, after: EntityID?, cursor: String?) async throws -> Page<Message> { try pending() }
    func send(chatId: EntityID, body: String, idempotencyKey: UUID) async throws -> Message { try pending() }

    func blocks(cursor: String?) async throws -> Page<Block> { try pending() }
    func block(accountId: EntityID) async throws -> Block { try pending() }
    func unblock(accountId: EntityID) async throws { throw AppError.notImplemented }
    func report(_ input: ReportInput, idempotencyKey: UUID) async throws -> Report { try pending() }
}

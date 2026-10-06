import Foundation

/// In-memory backend for demo mode. Implements every service protocol against
/// `DemoFixtures`, applying the same core rules as the Worker (blocks hide both
/// ways, one pending invite per pair, chat only after acceptance) so the UI can
/// be exercised end to end without an account. State resets on every launch.
actor DemoBackend: AccountService, ProfileService, GymService, AvailabilityService,
    DiscoveryService, InvitationService, ChatService, SafetyService {
    private let now: @Sendable () -> Date
    private var ownProfile: OwnProfile
    private var ownGyms: [GymAccess]
    private var ownSlots: [AvailabilitySlot]
    private var climbers: [EntityID: DemoFixtures.Climber]
    private var invitationStore: [Invitation] = []
    private var chatStore: [Chat] = []
    private var messageStore: [EntityID: [Message]] = [:]
    private var blockStore: [Block] = []
    private var nextNumber = 5000

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        let start = now()
        ownProfile = DemoFixtures.me(now: start)
        ownGyms = DemoFixtures.myGyms(now: start)
        ownSlots = DemoFixtures.mySlots()
        let seededClimbers = Dictionary(uniqueKeysWithValues: DemoFixtures.climbers(now: start).map { ($0.profile.accountId, $0) })
        climbers = seededClimbers
        let seed = Self.seedConversations(at: start, me: DemoFixtures.me(now: start), climbers: seededClimbers)
        invitationStore = seed.invitations
        chatStore = seed.chats
        messageStore = seed.messages
    }

    nonisolated var container: ServiceContainer {
        ServiceContainer(account: self, profiles: self, gyms: self, availability: self,
                         discovery: self, invitations: self, chats: self, safety: self)
    }

    // MARK: Seed

    private static func seedConversations(
        at start: Date, me: OwnProfile, climbers: [EntityID: DemoFixtures.Climber]
    ) -> (invitations: [Invitation], chats: [Chat], messages: [EntityID: [Message]]) {
        func party(_ id: EntityID) -> InvitationParty {
            let profile = climbers[id]!.profile
            return InvitationParty(accountId: id, displayName: profile.displayName,
                                   gradeMin: profile.gradeMin, gradeMax: profile.gradeMax)
        }
        let maya = party(DemoFixtures.id(11))
        let theo = party(DemoFixtures.id(12))
        let priya = party(DemoFixtures.id(13))
        let mePartyValue = InvitationParty(accountId: me.accountId, displayName: me.displayName,
                                           gradeMin: me.gradeMin, gradeMax: me.gradeMax)
        var invitations: [Invitation] = []
        var messages: [EntityID: [Message]] = [:]

        invitations.append(Invitation(
            invitationId: DemoFixtures.id(301), status: .pending, sender: maya, recipient: mePartyValue,
            gym: DemoFixtures.cozyCrimp, proposedStartAt: start.addingTimeInterval(2 * 86_400),
            durationMinutes: 120, note: "Want to try the new slab set on Tuesday?", chatId: nil,
            createdAt: start.addingTimeInterval(-3_600), respondedAt: nil,
            expiresAt: start.addingTimeInterval(2 * 86_400)))
        invitations.append(Invitation(
            invitationId: DemoFixtures.id(302), status: .pending, sender: mePartyValue, recipient: priya,
            gym: DemoFixtures.cozyCrimp, proposedStartAt: start.addingTimeInterval(4 * 86_400),
            durationMinutes: 90, note: nil, chatId: nil,
            createdAt: start.addingTimeInterval(-7_200), respondedAt: nil,
            expiresAt: start.addingTimeInterval(4 * 86_400)))

        let chatId = DemoFixtures.id(401)
        let accepted = Invitation(
            invitationId: DemoFixtures.id(303), status: .accepted, sender: theo, recipient: mePartyValue,
            gym: DemoFixtures.cozyCrimp, proposedStartAt: start.addingTimeInterval(86_400),
            durationMinutes: 120, note: "Cave session?", chatId: chatId,
            createdAt: start.addingTimeInterval(-86_400), respondedAt: start.addingTimeInterval(-80_000),
            expiresAt: start.addingTimeInterval(86_400))
        invitations.append(accepted)
        let lines: [(EntityID, String, TimeInterval)] = [
            (theo.accountId, "Hey! Thanks for accepting 🙌", -79_000),
            (DemoFixtures.meId, "Of course! I've been eyeing that purple V5.", -78_000),
            (theo.accountId, "Bring tape, it's crimpy at the lip. See you at 6?", -3_000),
        ]
        messages[chatId] = lines.enumerated().map { index, line in
            Message(messageId: DemoFixtures.id(501 + index), chatId: chatId, senderAccountId: line.0,
                    body: line.1, createdAt: start.addingTimeInterval(line.2))
        }
        let chat = Chat(
            chatId: chatId, otherMember: theo, status: .open, lastMessage: messages[chatId]?.last,
            unreadCount: 1, upcomingSession: accepted, createdAt: start.addingTimeInterval(-80_000),
            updatedAt: start.addingTimeInterval(-3_000))
        return (invitations, [chat], messages)
    }

    // MARK: Helpers

    private func newId() -> EntityID {
        nextNumber += 1
        return DemoFixtures.id(nextNumber)
    }

    private var meParty: InvitationParty {
        InvitationParty(accountId: ownProfile.accountId, displayName: ownProfile.displayName, gradeMin: ownProfile.gradeMin, gradeMax: ownProfile.gradeMax)
    }

    private func party(_ id: EntityID) -> InvitationParty {
        let profile = climbers[id]!.profile
        return InvitationParty(accountId: id, displayName: profile.displayName,
                               gradeMin: profile.gradeMin, gradeMax: profile.gradeMax)
    }

    private func isBlocked(_ id: EntityID) -> Bool {
        blockStore.contains { $0.blockedAccountId == id }
    }

    private func sharesInviteOrChat(_ id: EntityID) -> Bool {
        invitationStore.contains { $0.sender.accountId == id || $0.recipient.accountId == id }
            || chatStore.contains { $0.otherMember.accountId == id }
    }

    /// Pending invitations past their start are expired on read, like the Worker.
    private func expireStale() {
        let current = now()
        for index in invitationStore.indices where invitationStore[index].status == .pending && invitationStore[index].expiresAt <= current {
            invitationStore[index].status = .expired
        }
    }

    private func invitationIndex(_ id: EntityID) throws -> Int {
        expireStale()
        guard let index = invitationStore.firstIndex(where: { $0.invitationId == id }) else {
            throw AppError.api(.notFound, requestId: nil)
        }
        return index
    }

    // MARK: AccountService

    func me() async throws -> Me {
        expireStale()
        let pendingIncoming = invitationStore.filter { $0.status == .pending && $0.recipient.accountId == ownProfile.accountId }.count
        return Me(
            accountId: ownProfile.accountId, createdAt: ownProfile.updatedAt, profile: ownProfile, gyms: ownGyms,
            onboarding: OnboardingState(hasProfile: true, hasGym: !ownGyms.isEmpty, hasAvailability: !ownSlots.isEmpty,
                                        adultConfirmed: true, discoveryExplained: true),
            unreadChatCount: chatStore.reduce(0) { $0 + $1.unreadCount },
            pendingIncomingInvitationCount: pendingIncoming)
    }

    func exportData() async throws -> Data { throw AppError.requiresAccount }
    func deleteAccount() async throws { throw AppError.requiresAccount }

    // MARK: ProfileService

    func saveProfile(_ input: ProfileInput) async throws -> OwnProfile {
        guard input.revision == ownProfile.revision else { throw AppError.api(.revisionConflict, requestId: nil) }
        ownProfile.displayName = input.displayName
        ownProfile.gradeMin = input.gradeMin
        ownProfile.gradeMax = input.gradeMax
        ownProfile.styles = input.styles
        ownProfile.intro = input.intro
        ownProfile.revision += 1
        ownProfile.updatedAt = now()
        return ownProfile
    }

    func setDiscoverable(_ discoverable: Bool) async throws -> OwnProfile {
        ownProfile.discoverable = discoverable
        return ownProfile
    }

    func profile(id: EntityID) async throws -> PublicProfile {
        guard let climber = climbers[id], !isBlocked(id), climber.discoverable || sharesInviteOrChat(id) else {
            throw AppError.api(.notFound, requestId: nil)
        }
        return climber.profile
    }

    // MARK: GymService

    func gyms(query: String?, region: String?, cursor: String?) async throws -> Page<Gym> {
        var result = DemoFixtures.gyms
        if let query = query?.trimmingCharacters(in: .whitespaces), query.count >= 2 {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.city.localizedCaseInsensitiveContains(query) }
        }
        if let region { result = result.filter { $0.region == region } }
        return Page(items: result)
    }

    func myGyms() async throws -> [GymAccess] { ownGyms }

    func setAccess(gymId: EntityID, accessType: AccessType) async throws -> GymAccess {
        guard let gym = DemoFixtures.gyms.first(where: { $0.gymId == gymId }) else {
            throw AppError.api(.notFound, requestId: nil)
        }
        let access = GymAccess(gym: gym, accessType: accessType, selfReported: true, updatedAt: now())
        if let index = ownGyms.firstIndex(where: { $0.gym.gymId == gymId }) {
            ownGyms[index] = access
        } else {
            guard ownGyms.count < 10 else { throw AppError.api(.gymLimitReached, requestId: nil) }
            ownGyms.append(access)
        }
        return access
    }

    func removeGym(gymId: EntityID) async throws {
        ownGyms.removeAll { $0.gym.gymId == gymId }
    }

    func requestGym(_ input: GymRequestInput) async throws -> GymRequest {
        GymRequest(gymRequestId: newId(), name: input.name, city: input.city, region: input.region,
                   status: .submitted, createdAt: now())
    }

    // MARK: AvailabilityService

    func slots() async throws -> [AvailabilitySlot] { ownSlots }

    func addSlot(_ input: AvailabilitySlotInput) async throws -> AvailabilitySlot {
        guard ownSlots.count < 21 else { throw AppError.api(.availabilityLimitReached, requestId: nil) }
        guard input.startMinute % 30 == 0, input.endMinute % 30 == 0, input.endMinute - input.startMinute >= 30 else {
            throw AppError.api(.validationFailed, requestId: nil)
        }
        let slot = AvailabilitySlot(slotId: newId(), weekday: input.weekday, startMinute: input.startMinute,
                                    endMinute: input.endMinute, timeZone: input.timeZone, gymId: input.gymId)
        ownSlots.append(slot)
        return slot
    }

    func removeSlot(id: EntityID) async throws {
        ownSlots.removeAll { $0.slotId == id }
    }

    // MARK: DiscoveryService

    func discover(gymId: EntityID, filter: DiscoveryFilter, cursor: String?) async throws -> Page<ProfileCard> {
        guard DemoFixtures.gyms.contains(where: { $0.gymId == gymId }) else {
            throw AppError.api(.notFound, requestId: nil)
        }
        let cards = climbers.values
            .filter { $0.discoverable && !isBlocked($0.profile.accountId) }
            .compactMap { climber -> ProfileCard? in
                let profile = climber.profile
                guard let access = profile.gyms.first(where: { $0.gym.gymId == gymId }) else { return nil }
                if let min = filter.gradeMin, profile.gradeMax < min { return nil }
                if let max = filter.gradeMax, profile.gradeMin > max { return nil }
                if let type = filter.accessType, access.accessType != type { return nil }
                let slots = profile.availability.filter { slot in
                    (filter.weekday == nil || slot.weekday == filter.weekday)
                        && (filter.timeOfDay == nil || slot.timeOfDay == filter.timeOfDay)
                }
                if (filter.weekday != nil || filter.timeOfDay != nil) && slots.isEmpty { return nil }
                return ProfileCard(
                    accountId: profile.accountId, displayName: profile.displayName,
                    gradeMin: profile.gradeMin, gradeMax: profile.gradeMax, styles: profile.styles,
                    accessType: access.accessType,
                    availabilitySummary: profile.availability.map { AvailabilitySummaryItem(weekday: $0.weekday, timeOfDay: $0.timeOfDay) },
                    activeRecently: profile.activeRecently)
            }
        let ownRange = ownProfile.gradeMin...ownProfile.gradeMax
        func overlap(_ card: ProfileCard) -> Int {
            let range = card.gradeMin...card.gradeMax
            return ownRange.overlaps(range) ? min(ownRange.upperBound, range.upperBound) - max(ownRange.lowerBound, range.lowerBound) + 1 : 0
        }
        return Page(items: cards.sorted {
            (overlap($0), $0.activeRecently ? 1 : 0, $1.displayName) > (overlap($1), $1.activeRecently ? 1 : 0, $0.displayName)
        })
    }

    // MARK: InvitationService

    func invitations(box: InvitationBox, cursor: String?) async throws -> Page<Invitation> {
        expireStale()
        let items = invitationStore
            .filter { box == .incoming ? $0.recipient.accountId == ownProfile.accountId : $0.sender.accountId == ownProfile.accountId }
            .sorted { $0.proposedStartAt < $1.proposedStartAt }
        return Page(items: items)
    }

    func invitation(id: EntityID) async throws -> Invitation {
        invitationStore[try invitationIndex(id)]
    }

    func create(_ input: InvitationInput, idempotencyKey: UUID) async throws -> Invitation {
        let recipientId = input.recipientAccountId
        guard let climber = climbers[recipientId], !isBlocked(recipientId) else {
            throw AppError.api(.notFound, requestId: nil)
        }
        guard ownGyms.contains(where: { $0.gym.gymId == input.gymId }),
              let gym = climber.profile.gyms.first(where: { $0.gym.gymId == input.gymId })?.gym else {
            throw AppError.api(.gymNotShared, requestId: nil)
        }
        let start = now()
        guard input.proposedStartAt >= start.addingTimeInterval(3_600),
              input.proposedStartAt <= start.addingTimeInterval(60 * 86_400) else {
            throw AppError.api(.invalidTime, requestId: nil)
        }
        expireStale()
        let open = invitationStore.contains {
            $0.status == .pending && Set([$0.sender.accountId, $0.recipient.accountId]) == Set([ownProfile.accountId, recipientId])
        }
        guard !open else { throw AppError.api(.invitationAlreadyOpen, requestId: nil) }
        let invitation = Invitation(
            invitationId: newId(), status: .pending, sender: meParty, recipient: party(recipientId), gym: gym,
            proposedStartAt: input.proposedStartAt, durationMinutes: input.durationMinutes, note: input.note,
            chatId: nil, createdAt: start, respondedAt: nil, expiresAt: input.proposedStartAt)
        invitationStore.append(invitation)
        return invitation
    }

    func accept(id: EntityID) async throws -> Invitation {
        let index = try invitationIndex(id)
        var invitation = invitationStore[index]
        guard invitation.recipient.accountId == ownProfile.accountId else { throw AppError.api(.forbidden, requestId: nil) }
        guard invitation.status == .pending else { throw AppError.api(.invalidState, requestId: nil) }
        let other = invitation.sender
        let start = now()
        let chatId: EntityID
        if let chatIndex = chatStore.firstIndex(where: { $0.otherMember.accountId == other.accountId }) {
            chatId = chatStore[chatIndex].chatId
            chatStore[chatIndex].status = .open
            chatStore[chatIndex].upcomingSession = invitation
        } else {
            chatId = newId()
            chatStore.append(Chat(chatId: chatId, otherMember: other, status: .open, lastMessage: nil, unreadCount: 0,
                              upcomingSession: nil, createdAt: start, updatedAt: start))
        }
        invitation.status = .accepted
        invitation.respondedAt = start
        invitation.chatId = chatId
        invitationStore[index] = invitation
        if let chatIndex = chatStore.firstIndex(where: { $0.chatId == chatId }) {
            chatStore[chatIndex].upcomingSession = invitation
        }
        return invitation
    }

    func decline(id: EntityID) async throws -> Invitation {
        let index = try invitationIndex(id)
        guard invitationStore[index].recipient.accountId == ownProfile.accountId else { throw AppError.api(.forbidden, requestId: nil) }
        guard invitationStore[index].status == .pending else { throw AppError.api(.invalidState, requestId: nil) }
        invitationStore[index].status = .declined
        invitationStore[index].respondedAt = now()
        return invitationStore[index]
    }

    func cancel(id: EntityID) async throws -> Invitation {
        let index = try invitationIndex(id)
        let invitation = invitationStore[index]
        let canCancel = invitation.status == .accepted
            || (invitation.status == .pending && invitation.sender.accountId == ownProfile.accountId)
        guard canCancel else { throw AppError.api(.invalidState, requestId: nil) }
        invitationStore[index].status = .cancelled
        invitationStore[index].respondedAt = now()
        return invitationStore[index]
    }

    // MARK: ChatService

    func chats(cursor: String?) async throws -> Page<Chat> {
        Page(items: chatStore.sorted { $0.updatedAt > $1.updatedAt })
    }

    func chat(id: EntityID) async throws -> Chat {
        guard let chat = chatStore.first(where: { $0.chatId == id }) else { throw AppError.api(.notFound, requestId: nil) }
        return chat
    }

    func messages(chatId: EntityID, after: EntityID?, cursor: String?) async throws -> Page<Message> {
        guard let index = chatStore.firstIndex(where: { $0.chatId == chatId }) else {
            throw AppError.api(.notFound, requestId: nil)
        }
        chatStore[index].unreadCount = 0
        let all = messageStore[chatId] ?? []
        if let after {
            guard let position = all.firstIndex(where: { $0.messageId == after }) else { return Page(items: []) }
            return Page(items: Array(all[(position + 1)...]))
        }
        return Page(items: all.reversed())
    }

    func send(chatId: EntityID, body: String, idempotencyKey: UUID) async throws -> Message {
        guard let index = chatStore.firstIndex(where: { $0.chatId == chatId }) else {
            throw AppError.api(.notFound, requestId: nil)
        }
        guard chatStore[index].status == .open else { throw AppError.api(.chatClosed, requestId: nil) }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1000 else { throw AppError.api(.validationFailed, requestId: nil) }
        let message = Message(messageId: newId(), chatId: chatId, senderAccountId: ownProfile.accountId, body: trimmed, createdAt: now())
        messageStore[chatId, default: []].append(message)
        chatStore[index].lastMessage = message
        chatStore[index].updatedAt = message.createdAt
        return message
    }

    // MARK: SafetyService

    func blocks(cursor: String?) async throws -> Page<Block> { Page(items: blockStore) }

    func block(accountId: EntityID) async throws -> Block {
        guard let climber = climbers[accountId] else { throw AppError.api(.notFound, requestId: nil) }
        if let existing = blockStore.first(where: { $0.blockedAccountId == accountId }) { return existing }
        let block = Block(blockedAccountId: accountId, displayName: climber.profile.displayName, createdAt: now())
        blockStore.append(block)
        // Same effects as the Worker: cancel open invites and close the chat.
        for index in invitationStore.indices {
            let pair = Set([invitationStore[index].sender.accountId, invitationStore[index].recipient.accountId])
            if pair.contains(accountId), [.pending, .accepted].contains(invitationStore[index].status) {
                invitationStore[index].status = .cancelled
            }
        }
        for index in chatStore.indices where chatStore[index].otherMember.accountId == accountId {
            chatStore[index].status = .closed
            chatStore[index].upcomingSession = nil
        }
        return block
    }

    func unblock(accountId: EntityID) async throws {
        blockStore.removeAll { $0.blockedAccountId == accountId }
    }

    func report(_ input: ReportInput) async throws -> Report {
        Report(reportId: newId(), reportedAccountId: input.reportedAccountId, context: input.context,
               reason: input.reason.rawValue, status: .open, createdAt: now())
    }
}

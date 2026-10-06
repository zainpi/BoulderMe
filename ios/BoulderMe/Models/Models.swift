import Foundation

// DTOs mirroring the schemas in docs/api/openapi.yaml. Property names are the
// camelCase form of the wire names, so keep `Id` (not `ID`) suffixes for
// snake_case conversion to round-trip.

// MARK: Account

struct OnboardingState: Codable, Hashable, Sendable {
    var hasProfile: Bool
    var hasGym: Bool
    var hasAvailability: Bool
    var adultConfirmed: Bool
    var discoveryExplained: Bool
}

struct Me: Codable, Hashable, Sendable {
    var accountId: EntityID
    var createdAt: Date
    var profile: OwnProfile?
    var gyms: [GymAccess]
    var onboarding: OnboardingState
    var unreadChatCount: Int
    var pendingIncomingInvitationCount: Int
}

// MARK: Profiles

struct ProfileInput: Codable, Hashable, Sendable {
    var revision: Int
    var displayName: String
    var gradeMin: Grade
    var gradeMax: Grade
    var styles: [ClimbingStyle]
    var intro: String?
    var adultConfirmed: Bool
    var discoveryExplained: Bool

    // `intro` is required but nullable, so encode `null` instead of omitting it.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(gradeMin, forKey: .gradeMin)
        try container.encode(gradeMax, forKey: .gradeMax)
        try container.encode(styles, forKey: .styles)
        try container.encode(intro, forKey: .intro)
        try container.encode(adultConfirmed, forKey: .adultConfirmed)
        try container.encode(discoveryExplained, forKey: .discoveryExplained)
    }
}

struct OwnProfile: Codable, Hashable, Sendable {
    var accountId: EntityID
    var revision: Int
    var displayName: String
    var gradeMin: Grade
    var gradeMax: Grade
    var styles: [ClimbingStyle]
    var intro: String?
    var discoverable: Bool
    var adultConfirmed: Bool
    var discoveryExplained: Bool
    var updatedAt: Date
}

struct AvailabilitySummaryItem: Codable, Hashable, Sendable {
    var weekday: Weekday
    var timeOfDay: TimeOfDay
}

/// What discovery shows. Everything here is visible to every signed-in member.
struct ProfileCard: Codable, Hashable, Sendable, Identifiable {
    var accountId: EntityID
    var displayName: String
    var gradeMin: Grade
    var gradeMax: Grade
    var styles: [ClimbingStyle]
    var accessType: AccessType
    var availabilitySummary: [AvailabilitySummaryItem]
    var activeRecently: Bool

    var id: EntityID { accountId }
}

struct PublicProfile: Codable, Hashable, Sendable, Identifiable {
    var accountId: EntityID
    var displayName: String
    var gradeMin: Grade
    var gradeMax: Grade
    var styles: [ClimbingStyle]
    var intro: String?
    var gyms: [GymAccess]
    var availability: [AvailabilitySlot]
    var activeRecently: Bool

    var id: EntityID { accountId }
}

// MARK: Gyms

struct Gym: Codable, Hashable, Sendable, Identifiable {
    var gymId: EntityID
    var name: String
    var city: String
    var region: String
    var country: String
    var address: String?
    var websiteUrl: URL?
    var isBoulderingOnly: Bool

    var id: EntityID { gymId }
}

struct GymAccess: Codable, Hashable, Sendable, Identifiable {
    var gym: Gym
    var accessType: AccessType
    /// Always `true`: access is self-reported and never verified.
    var selfReported: Bool
    var updatedAt: Date

    var id: EntityID { gym.gymId }
}

struct GymRequestInput: Codable, Hashable, Sendable {
    var name: String
    var city: String
    var region: String
    var websiteUrl: URL?
    var note: String?
}

struct GymRequest: Codable, Hashable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable { case submitted, added, rejected }
    var gymRequestId: EntityID
    var name: String
    var city: String
    var region: String
    var status: Status
    var createdAt: Date

    var id: EntityID { gymRequestId }
}

// MARK: Availability

struct AvailabilitySlotInput: Codable, Hashable, Sendable {
    var weekday: Weekday
    var startMinute: Int
    var endMinute: Int
    var timeZone: String
    var gymId: EntityID?
}

struct AvailabilitySlot: Codable, Hashable, Sendable, Identifiable {
    var slotId: EntityID
    var weekday: Weekday
    var startMinute: Int
    var endMinute: Int
    var timeZone: String
    var gymId: EntityID?

    var id: EntityID { slotId }

    var timeOfDay: TimeOfDay {
        switch startMinute {
        case ..<720: .morning
        case ..<1020: .afternoon
        default: .evening
        }
    }
}

// MARK: Invitations

enum InvitationStatus: String, Codable, CaseIterable, Sendable {
    case pending, accepted, declined, cancelled, expired
}

enum InvitationBox: String, Codable, CaseIterable, Sendable, Identifiable {
    case incoming, outgoing
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct InvitationInput: Codable, Hashable, Sendable {
    var recipientAccountId: EntityID
    var gymId: EntityID
    var proposedStartAt: Date
    var durationMinutes: Int = 120
    var note: String?
}

struct InvitationParty: Codable, Hashable, Sendable {
    var accountId: EntityID
    var displayName: String
    var gradeMin: Grade
    var gradeMax: Grade
}

struct Invitation: Codable, Hashable, Sendable, Identifiable {
    var invitationId: EntityID
    var status: InvitationStatus
    var sender: InvitationParty
    var recipient: InvitationParty
    var gym: Gym
    var proposedStartAt: Date
    var durationMinutes: Int
    var note: String?
    var chatId: EntityID?
    var createdAt: Date
    var respondedAt: Date?
    var expiresAt: Date

    var id: EntityID { invitationId }
}

// MARK: Chats

struct Chat: Codable, Hashable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable { case open, closed }
    var chatId: EntityID
    var otherMember: InvitationParty
    var status: Status
    var lastMessage: Message?
    var unreadCount: Int
    var upcomingSession: Invitation?
    var createdAt: Date
    var updatedAt: Date

    var id: EntityID { chatId }
}

struct MessageInput: Codable, Hashable, Sendable {
    var body: String
}

struct Message: Codable, Hashable, Sendable, Identifiable {
    var messageId: EntityID
    var chatId: EntityID
    /// `nil` when the sender has deleted their account.
    var senderAccountId: EntityID?
    var body: String
    var createdAt: Date

    var id: EntityID { messageId }
}

// MARK: Safety

struct Block: Codable, Hashable, Sendable, Identifiable {
    var blockedAccountId: EntityID
    var displayName: String
    var createdAt: Date

    var id: EntityID { blockedAccountId }
}

enum ReportContext: String, Codable, Sendable { case profile, invitation, message }

enum ReportReason: String, Codable, CaseIterable, Sendable, Identifiable {
    case harassment
    case inappropriateContent = "inappropriate_content"
    case spam
    case fakeProfile = "fake_profile"
    case safetyConcern = "safety_concern"
    case underage
    case other
    var id: String { rawValue }
}

struct ReportInput: Codable, Hashable, Sendable {
    var reportedAccountId: EntityID
    var context: ReportContext
    var invitationId: EntityID?
    var messageId: EntityID?
    var reason: ReportReason
    var details: String?
}

struct Report: Codable, Hashable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable { case open, reviewing, actioned, dismissed }
    var reportId: EntityID
    var reportedAccountId: EntityID
    var context: ReportContext
    var reason: String
    var status: Status
    var createdAt: Date

    var id: EntityID { reportId }
}

// MARK: Discovery

struct DiscoveryFilter: Hashable, Sendable, Codable {
    var gradeMin: Grade?
    var gradeMax: Grade?
    var accessType: AccessType?
    var weekday: Weekday?
    var timeOfDay: TimeOfDay?

    static let any = DiscoveryFilter()
    var isActive: Bool { self != .any }
}

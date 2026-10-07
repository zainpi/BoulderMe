import Observation
import SwiftUI

enum AppTab: String, CaseIterable, Hashable, Identifiable {
    case discover, invites, chats, profile
    var id: String { rawValue }

    var title: String {
        switch self {
        case .discover: "Discover"
        case .invites: "Invites"
        case .chats: "Chats"
        case .profile: "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .discover: "figure.climbing"
        case .invites: "envelope.open.fill"
        case .chats: "bubble.left.and.bubble.right.fill"
        case .profile: "person.crop.circle.fill"
        }
    }
}

// Typed routes, one enum per tab's NavigationStack (docs/screen-map.md).

enum DiscoverRoute: Hashable {
    case profile(EntityID)
}

enum InvitesRoute: Hashable {
    case invitation(EntityID)
    case profile(EntityID)
}

enum ChatsRoute: Hashable {
    case chat(EntityID)
    case profile(EntityID)
}

enum ProfileRoute: Hashable {
    case settings
    case designSystem
}

/// Sheets that can open from several places.
enum AppSheet: Identifiable, Hashable {
    case safetyTips
    /// A demo user tapped something that needs a real account.
    case signInRequired

    var id: Self { self }
}

/// Owns tab selection and every tab's path. Paths survive tab switches, and a
/// reset (sign-out, leaving demo) clears them all.
@MainActor
@Observable
final class Router {
    var selectedTab: AppTab = .discover
    var discover: [DiscoverRoute] = []
    var invites: [InvitesRoute] = []
    var chats: [ChatsRoute] = []
    var profile: [ProfileRoute] = []
    var sheet: AppSheet?

    func reset() {
        selectedTab = .discover
        discover = []
        invites = []
        chats = []
        profile = []
        sheet = nil
    }

    /// Jump to a chat from anywhere (e.g. after accepting an invite).
    func openChat(_ chatId: EntityID) {
        chats = [.chat(chatId)]
        selectedTab = .chats
    }
}

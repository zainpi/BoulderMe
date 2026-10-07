import SwiftUI

/// Switches between Welcome and the main tabs, and hosts app-wide sheets.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var router = app.router
        Group {
            switch app.mode {
            case .launching:
                LaunchView()
                    .transition(.opacity)
            case .welcome:
                WelcomeView()
                    .transition(.opacity)
            case .onboarding:
                if let onboarding = app.onboarding {
                    OnboardingView(model: onboarding)
                        .transition(.opacity)
                }
            case .demo, .account:
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.mode)
        .sheet(item: $router.sheet) { sheet in
            switch sheet {
            case .safetyTips:
                SafetyTipsSheet()
            case .signInRequired:
                SignInRequiredSheet()
            }
        }
    }
}

/// Shown for the moment it takes to restore a stored session.
struct LaunchView: View {
    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            VStack(spacing: Spacing.m) {
                Image(systemName: "figure.climbing")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(Palette.accent)
                ProgressView().tint(Palette.accent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading BoulderMe")
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var router = app.router
        TabView(selection: $router.selectedTab) {
            NavigationStack(path: $router.discover) {
                DiscoverView()
                    .navigationDestination(for: DiscoverRoute.self) { route in
                        switch route {
                        case let .profile(id): ProfileDetailView(accountId: id)
                        }
                    }
            }
            .tabItem { Label(AppTab.discover.title, systemImage: AppTab.discover.systemImage) }
            .tag(AppTab.discover)

            NavigationStack(path: $router.invites) {
                InvitesView()
                    .navigationDestination(for: InvitesRoute.self) { route in
                        switch route {
                        case let .invitation(id): InvitationDetailView(invitationId: id)
                        case let .profile(id): ProfileDetailView(accountId: id)
                        }
                    }
            }
            .tabItem { Label(AppTab.invites.title, systemImage: AppTab.invites.systemImage) }
            .badge(app.pendingInviteCount)
            .tag(AppTab.invites)

            NavigationStack(path: $router.chats) {
                ChatsView()
                    .navigationDestination(for: ChatsRoute.self) { route in
                        switch route {
                        case let .chat(id): ChatThreadView(chatId: id)
                        case let .profile(id): ProfileDetailView(accountId: id)
                        }
                    }
            }
            .tabItem { Label(AppTab.chats.title, systemImage: AppTab.chats.systemImage) }
            .badge(app.unreadChatCount)
            .tag(AppTab.chats)

            NavigationStack(path: $router.profile) {
                MyProfileView()
                    .navigationDestination(for: ProfileRoute.self) { route in
                        switch route {
                        case .editProfile: EditProfileView()
                        case .gyms: MyGymsView()
                        case .availability: MyAvailabilityView()
                        case .settings: SettingsView()
                        case .deleteAccount: DeleteAccountView()
                        case .designSystem: DesignSystemGallery()
                        }
                    }
            }
            .tabItem { Label(AppTab.profile.title, systemImage: AppTab.profile.systemImage) }
            .tag(AppTab.profile)
        }
        .task { await app.refreshBadges() }
        .onChange(of: router.selectedTab) {
            Task { await app.refreshBadges() }
        }
    }
}

#Preview("Demo tabs") {
    RootView().environment(AppModel.preview())
}

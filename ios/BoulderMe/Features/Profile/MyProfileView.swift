import SwiftUI

/// Your own card as others see it, discovery status, gyms and availability.
/// Editing arrives in T6.
struct MyProfileView: View {
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<Me> = .loading
    @State private var slots: [AvailabilitySlot] = []

    var body: some View {
        LoadStateView(state: state, retry: { Task { await load() } }) { me in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    if let profile = me.profile {
                        discoveryPill(profile.discoverable)
                        SectionHeader(title: "Your card", subtitle: "What other signed-in climbers see")
                        ProfileCardView(card: ProfileCard(
                            accountId: profile.accountId, displayName: profile.displayName,
                            gradeMin: profile.gradeMin, gradeMax: profile.gradeMax, styles: profile.styles,
                            accessType: me.gyms.first?.accessType ?? .membership,
                            availabilitySummary: slots.map { AvailabilitySummaryItem(weekday: $0.weekday, timeOfDay: $0.timeOfDay) },
                            activeRecently: true))
                    }
                    SectionHeader(title: "My gyms")
                    ForEach(me.gyms) { access in
                        CozyCard {
                            Text(access.gym.name).font(Typography.headline).foregroundStyle(Palette.ink)
                            Text(access.gym.city).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                            AccessLabel(accessType: access.accessType)
                        }
                    }
                }
                .padding(Spacing.m)
            }
            .refreshable { await load() }
        }
        .cozyNavigation(title: "Profile")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: ProfileRoute.settings) {
                    Image(systemName: "gearshape.fill").accessibilityLabel("Settings")
                }
            }
        }
        .task { await load() }
    }

    private func discoveryPill(_ on: Bool) -> some View {
        Label(on ? "Discoverable" : "Discovery paused", systemImage: on ? "eye.fill" : "eye.slash.fill")
            .font(Typography.caption.weight(.bold))
            .foregroundStyle(on ? Palette.moss : Palette.inkSecondary)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xxs)
            .background((on ? Palette.moss : Palette.inkSecondary).opacity(0.14), in: Capsule())
    }

    private func load() async {
        do {
            let me = try await app.services.account.me()
            slots = (try? await app.services.availability.slots()) ?? []
            state = .loaded(me)
        } catch {
            state = .failed(error.asAppError)
        }
    }
}

/// Settings shell. T6 fills in discovery toggle, blocked list, export, sign out
/// and delete; here it has the demo exit, app info and the design gallery.
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            if app.isDemo {
                Section {
                    Button("Leave the demo", role: .destructive) { app.leaveDemo() }
                } footer: {
                    Text("Demo data is made up and stays on this device. Leaving resets it.")
                }
            }
            Section("Safety") {
                Button("Safety tips") { app.router.sheet = .safetyTips }
            }
            Section("About") {
                LabeledContent("Version", value: "\(app.config.version) (\(app.config.build))")
                if app.config.environment != .production {
                    LabeledContent("Environment", value: app.config.environment.rawValue)
                    NavigationLink("Design system", value: ProfileRoute.designSystem)
                }
            }
        }
        .font(Typography.body)
        .cozyNavigation(title: "Settings")
    }
}

#Preview("My profile") {
    NavigationStack { MyProfileView() }.environment(AppModel.preview())
}

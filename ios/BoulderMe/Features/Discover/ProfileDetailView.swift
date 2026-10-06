import SwiftUI

/// Another climber's public profile. The invite sheet, report and block land
/// in T7; the buttons are in place and route through the app model.
struct ProfileDetailView: View {
    let accountId: EntityID
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<PublicProfile> = .loading
    @State private var showComingSoon = false

    var body: some View {
        LoadStateView(state: state, retry: { Task { await load() } }) { profile in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    header(profile)
                    if let intro = profile.intro, !intro.isEmpty {
                        CozyCard {
                            Text(intro).font(Typography.body).foregroundStyle(Palette.ink)
                        }
                    }
                    CozyCard {
                        SectionHeader(title: "Styles")
                        ChipFlow(items: profile.styles.map(\.title))
                    }
                    CozyCard {
                        SectionHeader(title: "Gyms", subtitle: "Access is self-reported")
                        ForEach(profile.gyms) { access in
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(access.gym.name).font(Typography.headline).foregroundStyle(Palette.ink)
                                AccessLabel(accessType: access.accessType)
                            }
                        }
                    }
                    if !profile.availability.isEmpty {
                        CozyCard {
                            SectionHeader(title: "Usually climbs")
                            AvailabilitySummaryView(items: profile.availability.map {
                                AvailabilitySummaryItem(weekday: $0.weekday, timeOfDay: $0.timeOfDay)
                            })
                        }
                    }
                    Button {
                        showComingSoon = true
                    } label: {
                        Label("Invite to climb", systemImage: "hand.wave.fill")
                    }
                    .buttonStyle(.cozyPrimary)
                    .padding(.top, Spacing.s)
                }
                .padding(Spacing.m)
            }
        }
        .cozyNavigation(title: state.value?.displayName ?? "Climber")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Safety tips", systemImage: "heart.text.square") { app.router.sheet = .safetyTips }
                    Button("Report", systemImage: "flag") { showComingSoon = true }
                    Button("Block", systemImage: "hand.raised", role: .destructive) { showComingSoon = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("More")
                }
            }
        }
        .alert(AppError.notImplemented.title, isPresented: $showComingSoon) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(AppError.notImplemented.userMessage)
        }
        .task { await load() }
    }

    private func header(_ profile: PublicProfile) -> some View {
        HStack(spacing: Spacing.m) {
            Avatar(name: profile.displayName, seed: profile.accountId, size: 72)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(profile.displayName).font(Typography.title).foregroundStyle(Palette.ink)
                GradeBadge(min: profile.gradeMin, max: profile.gradeMax)
                if profile.activeRecently {
                    Label("Active recently", systemImage: "leaf.fill")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.moss)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            state = .loaded(try await app.services.profiles.profile(id: accountId))
        } catch {
            state = .failed(error.asAppError)
        }
    }
}

#Preview("Profile detail") {
    NavigationStack { ProfileDetailView(accountId: DemoFixtures.id(11)) }
        .environment(AppModel.preview())
}

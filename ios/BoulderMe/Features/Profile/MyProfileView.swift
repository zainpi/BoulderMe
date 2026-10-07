import SwiftUI

/// Your own card as others see it, discovery status, and links to edit
/// profile, gyms and availability.
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
                        if let intro = profile.intro {
                            Text(intro).font(Typography.body).foregroundStyle(Palette.inkSecondary)
                        }
                        NavigationLink(value: ProfileRoute.editProfile) {
                            Label("Edit profile", systemImage: "pencil")
                        }
                        .buttonStyle(.cozySecondary)
                    }
                    linkRow(.gyms, title: "My gyms", detail: gymsDetail(me), symbol: "building.2.fill")
                    linkRow(.availability, title: "When I climb", detail: slotsDetail, symbol: "calendar")
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

    private func gymsDetail(_ me: Me) -> String {
        switch me.gyms.count {
        case 0: "Add a gym so climbers can find you"
        case 1: me.gyms[0].gym.name
        default: "\(me.gyms[0].gym.name) and \(me.gyms.count - 1) more"
        }
    }

    private var slotsDetail: String {
        slots.isEmpty ? "Add the times you usually climb" : "\(slots.count) time\(slots.count == 1 ? "" : "s") a week"
    }

    private func linkRow(_ route: ProfileRoute, title: String, detail: String, symbol: String) -> some View {
        NavigationLink(value: route) {
            CozyCard {
                HStack(spacing: Spacing.s) {
                    Image(systemName: symbol).font(.title3).foregroundStyle(Palette.accent).frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(title).font(Typography.headline).foregroundStyle(Palette.ink)
                        Text(detail).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.forward").foregroundStyle(Palette.inkSecondary).accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
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
            let appError = error.asAppError
            if appError == .offline {
                let cached: Me? = app.accountCache?.value("me")
                state = .offline(cached: cached, lastUpdated: nil)
            } else {
                state = .failed(appError)
            }
        }
    }
}

/// Edit name, intro, grades and styles. `revision_conflict` offers to keep
/// these edits or load the saved version.
struct EditProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var profile: OwnProfile?
    @State private var draft = ProfileDraft()
    @State private var loadError: AppError?
    @State private var saveError: AppError?
    @State private var saving = false
    @State private var conflict = false

    var body: some View {
        Group {
            if profile != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.l) {
                        NameIntroFields(draft: $draft)
                        GradeRangePicker(min: $draft.gradeMin, max: $draft.gradeMax)
                        StylePicker(draft: $draft)
                        if let saveError {
                            Text(saveError.userMessage).font(Typography.callout).foregroundStyle(Palette.danger)
                        }
                    }
                    .padding(Spacing.m)
                }
                .scrollDismissesKeyboard(.interactively)
            } else if let loadError {
                ErrorStateView(error: loadError) { Task { await load() } }
            } else {
                ScrollView { SkeletonList(count: 2).padding(Spacing.m) }
            }
        }
        .cozyNavigation(title: "Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") { Task { await save(revision: profile?.revision ?? 0) } }
                    .disabled(saving || profile == nil || !draft.isValid || draft == profile.map(ProfileDraft.init(profile:)))
            }
        }
        .alert("Your profile changed somewhere else", isPresented: $conflict) {
            Button("Keep my edits") { Task { await keepMine() } }
            Button("Use the saved version") { Task { await load() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It was saved from another device since you opened it.")
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let me = try await app.services.account.me()
            guard let current = me.profile else { throw AppError.api(.notFound, requestId: nil) }
            profile = current
            draft = ProfileDraft(profile: current)
            loadError = nil
        } catch {
            loadError = error.asAppError
        }
    }

    private func save(revision: Int) async {
        guard let profile else { return }
        saving = true
        defer { saving = false }
        do {
            self.profile = try await app.services.profiles.saveProfile(
                draft.input(revision: revision, discoveryExplained: profile.discoveryExplained))
            saveError = nil
            dismiss()
        } catch AppError.api(.revisionConflict, _) {
            conflict = true
        } catch {
            saveError = error.asAppError
        }
    }

    private func keepMine() async {
        do {
            let me = try await app.services.account.me()
            await save(revision: me.profile?.revision ?? 0)
        } catch {
            saveError = error.asAppError
        }
    }
}

/// My gyms (Profile tab).
struct MyGymsView: View {
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<[GymAccess]> = .loading

    var body: some View {
        LoadStateView(state: state, retry: { Task { await load() } }) { gyms in
            ScrollView {
                GymsEditor(gyms: gyms) { state = .loaded($0) }
                    .padding(Spacing.m)
            }
        }
        .cozyNavigation(title: "My gyms")
        .task { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await app.services.gyms.myGyms())
        } catch {
            state = .failed(error.asAppError)
        }
    }
}

/// Weekly availability (Profile tab).
struct MyAvailabilityView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Tap the times you usually climb. Climbers who can see your profile see these too.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.inkSecondary)
                AvailabilityEditor()
            }
            .padding(Spacing.m)
        }
        .cozyNavigation(title: "When I climb")
    }
}

#Preview("My profile") {
    NavigationStack { MyProfileView() }.environment(AppModel.preview())
}

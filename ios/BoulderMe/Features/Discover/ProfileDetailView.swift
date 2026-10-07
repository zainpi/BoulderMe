import SwiftUI

/// Another climber's public profile, from Discover, an invitation or a chat.
/// Invite to climb, report and block start here.
struct ProfileDetailView: View {
    let accountId: EntityID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<PublicProfile> = .loading
    @State private var showInvite = false
    @State private var reportTarget: ReportTarget?
    @State private var blockTarget: BlockTarget?

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
                    if !profile.styles.isEmpty {
                        CozyCard {
                            SectionHeader(title: "Styles")
                            ChipFlow(items: profile.styles.map(\.title))
                        }
                    }
                    CozyCard {
                        SectionHeader(title: "Gyms", subtitle: "Access is self-reported")
                        ForEach(profile.gyms) { access in
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(access.gym.name).font(Typography.headline).foregroundStyle(Palette.ink)
                                AccessLabel(accessType: access.accessType)
                            }
                            .accessibilityElement(children: .combine)
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
                        showInvite = true
                    } label: {
                        Label("Invite to climb", systemImage: "hand.wave.fill")
                    }
                    .buttonStyle(.cozyPrimary)
                    .padding(.top, Spacing.s)
                }
                .padding(Spacing.m)
            }
            .sheet(isPresented: $showInvite) {
                InviteSheet(profile: profile)
            }
        }
        .cozyNavigation(title: state.value?.displayName ?? "Climber")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Safety tips", systemImage: "heart.text.square") { app.router.sheet = .safetyTips }
                    if let profile = state.value {
                        Button("Report \(profile.displayName)", systemImage: "flag") {
                            reportTarget = .profile(profile.accountId, name: profile.displayName)
                        }
                        Button("Block \(profile.displayName)", systemImage: "hand.raised", role: .destructive) {
                            blockTarget = BlockTarget(accountId: profile.accountId, displayName: profile.displayName)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("More")
                }
            }
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(target: target, onBlocked: { dismiss() })
        }
        .blockConfirmation($blockTarget) { dismiss() }
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
            let appError = error.asAppError
            state = appError == .offline ? .offline(cached: state.value, lastUpdated: nil) : .failed(appError)
        }
    }
}

/// Invite a climber to a session: a gym you both climb at, a time 1 hour to 60
/// days ahead, a length and an optional note.
struct InviteSheet: View {
    let profile: PublicProfile
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var sharedGyms: LoadState<[Gym]> = .loading
    @State private var gymId: EntityID?
    @State private var start = InviteSheet.defaultStart()
    @State private var durationMinutes = 120
    @State private var note = ""
    @State private var sending = false
    @State private var error: AppError?
    @State private var sent: Invitation?
    @State private var showTips = false
    /// Reused on retry so a flaky connection never sends two invites.
    @State private var idempotencyKey = UUID()

    static let noteLimit = 200
    static let durations = [60, 90, 120, 180, 240]

    /// Tomorrow at 6 pm, a typical after-work session.
    static func defaultStart(now: Date = .now, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: tomorrow) ?? now.addingTimeInterval(86_400)
    }

    /// The window the Worker accepts: 1 hour to 60 days from now.
    static func allowedRange(now: Date = .now) -> ClosedRange<Date> {
        now.addingTimeInterval(3_600 + 60)...now.addingTimeInterval(60 * 86_400 - 60)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let sent { sentView(sent) } else { form }
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Invite \(profile.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sent == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            }
        }
        .interactiveDismissDisabled(sending)
        .sheet(isPresented: $showTips) { SafetyTipsSheet() }
        .task { await loadGyms() }
    }

    private var form: some View {
        LoadStateView(state: sharedGyms, retry: { Task { await loadGyms() } }) { gyms in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if gyms.isEmpty {
                        EmptyStateView(systemImage: "building.2.crop.circle",
                                       title: "No shared gym yet",
                                       message: "You can invite climbers at gyms you both list. Add one of \(profile.displayName)'s gyms to your profile first.")
                    } else {
                        gymSection(gyms)
                        whenSection
                        noteSection
                        if let error { errorView(error) }
                        Button(sending ? "Sending…" : "Send invite") { Task { await send() } }
                            .buttonStyle(.cozyPrimary)
                            .disabled(gymId == nil || sending)
                        Button {
                            showTips = true
                        } label: {
                            Label("Safety tips for meeting up", systemImage: "heart.text.square")
                                .font(Typography.callout)
                        }
                        .tint(Palette.accent)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(Spacing.m)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func gymSection(_ gyms: [Gym]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader(title: "Where", subtitle: "Gyms you both climb at")
            ForEach(gyms) { gym in
                ChoiceRow(title: gym.name, subtitle: gym.city, systemImage: "building.2.fill", isSelected: gymId == gym.gymId) {
                    gymId = gym.gymId
                }
            }
        }
    }

    private var whenSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader(title: "When", subtitle: "Between an hour and 60 days from now")
            DatePicker("Start", selection: $start, in: Self.allowedRange(), displayedComponents: [.date, .hourAndMinute])
                .font(Typography.body)
                .tint(Palette.accent)
            Picker("Length", selection: $durationMinutes) {
                ForEach(Self.durations, id: \.self) { minutes in
                    Text(Self.durationLabel(minutes)).tag(minutes)
                }
            }
            .font(Typography.body)
            .tint(Palette.accent)
        }
        .padding(Spacing.m)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader(title: "Note (optional)", subtitle: "A short hello. Chat opens once they accept.")
            TextField("Want to try the new slab set?", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .cozyField()
                .onChange(of: note) { _, value in
                    if value.count > Self.noteLimit { note = String(value.prefix(Self.noteLimit)) }
                }
            Text("\(note.count)/\(Self.noteLimit)")
                .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func errorView(_ error: AppError) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(error.userMessage).font(Typography.callout).foregroundStyle(Palette.danger)
            if error.code == .invitationAlreadyOpen {
                Button("See the open invite") { Task { await openExisting() } }
                    .font(Typography.callout.weight(.semibold))
                    .tint(Palette.accent)
            }
        }
    }

    private func sentView(_ invitation: Invitation) -> some View {
        VStack(spacing: Spacing.m) {
            EmptyStateView(
                systemImage: "paperplane.fill",
                title: "Invite sent",
                message: "\(profile.displayName) can accept or decline. A chat opens once they accept.")
            Button("See invite") {
                dismiss()
                app.router.openInvitation(invitation.invitationId)
            }
            .buttonStyle(.cozySecondary)
            Button("Done") { dismiss() }
                .buttonStyle(.cozyPrimary)
        }
        .padding(.horizontal, Spacing.m)
    }

    static func durationLabel(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return hours == 1 ? "1 hour" : "\(hours) hours"
        default: return "\(hours) h \(rest) min"
        }
    }

    private func loadGyms() async {
        do {
            let mine = Set(try await app.services.gyms.myGyms().map(\.gym.gymId))
            let shared = profile.gyms.map(\.gym).filter { mine.contains($0.gymId) }
            if gymId == nil { gymId = shared.first?.gymId }
            sharedGyms = .loaded(shared)
        } catch {
            sharedGyms = .failed(error.asAppError)
        }
    }

    private func send() async {
        guard let gymId else { return }
        guard Self.allowedRange().contains(start) else {
            error = .api(.invalidTime, requestId: nil)
            return
        }
        sending = true
        defer { sending = false }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = InvitationInput(recipientAccountId: profile.accountId, gymId: gymId, proposedStartAt: start,
                                    durationMinutes: durationMinutes, note: trimmed.isEmpty ? nil : trimmed)
        do {
            sent = try await app.services.invitations.create(input, idempotencyKey: idempotencyKey)
            error = nil
        } catch {
            let appError = error.asAppError
            self.error = appError
            // A changed request needs a new key; a network failure retries with the same one.
            if appError != .offline { idempotencyKey = UUID() }
        }
    }

    /// `invitation_already_open`: find the pending invite between the two of you and open it.
    private func openExisting() async {
        for box in InvitationBox.allCases {
            guard let page = try? await app.services.invitations.invitations(box: box, cursor: nil) else { continue }
            if let open = page.items.first(where: {
                $0.status == .pending && $0.other(than: app.currentAccountId).accountId == profile.accountId
            }) {
                dismiss()
                app.router.openInvitation(open.invitationId)
                return
            }
        }
        dismiss()
        app.router.selectedTab = .invites
    }
}

#Preview("Profile detail") {
    NavigationStack { ProfileDetailView(accountId: DemoFixtures.id(11)) }
        .environment(AppModel.preview())
}

#Preview("Invite sheet") {
    let maya = DemoFixtures.climbers(now: .now)[0].profile
    return InviteSheet(profile: maya).environment(AppModel.preview())
}

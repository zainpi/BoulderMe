import SwiftUI

/// Discover home: pick one of your gyms, filter, and page through who climbs there.
/// The selected gym and filters are kept per account on this device.
struct DiscoverView: View {
    @Environment(AppModel.self) private var app
    @State private var me: Me?
    @State private var selectedGymId: EntityID?
    @State private var filter = DiscoveryFilter.any
    @State private var state: LoadState<[ProfileCard]> = .loading
    @State private var nextCursor: String?
    @State private var loadingMore = false
    @State private var lastUpdated: Date?
    @State private var restored = false
    @State private var showFilters = false

    private var gyms: [GymAccess] { me?.gyms ?? [] }

    var body: some View {
        LoadStateView(state: state, retry: { Task { await load() } }) { cards in
            ScrollView {
                LazyVStack(spacing: Spacing.m) {
                    gymPicker
                    if me?.profile?.discoverable == false {
                        PausedBanner { app.router.profile = [.settings]; app.router.selectedTab = .profile }
                    }
                    if gyms.isEmpty, me != nil {
                        EmptyStateView(
                            systemImage: "building.2.fill",
                            title: "Add a gym first",
                            message: "Discover shows climbers at the gyms you climb at.",
                            actionTitle: "Add a gym") {
                                app.router.profile = [.gyms]
                                app.router.selectedTab = .profile
                            }
                    } else if cards.isEmpty {
                        EmptyStateView(
                            systemImage: "figure.climbing",
                            title: "No one's here yet",
                            message: filter.isActive
                                ? "No one matches these filters. Try widening them."
                                : "Invite a friend or try another gym.",
                            actionTitle: filter.isActive ? "Clear filters" : nil,
                            action: filter.isActive ? { filter = .any } : nil)
                    } else {
                        ForEach(cards) { card in
                            NavigationLink(value: DiscoverRoute.profile(card.accountId)) {
                                ProfileCardView(card: card)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens their profile")
                            .onAppear {
                                if card.id == cards.last?.id { Task { await loadMore() } }
                            }
                        }
                        if loadingMore {
                            SkeletonCard()
                        }
                    }
                }
                .padding(Spacing.m)
                .padding(.bottom, 72)
            }
            .refreshable { await load() }
        }
        .overlay(alignment: .bottom) {
            if !gyms.isEmpty { filterButton }
        }
        .cozyNavigation(title: "Discover")
        .sheet(isPresented: $showFilters) {
            DiscoveryFilterSheet(filter: $filter)
        }
        .task(id: TaskKey(gymId: selectedGymId, filter: filter, blockRevision: app.blockRevision)) {
            restoreChoices()
            await load()
        }
        .onChange(of: filter) { _, value in app.accountCache?.set(value, for: "discover.filter") }
        .onChange(of: selectedGymId) { _, value in app.accountCache?.set(value, for: "discover.gym") }
    }

    private struct TaskKey: Hashable {
        var gymId: EntityID?
        var filter: DiscoveryFilter
        var blockRevision: Int
    }

    @ViewBuilder
    private var gymPicker: some View {
        if gyms.count > 1 {
            Picker("Gym", selection: $selectedGymId) {
                ForEach(gyms) { access in
                    Text(access.gym.name).tag(Optional(access.gym.gymId))
                }
            }
            .pickerStyle(.menu)
            .font(Typography.headline)
            .tint(Palette.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let gym = gyms.first?.gym {
            Label(gym.name, systemImage: "building.2.fill")
                .font(Typography.headline)
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var filterButton: some View {
        Button {
            showFilters = true
        } label: {
            Label(filter.isActive ? "Filters on" : "Filters", systemImage: "slider.horizontal.3")
                .labelStyle(.titleAndIcon)
                .font(Typography.button)
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
                .floatingGlass(in: Capsule())
        }
        .padding(.bottom, Spacing.m)
        .accessibilityHint("Grade range, access type and when they climb")
    }

    /// Signed in, the last gym and filters come back from this device's account cache.
    private func restoreChoices() {
        guard !restored else { return }
        restored = true
        guard let cache = app.accountCache, !app.isDemo else { return }
        if let saved: DiscoveryFilter = cache.value("discover.filter") { filter = saved }
        if let saved: EntityID = cache.value("discover.gym") { selectedGymId = saved }
    }

    private func load() async {
        do {
            let me = try await app.services.account.me()
            self.me = me
            guard me.profile != nil else {
                state = .failed(.api(.profileIncomplete, requestId: nil))
                return
            }
            guard let gymId = me.gyms.first(where: { $0.gym.gymId == selectedGymId })?.gym.gymId ?? me.gyms.first?.gym.gymId else {
                state = .loaded([])
                return
            }
            if selectedGymId != gymId {
                selectedGymId = gymId // Re-runs the task for this gym.
                return
            }
            let page = try await app.services.discovery.discover(gymId: gymId, filter: filter, cursor: nil)
            nextCursor = page.nextCursor
            lastUpdated = .now
            state = .loaded(page.items)
        } catch {
            // A newer load (gym or filter changed) replaced this one.
            guard !Task.isCancelled else { return }
            let appError = error.asAppError
            state = appError == .offline ? .offline(cached: state.value, lastUpdated: lastUpdated) : .failed(appError)
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !loadingMore, let gymId = selectedGymId, case let .loaded(cards) = state else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await app.services.discovery.discover(gymId: gymId, filter: filter, cursor: cursor)
            let known = Set(cards.map(\.id))
            nextCursor = page.nextCursor
            state = .loaded(cards + page.items.filter { !known.contains($0.id) })
        } catch {
            // Keep what's shown; scrolling back to the end tries again.
        }
    }
}

/// Shown on Discover while your own discovery is paused.
struct PausedBanner: View {
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: "pause.circle.fill")
                .font(.title2)
                .foregroundStyle(Palette.denim)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("You're paused").font(Typography.headline).foregroundStyle(Palette.ink)
                Text("Others can't find or invite you right now. You can still browse and send invites.")
                    .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                Button("Change in Settings", action: openSettings)
                    .font(Typography.callout.weight(.semibold))
                    .tint(Palette.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .background(Palette.denim.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Grade range, access type, weekday and time of day.
struct DiscoveryFilterSheet: View {
    @Binding var filter: DiscoveryFilter
    @Environment(\.dismiss) private var dismiss
    @State private var draft = DiscoveryFilter.any

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    SectionHeader(title: "Grades", subtitle: "Show climbers whose range overlaps")
                    Toggle("Any grade", isOn: Binding(
                        get: { draft.gradeMin == nil && draft.gradeMax == nil },
                        set: { any in
                            draft.gradeMin = any ? nil : 0
                            draft.gradeMax = any ? nil : Grades.range.upperBound
                        }))
                        .tint(Palette.accent)
                    if draft.gradeMin != nil || draft.gradeMax != nil {
                        Stepper("From \(Grades.label(draft.gradeMin ?? 0))", value: Binding(
                            get: { draft.gradeMin ?? 0 },
                            set: { draft.gradeMin = $0; if let max = draft.gradeMax, max < $0 { draft.gradeMax = $0 } }),
                                in: Grades.range)
                        Stepper("To \(Grades.label(draft.gradeMax ?? Grades.range.upperBound))", value: Binding(
                            get: { draft.gradeMax ?? Grades.range.upperBound },
                            set: { draft.gradeMax = $0; if let min = draft.gradeMin, min > $0 { draft.gradeMin = $0 } }),
                                in: Grades.range)
                    }

                    SectionHeader(title: "Access", subtitle: "Self-reported by each climber")
                    ForEach(AccessType.allCases) { type in
                        ChoiceRow(title: type.title, systemImage: type.symbol, isSelected: draft.accessType == type) {
                            draft.accessType = draft.accessType == type ? nil : type
                        }
                    }

                    SectionHeader(title: "When", subtitle: "Climbers with a time slot then")
                    FlowLayout(spacing: Spacing.xs) {
                        ForEach(Weekday.allCases) { day in
                            Chip(title: day.shortName, isSelected: draft.weekday == day) {
                                draft.weekday = draft.weekday == day ? nil : day
                            }
                        }
                    }
                    FlowLayout(spacing: Spacing.xs) {
                        ForEach(TimeOfDay.allCases) { time in
                            Chip(title: time.title, isSelected: draft.timeOfDay == time) {
                                draft.timeOfDay = draft.timeOfDay == time ? nil : time
                            }
                        }
                    }
                }
                .font(Typography.body)
                .foregroundStyle(Palette.ink)
                .padding(Spacing.m)
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Reset") { draft = .any } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        filter = draft
                        dismiss()
                    }
                    .bold()
                }
            }
            .onAppear { draft = filter }
        }
        .presentationDetents([.large])
    }
}

#Preview("Discover") {
    let app = AppModel.preview()
    return NavigationStack { DiscoverView() }.environment(app)
}

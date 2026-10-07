import SwiftUI

/// Discover home: pick one of your gyms, see who climbs there. Full filters,
/// invite sheet and paging arrive in T7; this is the shell they plug into.
struct DiscoverView: View {
    @Environment(AppModel.self) private var app
    @State private var gyms: [GymAccess] = []
    @State private var selectedGymId: EntityID?
    @State private var filter = DiscoveryFilter.any
    @State private var state: LoadState<[ProfileCard]> = .loading
    @State private var showFilters = false

    var body: some View {
        LoadStateView(state: state, retry: { Task { await load() } }) { cards in
            ScrollView {
                VStack(spacing: Spacing.m) {
                    gymPicker
                    if cards.isEmpty {
                        EmptyStateView(
                            systemImage: "figure.climbing",
                            title: "No one's here yet",
                            message: "Invite a friend or try another gym.",
                            actionTitle: filter.isActive ? "Clear filters" : nil,
                            action: filter.isActive ? { filter = .any } : nil)
                    } else {
                        ForEach(cards) { card in
                            NavigationLink(value: DiscoverRoute.profile(card.accountId)) {
                                ProfileCardView(card: card)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(Spacing.m)
                .padding(.bottom, 72)
            }
            .refreshable { await load() }
        }
        .overlay(alignment: .bottom) { filterButton }
        .cozyNavigation(title: "Discover")
        .sheet(isPresented: $showFilters) {
            DiscoveryFilterSheet(filter: $filter)
        }
        .task(id: TaskKey(gymId: selectedGymId, filter: filter)) { await load() }
    }

    private struct TaskKey: Hashable {
        var gymId: EntityID?
        var filter: DiscoveryFilter
    }

    @ViewBuilder
    private var gymPicker: some View {
        if !gyms.isEmpty {
            Picker("Gym", selection: $selectedGymId) {
                ForEach(gyms) { access in
                    Text(access.gym.name).tag(Optional(access.gym.gymId))
                }
            }
            .pickerStyle(.menu)
            .font(Typography.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var filterButton: some View {
        Button {
            showFilters = true
        } label: {
            Label(filter.isActive ? "Filters on" : "Filters", systemImage: "slider.horizontal.3")
                .font(Typography.button)
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
                .floatingGlass(in: Capsule())
        }
        .padding(.bottom, Spacing.m)
    }

    private func load() async {
        do {
            if gyms.isEmpty {
                gyms = try await app.services.gyms.myGyms()
            }
            guard let gymId = selectedGymId ?? gyms.first?.gym.gymId else {
                state = .loaded([])
                return
            }
            if selectedGymId == nil { selectedGymId = gymId }
            let page = try await app.services.discovery.discover(gymId: gymId, filter: filter, cursor: nil)
            state = .loaded(page.items)
        } catch {
            let appError = error.asAppError
            state = appError == .offline ? .offline(cached: state.value, lastUpdated: nil) : .failed(appError)
        }
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
                    HStack {
                        Stepper("From \(Grades.label(draft.gradeMin ?? 0))", value: Binding(
                            get: { draft.gradeMin ?? 0 },
                            set: { draft.gradeMin = $0; if let max = draft.gradeMax, max < $0 { draft.gradeMax = $0 } }),
                                in: Grades.range)
                    }
                    Stepper("To \(Grades.label(draft.gradeMax ?? Grades.range.upperBound))", value: Binding(
                        get: { draft.gradeMax ?? Grades.range.upperBound },
                        set: { draft.gradeMax = $0; if let min = draft.gradeMin, min > $0 { draft.gradeMin = $0 } }),
                            in: Grades.range)

                    SectionHeader(title: "Access", subtitle: "Self-reported by each climber")
                    ForEach(AccessType.allCases) { type in
                        ChoiceRow(title: type.title, systemImage: type.symbol, isSelected: draft.accessType == type) {
                            draft.accessType = draft.accessType == type ? nil : type
                        }
                    }

                    SectionHeader(title: "When")
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

import SwiftUI

/// The member's gyms with self-reported access, used by onboarding and My gyms.
/// Every change is saved right away; removing shows an Undo.
struct GymsEditor: View {
    @Environment(AppModel.self) private var app
    let gyms: [GymAccess]
    let onChange: ([GymAccess]) -> Void

    @State private var showSearch = false
    @State private var error: AppError?
    @State private var removed: GymAccess?
    @State private var working: EntityID?

    static let limit = 10

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if gyms.isEmpty {
                EmptyStateView(systemImage: "building.2.fill", title: "No gyms yet",
                               message: "Add the gyms you climb at so climbers there can find you.")
            }
            ForEach(gyms) { access in
                gymCard(access)
            }
            if let removed {
                HStack {
                    Text("Removed \(removed.gym.name)").font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                    Spacer()
                    Button("Undo") { Task { await undoRemove(removed) } }
                        .font(Typography.caption.weight(.bold))
                }
                .padding(.horizontal, Spacing.xs)
            }
            if let error {
                Text(error.userMessage).font(Typography.caption).foregroundStyle(Palette.danger)
            }
            Button {
                showSearch = true
            } label: {
                Label(gyms.isEmpty ? "Add a gym" : "Add another gym", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.cozySecondary)
            .disabled(gyms.count >= Self.limit)
            if gyms.count >= Self.limit {
                Text(AppError.api(.gymLimitReached, requestId: nil).userMessage)
                    .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
            }
        }
        .sheet(isPresented: $showSearch) {
            GymSearchSheet(excluded: Set(gyms.map(\.gym.gymId))) { gym, accessType in
                await add(gym: gym, accessType: accessType)
            }
        }
    }

    private func gymCard(_ access: GymAccess) -> some View {
        CozyCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(access.gym.name).font(Typography.headline).foregroundStyle(Palette.ink)
                    Text(access.gym.city).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
                Button(role: .destructive) {
                    Task { await remove(access) }
                } label: {
                    Image(systemName: "minus.circle.fill").font(.title3).foregroundStyle(Palette.danger)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(access.gym.name)")
            }
            AccessTypePicker(selection: Binding(
                get: { access.accessType },
                set: { type in Task { await setAccess(access.gym, type) } }))
            .disabled(working == access.gym.gymId)
        }
    }

    private func add(gym: Gym, accessType: AccessType) async -> Bool {
        do {
            let access = try await app.services.gyms.setAccess(gymId: gym.gymId, accessType: accessType)
            onChange(gyms + [access])
            error = nil
            return true
        } catch {
            self.error = error.asAppError
            return false
        }
    }

    private func setAccess(_ gym: Gym, _ type: AccessType) async {
        working = gym.gymId
        defer { working = nil }
        do {
            let access = try await app.services.gyms.setAccess(gymId: gym.gymId, accessType: type)
            onChange(gyms.map { $0.gym.gymId == gym.gymId ? access : $0 })
            error = nil
        } catch {
            self.error = error.asAppError
        }
    }

    private func remove(_ access: GymAccess) async {
        do {
            try await app.services.gyms.removeGym(gymId: access.gym.gymId)
            onChange(gyms.filter { $0.gym.gymId != access.gym.gymId })
            removed = access
            error = nil
        } catch {
            self.error = error.asAppError
        }
    }

    private func undoRemove(_ access: GymAccess) async {
        if await add(gym: access.gym, accessType: access.accessType) { removed = nil }
    }
}

/// Membership or guest pass, always captioned as self-reported.
struct AccessTypePicker: View {
    @Binding var selection: AccessType

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Picker("Access", selection: $selection) {
                ForEach(AccessType.allCases) { type in
                    Label(type.title, systemImage: type.symbol).tag(type)
                }
            }
            .pickerStyle(.segmented)
            Text("Self-reported. BoulderMe never checks memberships or passes.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
    }
}

/// Search the curated list and add a gym, or suggest a missing one.
struct GymSearchSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let excluded: Set<EntityID>
    let onAdd: (Gym, AccessType) async -> Bool

    @State private var query = ""
    @State private var state: LoadState<[Gym]> = .loading
    @State private var chosen: Gym?
    @State private var accessType: AccessType = .membership
    @State private var adding = false
    @State private var showSuggest = false

    var body: some View {
        NavigationStack {
            Group {
                if let chosen {
                    confirm(chosen)
                } else {
                    results
                }
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle(chosen == nil ? "Find your gym" : "How do you get in?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .sheet(isPresented: $showSuggest) { SuggestGymSheet(prefillName: query) }
        .task(id: query) {
            // Debounce typing, then search.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            TextField("Search by name or city", text: $query)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .cozyField()
                .padding(Spacing.m)
            LoadStateView(state: state, retry: { Task { await search() } }) { gyms in
                let visible = gyms.filter { !excluded.contains($0.gymId) }
                ScrollView {
                    VStack(spacing: Spacing.s) {
                        if visible.isEmpty {
                            EmptyStateView(systemImage: "magnifyingglass", title: "No gyms found",
                                           message: "We're starting in Ontario. Tell us about your gym and we'll look into it.",
                                           actionTitle: "Suggest a gym") { showSuggest = true }
                        }
                        ForEach(visible) { gym in
                            ChoiceRow(title: gym.name, subtitle: gym.city, systemImage: "building.2.fill", isSelected: false) {
                                chosen = gym
                            }
                        }
                        if !visible.isEmpty {
                            Button("Can't find it? Suggest a gym") { showSuggest = true }
                                .font(Typography.callout)
                                .padding(.top, Spacing.s)
                        }
                    }
                    .padding(.horizontal, Spacing.m)
                    .padding(.bottom, Spacing.l)
                }
            }
        }
    }

    private func confirm(_ gym: Gym) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                CozyCard {
                    Text(gym.name).font(Typography.title).foregroundStyle(Palette.ink)
                    Text([gym.address, gym.city].compactMap { $0 }.joined(separator: " · "))
                        .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                }
                ForEach(AccessType.allCases) { type in
                    ChoiceRow(title: type.title,
                              subtitle: type == .membership ? "You have a membership here" : "You pay per visit or use a pass",
                              systemImage: type.symbol, isSelected: accessType == type) { accessType = type }
                }
                Text("Self-reported. BoulderMe never checks memberships or passes.")
                    .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                Button(adding ? "Adding…" : "Add \(gym.name)") {
                    Task {
                        adding = true
                        if await onAdd(gym, accessType) { dismiss() }
                        adding = false
                    }
                }
                .buttonStyle(.cozyPrimary)
                .disabled(adding)
                Button("Pick a different gym") { chosen = nil }
                    .buttonStyle(.cozySecondary)
            }
            .padding(Spacing.m)
        }
    }

    private func search() async {
        do {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let page = try await app.services.gyms.gyms(query: trimmed.count >= 2 ? trimmed : nil, region: nil, cursor: nil)
            state = .loaded(page.items)
        } catch {
            state = .failed(error.asAppError)
        }
    }
}

/// "Suggest a gym": goes to a review queue, nothing is published automatically.
struct SuggestGymSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var city = ""
    @State private var website = ""
    @State private var note = ""
    @State private var sending = false
    @State private var sent = false
    @State private var error: AppError?

    init(prefillName: String = "") {
        _name = State(initialValue: prefillName)
    }

    private var canSend: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        return (2...80).contains(trimmedName.count) && (2...60).contains(trimmedCity.count) && note.count <= 280 && !sending
    }

    var body: some View {
        NavigationStack {
            Form {
                if sent {
                    Section {
                        Label("Thanks! We'll review it soon.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Palette.moss)
                    }
                } else {
                    Section {
                        TextField("Gym name", text: $name)
                        TextField("City", text: $city)
                        LabeledContent("Province", value: "Ontario")
                        TextField("Website (optional)", text: $website)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                        TextField("Anything else? (optional)", text: $note, axis: .vertical)
                    } footer: {
                        Text("Suggestions go to a review queue. Nothing is added automatically.")
                    }
                    if let error {
                        Section { Text(error.userMessage).foregroundStyle(Palette.danger) }
                    }
                }
            }
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Suggest a gym")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(sent ? "Done" : "Cancel") { dismiss() } }
                if !sent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") { Task { await send() } }.disabled(!canSend)
                    }
                }
            }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = GymRequestInput(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            city: city.trimmingCharacters(in: .whitespacesAndNewlines),
            region: "CA-ON",
            websiteUrl: URL(string: website.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? nil : $0 },
            note: trimmedNote.isEmpty ? nil : trimmedNote)
        do {
            _ = try await app.services.gyms.requestGym(input)
            sent = true
        } catch {
            self.error = error.asAppError
        }
    }
}

import SwiftUI

/// Incoming / Outgoing invitations in three sections: Pending, Upcoming, Past.
struct InvitesView: View {
    @Environment(AppModel.self) private var app
    @State private var box: InvitationBox = .incoming
    @State private var state: LoadState<[Invitation]> = .loading
    @State private var nextCursor: String?
    @State private var lastUpdated: Date?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Box", selection: $box) {
                ForEach(InvitationBox.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)

            LoadStateView(state: state, retry: { Task { await load() } }) { invitations in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.m) {
                        if invitations.isEmpty {
                            EmptyStateView(
                                systemImage: box == .incoming ? "envelope.open" : "paperplane",
                                title: box == .incoming ? "No invites yet" : "Nothing sent yet",
                                message: box == .incoming
                                    ? "When someone invites you to climb, it shows up here."
                                    : "Find a climber in Discover and invite them to a session.",
                                actionTitle: box == .outgoing ? "Go to Discover" : nil,
                                action: box == .outgoing ? { app.router.selectedTab = .discover } : nil)
                        } else {
                            let sections = InvitationSections(invitations)
                            section("Pending", sections.pending, all: invitations)
                            section("Upcoming", sections.upcoming, all: invitations)
                            section("Past", sections.past, all: invitations)
                        }
                    }
                    .padding(Spacing.m)
                }
                .refreshable { await load() }
            }
        }
        .cozyNavigation(title: "Invites")
        .task(id: TaskKey(box: box, blockRevision: app.blockRevision)) { await load() }
        .onAppear { if state.value != nil { Task { await load() } } }
    }

    private struct TaskKey: Hashable {
        var box: InvitationBox
        var blockRevision: Int
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Invitation], all: [Invitation]) -> some View {
        if !items.isEmpty {
            SectionHeader(title: title)
                .padding(.top, Spacing.xs)
            ForEach(items) { invitation in
                NavigationLink(value: InvitesRoute.invitation(invitation.invitationId)) {
                    InvitationRow(invitation: invitation, box: box)
                }
                .buttonStyle(.plain)
                .onAppear {
                    if invitation.id == all.last?.id { Task { await loadMore() } }
                }
            }
        }
    }

    private func load() async {
        do {
            let page = try await app.services.invitations.invitations(box: box, cursor: nil)
            nextCursor = page.nextCursor
            lastUpdated = .now
            state = .loaded(page.items)
        } catch {
            guard !Task.isCancelled else { return }
            let appError = error.asAppError
            state = appError == .offline ? .offline(cached: state.value, lastUpdated: lastUpdated) : .failed(appError)
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor, case let .loaded(items) = state else { return }
        nextCursor = nil
        do {
            let page = try await app.services.invitations.invitations(box: box, cursor: cursor)
            let known = Set(items.map(\.id))
            nextCursor = page.nextCursor
            state = .loaded(items + page.items.filter { !known.contains($0.id) })
        } catch {
            nextCursor = cursor
        }
    }
}

/// Splits a box into what needs an answer, accepted sessions still to come, and the rest.
struct InvitationSections {
    var pending: [Invitation] = []
    var upcoming: [Invitation] = []
    var past: [Invitation] = []

    init(_ invitations: [Invitation], now: Date = .now) {
        for invitation in invitations {
            switch invitation.status {
            case .pending where invitation.expiresAt > now: pending.append(invitation)
            case .accepted where invitation.endsAt > now: upcoming.append(invitation)
            default: past.append(invitation)
            }
        }
        pending.sort { $0.proposedStartAt < $1.proposedStartAt }
        upcoming.sort { $0.proposedStartAt < $1.proposedStartAt }
    }
}

struct InvitationRow: View {
    let invitation: Invitation
    let box: InvitationBox

    private var other: InvitationParty { box == .incoming ? invitation.sender : invitation.recipient }

    var body: some View {
        CozyCard {
            HStack(spacing: Spacing.s) {
                Avatar(name: other.displayName, seed: other.accountId, size: 44)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(other.displayName).font(Typography.headline).foregroundStyle(Palette.ink)
                    Text(invitation.gym.name).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                }
                Spacer(minLength: 0)
                StatusPill(status: invitation.status)
            }
            HStack(spacing: Spacing.s) {
                Label(invitation.proposedStartAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                Label(InviteSheet.durationLabel(invitation.durationMinutes), systemImage: "clock")
            }
            .font(Typography.callout)
            .foregroundStyle(Palette.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the invite")
    }
}

struct StatusPill: View {
    let status: InvitationStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(Typography.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xxs)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var color: Color {
        switch status {
        case .pending: Palette.accent
        case .accepted: Palette.moss
        case .declined, .cancelled, .expired: Palette.inkSecondary
        }
    }
}

/// One invitation: accept or decline (incoming), cancel (outgoing or an accepted
/// session), open the chat, view their profile, report or block.
struct InvitationDetailView: View {
    let invitationId: EntityID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<Invitation> = .loading
    @State private var working = false
    @State private var actionError: AppError?
    @State private var confirmCancel = false
    @State private var reportTarget: ReportTarget?
    @State private var blockTarget: BlockTarget?

    var body: some View {
        LoadStateView(state: state, retry: { Task { await load() } }) { invitation in
            let incoming = invitation.isIncoming(for: app.currentAccountId)
            let other = invitation.other(than: app.currentAccountId)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    InvitationRow(invitation: invitation, box: incoming ? .incoming : .outgoing)
                    if !other.isDeleted {
                        NavigationLink(value: InvitesRoute.profile(other.accountId)) {
                            Label("See \(other.displayName)'s profile", systemImage: "person.crop.circle")
                                .font(Typography.callout.weight(.semibold))
                        }
                        .tint(Palette.accent)
                    }
                    if let note = invitation.note, !note.isEmpty {
                        CozyCard {
                            SectionHeader(title: "Note")
                            Text(note).font(Typography.body).foregroundStyle(Palette.ink)
                        }
                    }
                    Text(explanation(invitation, incoming: incoming, other: other))
                        .font(Typography.callout)
                        .foregroundStyle(Palette.inkSecondary)
                    actions(invitation, incoming: incoming)
                }
                .padding(Spacing.m)
            }
            .refreshable { await load() }
        }
        .cozyNavigation(title: "Invite")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let invitation = state.value {
                    let other = invitation.other(than: app.currentAccountId)
                    if !other.isDeleted {
                        Menu {
                            Button("Safety tips", systemImage: "heart.text.square") { app.router.sheet = .safetyTips }
                            Button("Report", systemImage: "flag") {
                                reportTarget = .invitation(invitation, from: other)
                            }
                            Button("Block \(other.displayName)", systemImage: "hand.raised", role: .destructive) {
                                blockTarget = BlockTarget(accountId: other.accountId, displayName: other.displayName)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").accessibilityLabel("More")
                        }
                    }
                }
            }
        }
        .confirmationDialog("Cancel this session?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel invite", role: .destructive) {
                perform { try await app.services.invitations.cancel(id: invitationId) }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("They'll see it as cancelled.")
        }
        .alert(actionError?.title ?? "", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError?.userMessage ?? "")
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(target: target, onBlocked: { dismiss() })
        }
        .blockConfirmation($blockTarget) { dismiss() }
        .task { await load() }
    }

    private func explanation(_ invitation: Invitation, incoming: Bool, other: InvitationParty) -> String {
        switch invitation.status {
        case .pending:
            incoming
                ? "Accept to open a chat with \(other.displayName). Declining is private: they only see \"declined\"."
                : "Waiting for \(other.displayName). It expires at the start time if there's no answer."
        case .accepted: "You're climbing together. Chat to sort out the details."
        case .declined: "This invite was declined."
        case .cancelled: "This invite was cancelled."
        case .expired: "This invite expired without an answer."
        }
    }

    @ViewBuilder
    private func actions(_ invitation: Invitation, incoming: Bool) -> some View {
        VStack(spacing: Spacing.s) {
            switch invitation.status {
            case .pending where incoming:
                Button(working ? "Accepting…" : "Accept") {
                    perform { try await app.services.invitations.accept(id: invitationId) }
                }
                .buttonStyle(.cozyPrimary)
                Button("Decline") { perform { try await app.services.invitations.decline(id: invitationId) } }
                    .buttonStyle(.cozySecondary)
            case .pending:
                Button("Cancel invite") { confirmCancel = true }
                    .buttonStyle(.cozyDestructive)
            case .accepted:
                if let chatId = invitation.chatId {
                    Button("Open chat") { app.router.openChat(chatId) }
                        .buttonStyle(.cozyPrimary)
                }
                if invitation.endsAt > .now {
                    Button("Cancel session") { confirmCancel = true }
                        .buttonStyle(.cozyDestructive)
                }
            case .declined, .cancelled, .expired:
                EmptyView()
            }
        }
        .disabled(working)
    }

    private func perform(_ action: @escaping () async throws -> Invitation) {
        Task {
            working = true
            defer { working = false }
            do {
                let updated = try await action()
                state = .loaded(updated)
                await app.refreshBadges()
                if updated.status == .accepted, let chatId = updated.chatId {
                    app.router.openChat(chatId)
                }
            } catch {
                actionError = error.asAppError
                // `invalid_state`: it changed elsewhere (expired, cancelled); show the latest.
                if actionError?.code == .invalidState { await load() }
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await app.services.invitations.invitation(id: invitationId))
        } catch {
            let appError = error.asAppError
            state = appError == .offline ? .offline(cached: state.value, lastUpdated: nil) : .failed(appError)
        }
    }
}

#Preview("Invites") {
    NavigationStack { InvitesView() }.environment(AppModel.preview())
}

#Preview("Invite detail") {
    NavigationStack { InvitationDetailView(invitationId: DemoFixtures.id(301)) }.environment(AppModel.preview())
}

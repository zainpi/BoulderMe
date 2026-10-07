import SwiftUI

/// Incoming / Outgoing invitations. T7 adds sections, paging and the full
/// detail flow; accept / decline / cancel already work against demo services.
struct InvitesView: View {
    @Environment(AppModel.self) private var app
    @State private var box: InvitationBox = .incoming
    @State private var state: LoadState<[Invitation]> = .loading

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
                    VStack(spacing: Spacing.m) {
                        if invitations.isEmpty {
                            EmptyStateView(
                                systemImage: box == .incoming ? "envelope.open" : "paperplane",
                                title: box == .incoming ? "No invites yet" : "Nothing sent yet",
                                message: box == .incoming
                                    ? "When someone invites you to climb, it shows up here."
                                    : "Find a climber in Discover and invite them to a session.")
                        } else {
                            ForEach(invitations) { invitation in
                                NavigationLink(value: InvitesRoute.invitation(invitation.invitationId)) {
                                    InvitationRow(invitation: invitation, box: box)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(Spacing.m)
                }
                .refreshable { await load() }
            }
        }
        .cozyNavigation(title: "Invites")
        .task(id: box) { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await app.services.invitations.invitations(box: box, cursor: nil).items)
        } catch {
            state = .failed(error.asAppError)
        }
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
            Label(invitation.proposedStartAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                .font(Typography.callout)
                .foregroundStyle(Palette.ink)
        }
        .accessibilityElement(children: .combine)
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

struct InvitationDetailView: View {
    let invitationId: EntityID
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<Invitation> = .loading
    @State private var actionError: AppError?

    var body: some View {
        LoadStateView(state: state, retry: { Task { await load() } }) { invitation in
            let incoming = invitation.recipient.accountId == app.currentAccountId
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    InvitationRow(invitation: invitation, box: incoming ? .incoming : .outgoing)
                    if let note = invitation.note {
                        CozyCard {
                            SectionHeader(title: "Note")
                            Text(note).font(Typography.body).foregroundStyle(Palette.ink)
                        }
                    }
                    actions(invitation, incoming: incoming)
                }
                .padding(Spacing.m)
            }
        }
        .cozyNavigation(title: "Invite")
        .navigationBarTitleDisplayMode(.inline)
        .alert(actionError?.title ?? "", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError?.userMessage ?? "")
        }
        .task { await load() }
    }

    @ViewBuilder
    private func actions(_ invitation: Invitation, incoming: Bool) -> some View {
        VStack(spacing: Spacing.s) {
            switch (invitation.status, incoming) {
            case (.pending, true):
                Button("Accept") { perform { try await app.services.invitations.accept(id: invitationId) } }
                    .buttonStyle(.cozyPrimary)
                Button("Decline") { perform { try await app.services.invitations.decline(id: invitationId) } }
                    .buttonStyle(.cozySecondary)
            case (.pending, false), (.accepted, _):
                if let chatId = invitation.chatId {
                    Button("Open chat") { app.router.openChat(chatId) }
                        .buttonStyle(.cozyPrimary)
                }
                Button("Cancel invite") { perform { try await app.services.invitations.cancel(id: invitationId) } }
                    .buttonStyle(.cozyDestructive)
            default:
                EmptyView()
            }
        }
    }

    private func perform(_ action: @escaping () async throws -> Invitation) {
        Task {
            do {
                let updated = try await action()
                state = .loaded(updated)
                await app.refreshBadges()
                if updated.status == .accepted, let chatId = updated.chatId {
                    app.router.openChat(chatId)
                }
            } catch {
                actionError = error.asAppError
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await app.services.invitations.invitation(id: invitationId))
        } catch {
            state = .failed(error.asAppError)
        }
    }
}

#Preview("Invites") {
    NavigationStack { InvitesView() }.environment(AppModel.preview())
}

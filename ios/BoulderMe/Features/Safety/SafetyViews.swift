import SwiftUI

// Report and block, reachable from a profile, an invitation and a chat
// (docs/screen-map.md, global sheets). Both are silent: the other climber is
// never told. The Worker enforces the rules; these screens explain them.

/// Who (and what) is being reported.
struct ReportTarget: Identifiable, Hashable {
    var accountId: EntityID
    var displayName: String
    var context: ReportContext
    var invitationId: EntityID?
    var messageId: EntityID?

    var id: String { "\(accountId)-\(context.rawValue)-\(invitationId?.description ?? "")-\(messageId?.description ?? "")" }

    static func profile(_ accountId: EntityID, name: String) -> ReportTarget {
        ReportTarget(accountId: accountId, displayName: name, context: .profile)
    }

    static func invitation(_ invitation: Invitation, from party: InvitationParty) -> ReportTarget {
        ReportTarget(accountId: party.accountId, displayName: party.displayName, context: .invitation,
                     invitationId: invitation.invitationId)
    }

    static func message(_ message: Message, from party: InvitationParty) -> ReportTarget {
        ReportTarget(accountId: party.accountId, displayName: party.displayName, context: .message,
                     messageId: message.messageId)
    }

    var subject: String {
        switch context {
        case .profile: "\(displayName)'s profile"
        case .invitation: "this invite from \(displayName)"
        case .message: "this message from \(displayName)"
        }
    }
}

/// Reason list, optional details and an "Also block" toggle.
struct ReportSheet: View {
    let target: ReportTarget
    /// Called after a block that was filed with the report.
    var onBlocked: () -> Void = {}
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason?
    @State private var details = ""
    @State private var alsoBlock = false
    @State private var sending = false
    @State private var error: AppError?
    @State private var sent = false
    @State private var blocked = false
    /// Reused when the member retries, so a retry never files the report twice.
    @State private var idempotencyKey = UUID()

    static let detailsLimit = 1000

    var body: some View {
        NavigationStack {
            Group {
                if sent { thanks } else { form }
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !sent {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            }
        }
        .interactiveDismissDisabled(sending)
        // Leave the blocked member's screen only once this sheet has closed.
        .onDisappear { if blocked { onBlocked() } }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("What's wrong with \(target.subject)?")
                    .font(Typography.title)
                    .foregroundStyle(Palette.ink)
                Text("\(target.displayName) won't know who reported them. We review every report.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.inkSecondary)
                ForEach(ReportReason.allCases) { option in
                    ChoiceRow(title: option.title, isSelected: reason == option) {
                        reason = option
                        error = nil
                    }
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Anything else? (optional)").font(Typography.headline).foregroundStyle(Palette.ink)
                    TextField("What happened", text: $details, axis: .vertical)
                        .lineLimit(3...8)
                        .cozyField()
                        .onChange(of: details) { _, value in
                            if value.count > Self.detailsLimit { details = String(value.prefix(Self.detailsLimit)) }
                        }
                    Text("\(details.count)/\(Self.detailsLimit)")
                        .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Toggle(isOn: $alsoBlock) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("Also block \(target.displayName)").font(Typography.body).foregroundStyle(Palette.ink)
                        Text("You'll stop seeing each other everywhere, and your chat closes.")
                            .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                    }
                }
                .tint(Palette.accent)
                if let error {
                    Text(error.userMessage).font(Typography.callout).foregroundStyle(Palette.danger)
                }
                Button(sending ? "Sending…" : "Send report") { Task { await send() } }
                    .buttonStyle(.cozyPrimary)
                    .disabled(reason == nil || sending)
            }
            .padding(Spacing.m)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var thanks: some View {
        VStack(spacing: Spacing.m) {
            EmptyStateView(
                systemImage: "checkmark.shield.fill",
                title: "Thanks for telling us",
                message: alsoBlock
                    ? "We'll take a look. \(target.displayName) is blocked and can't see you anymore."
                    : "We'll take a look. You can block \(target.displayName) any time from their profile.")
            Button("Done") { dismiss() }
                .buttonStyle(.cozyPrimary)
                .padding(.horizontal, Spacing.m)
        }
    }

    private func send() async {
        guard let reason else { return }
        sending = true
        defer { sending = false }
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = ReportInput(reportedAccountId: target.accountId, context: target.context,
                                invitationId: target.invitationId, messageId: target.messageId,
                                reason: reason, details: trimmed.isEmpty ? nil : trimmed)
        do {
            _ = try await app.services.safety.report(input, idempotencyKey: idempotencyKey)
            if alsoBlock {
                _ = try await app.services.safety.block(accountId: target.accountId)
                blocked = true
                app.didBlock()
            }
            sent = true
        } catch {
            let appError = error.asAppError
            self.error = appError
            // A network failure retries with the same key; anything else starts fresh.
            if appError != .offline { idempotencyKey = UUID() }
        }
    }
}

/// Who is about to be blocked.
struct BlockTarget: Identifiable, Hashable {
    var accountId: EntityID
    var displayName: String
    var id: EntityID { accountId }
}

extension View {
    /// The block confirmation: explains it's silent and closes the chat, then blocks.
    /// `onBlocked` runs after the server confirms (usually to leave the screen).
    func blockConfirmation(_ target: Binding<BlockTarget?>, onBlocked: @escaping () -> Void) -> some View {
        modifier(BlockConfirmation(target: target, onBlocked: onBlocked))
    }
}

private struct BlockConfirmation: ViewModifier {
    @Binding var target: BlockTarget?
    let onBlocked: () -> Void
    @Environment(AppModel.self) private var app
    @State private var error: AppError?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Block \(target?.displayName ?? "this climber")?",
                isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                titleVisibility: .visible,
                presenting: target
            ) { target in
                Button("Block \(target.displayName)", role: .destructive) {
                    Task { await block(target) }
                }
            } message: { target in
                Text("You won't see each other in discovery, invites or chats. Open invites are cancelled and your chat closes. \(target.displayName) isn't told.")
            }
            .alert(error?.title ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error?.userMessage ?? "")
            }
    }

    private func block(_ target: BlockTarget) async {
        do {
            _ = try await app.services.safety.block(accountId: target.accountId)
            app.didBlock()
            onBlocked()
        } catch {
            self.error = error.asAppError
        }
    }
}

/// Settings → Blocked climbers. Unblocking doesn't reopen old chats or invites.
struct BlockedClimbersView: View {
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<[Block]> = .loading
    @State private var nextCursor: String?
    @State private var confirmUnblock: Block?
    @State private var error: AppError?

    var body: some View {
        LoadStateView(state: state, retry: { Task { await load() } }) { blocks in
            List {
                if blocks.isEmpty {
                    EmptyStateView(systemImage: "hand.raised.fill", title: "No one's blocked",
                                   message: "You haven't blocked anyone.")
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(blocks) { block in
                            HStack(spacing: Spacing.s) {
                                Avatar(name: block.displayName, seed: block.blockedAccountId, size: 40)
                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    Text(block.displayName).font(Typography.headline).foregroundStyle(Palette.ink)
                                    Text("Blocked \(block.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                                }
                                Spacer(minLength: 0)
                                Button("Unblock") { confirmUnblock = block }
                                    .font(Typography.callout.weight(.semibold))
                                    .buttonStyle(.borderless)
                                    .tint(Palette.accent)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAction(named: "Unblock") { confirmUnblock = block }
                            .onAppear {
                                if block.id == blocks.last?.id { Task { await loadMore() } }
                            }
                        }
                    } footer: {
                        Text("Blocked climbers can't find, invite or message you, and aren't told.")
                    }
                }
            }
            .refreshable { await load() }
        }
        .cozyNavigation(title: "Blocked climbers")
        .confirmationDialog("Unblock \(confirmUnblock?.displayName ?? "")?",
                            isPresented: Binding(get: { confirmUnblock != nil }, set: { if !$0 { confirmUnblock = nil } }),
                            titleVisibility: .visible, presenting: confirmUnblock) { block in
            Button("Unblock") { Task { await unblock(block) } }
        } message: { _ in
            Text("You'll be able to see each other again. Your old chat stays closed until a new invite is accepted.")
        }
        .alert(error?.title ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error?.userMessage ?? "")
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let page = try await app.services.safety.blocks(cursor: nil)
            nextCursor = page.nextCursor
            state = .loaded(page.items)
        } catch {
            let appError = error.asAppError
            state = appError == .offline ? .offline(cached: state.value, lastUpdated: nil) : .failed(appError)
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor, case let .loaded(blocks) = state else { return }
        nextCursor = nil
        if let page = try? await app.services.safety.blocks(cursor: cursor) {
            nextCursor = page.nextCursor
            state = .loaded(blocks + page.items)
        } else {
            nextCursor = cursor
        }
    }

    private func unblock(_ block: Block) async {
        do {
            try await app.services.safety.unblock(accountId: block.blockedAccountId)
            if case let .loaded(blocks) = state {
                state = .loaded(blocks.filter { $0.id != block.id })
            }
            app.didBlock()
        } catch {
            self.error = error.asAppError
        }
    }
}

#Preview("Report") {
    ReportSheet(target: .profile(DemoFixtures.id(11), name: "Maya"))
        .environment(AppModel.preview())
}

#Preview("Blocked climbers") {
    NavigationStack { BlockedClimbersView() }.environment(AppModel.preview())
}

import SwiftUI
import UIKit

/// Chat list. Chats exist only after an invite is accepted.
struct ChatsView: View {
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<[Chat]> = .loading
    @State private var nextCursor: String?
    @State private var lastUpdated: Date?

    var body: some View {
        LoadStateView(state: state, retry: { Task { await load() } }) { chats in
            ScrollView {
                LazyVStack(spacing: Spacing.m) {
                    if chats.isEmpty {
                        EmptyStateView(systemImage: "bubble.left.and.bubble.right",
                                       title: "No chats yet",
                                       message: "Chats open once an invite is accepted.",
                                       actionTitle: "See invites",
                                       action: { app.router.selectedTab = .invites })
                    } else {
                        ForEach(chats) { chat in
                            NavigationLink(value: ChatsRoute.chat(chat.chatId)) {
                                ChatRow(chat: chat)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if chat.id == chats.last?.id { Task { await loadMore() } }
                            }
                        }
                    }
                }
                .padding(Spacing.m)
            }
            .refreshable { await load() }
        }
        .cozyNavigation(title: "Chats")
        .task(id: app.blockRevision) { await load() }
        .onAppear { if state.value != nil { Task { await load() } } }
    }

    private func load() async {
        do {
            let page = try await app.services.chats.chats(cursor: nil)
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
        guard let cursor = nextCursor, case let .loaded(chats) = state else { return }
        nextCursor = nil
        do {
            let page = try await app.services.chats.chats(cursor: cursor)
            let known = Set(chats.map(\.id))
            nextCursor = page.nextCursor
            state = .loaded(chats + page.items.filter { !known.contains($0.id) })
        } catch {
            nextCursor = cursor
        }
    }
}

struct ChatRow: View {
    let chat: Chat

    var body: some View {
        CozyCard {
            HStack(spacing: Spacing.s) {
                Avatar(name: chat.otherMember.displayName, seed: chat.otherMember.accountId, size: 44)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack {
                        Text(chat.otherMember.displayName).font(Typography.headline).foregroundStyle(Palette.ink)
                        if chat.status == .closed {
                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(Palette.inkSecondary)
                                .accessibilityLabel("Closed")
                        }
                    }
                    Text(chat.lastMessage?.body ?? "Say hi 👋")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                    if let session = chat.upcomingSession {
                        Label(session.proposedStartAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.denim)
                    }
                }
                Spacer(minLength: 0)
                if chat.unreadCount > 0 {
                    Text("\(chat.unreadCount)")
                        .font(Typography.caption.weight(.bold))
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, Spacing.xxs)
                        .background(Palette.accent, in: Capsule())
                        .accessibilityLabel("\(chat.unreadCount) unread")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the chat")
    }
}

/// A chat thread: history paged back, the upcoming session pinned on top,
/// polling every 5 seconds while on screen (and never in the background),
/// report from a long press on a message, and block from the menu.
struct ChatThreadView: View {
    let chatId: EntityID
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var model = ChatThreadModel()
    @State private var draft = ""
    @State private var reportTarget: ReportTarget?
    @State private var blockTarget: BlockTarget?

    static let pollInterval: Duration = .seconds(5)

    var body: some View {
        Group {
            switch model.loadError {
            case let error? where model.chat == nil:
                ScrollView { ErrorStateView(error: error) { Task { await model.loadInitial(app: app, chatId: chatId) } } }
            default:
                if model.chat == nil {
                    ScrollView { SkeletonList(count: 3).padding(Spacing.m) }
                } else {
                    thread
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let chat = model.chat { composer(chat) }
        }
        .cozyNavigation(title: model.chat?.otherMember.displayName ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .alert(model.actionError?.title ?? "", isPresented: Binding(
            get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError?.userMessage ?? "")
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(target: target, onBlocked: { dismiss() })
        }
        .blockConfirmation($blockTarget) { dismiss() }
        .task(id: scenePhase) {
            // Poll only while this screen is visible and the app is in the foreground.
            guard scenePhase == .active else { return }
            await model.loadInitial(app: app, chatId: chatId)
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { break }
                await model.poll(app: app, chatId: chatId)
            }
        }
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Spacing.xs) {
                    if model.olderCursor != nil {
                        Button(model.loadingOlder ? "Loading…" : "Load earlier messages") {
                            Task { await model.loadOlder(app: app, chatId: chatId) }
                        }
                        .font(Typography.callout.weight(.semibold))
                        .tint(Palette.accent)
                        .disabled(model.loadingOlder)
                        .padding(.bottom, Spacing.s)
                    }
                    if let session = model.chat?.upcomingSession {
                        Button { app.router.openInvitation(session.invitationId) } label: {
                            UpcomingSessionCard(invitation: session)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the invite")
                        .padding(.bottom, Spacing.s)
                    }
                    if model.messages.isEmpty {
                        Text("Say hi and sort out the details. Keep first meetups at the gym.")
                            .font(Typography.callout)
                            .foregroundStyle(Palette.inkSecondary)
                            .multilineTextAlignment(.center)
                            .padding(Spacing.l)
                    }
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                        if ChatThreadModel.showsTime(at: index, in: model.messages) {
                            Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkSecondary)
                                .padding(.top, Spacing.s)
                        }
                        bubble(message)
                            .id(message.messageId)
                    }
                }
                .padding(Spacing.m)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.last?.messageId) { _, last in
                if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
    }

    private func bubble(_ message: Message) -> some View {
        let isMine = message.senderAccountId == app.currentAccountId
        return MessageBubble(message: message, isMine: isMine,
                             senderName: isMine ? "You" : (message.senderAccountId == nil ? "Deleted climber" : model.chat?.otherMember.displayName ?? ""))
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.body }
                if !isMine, message.senderAccountId != nil, let other = model.chat?.otherMember {
                    Button("Report message", systemImage: "flag") {
                        reportTarget = .message(message, from: other)
                    }
                }
            }
            .accessibilityAction(named: "Report message") {
                if !isMine, message.senderAccountId != nil, let other = model.chat?.otherMember {
                    reportTarget = .message(message, from: other)
                }
            }
    }

    @ViewBuilder
    private var menu: some View {
        if let other = model.chat?.otherMember {
            Menu {
                if !other.isDeleted {
                    NavigationLink(value: ChatsRoute.profile(other.accountId)) {
                        Label("See profile", systemImage: "person.crop.circle")
                    }
                }
                Button("Safety tips", systemImage: "heart.text.square") { app.router.sheet = .safetyTips }
                if !other.isDeleted {
                    Button("Report \(other.displayName)", systemImage: "flag") {
                        reportTarget = .profile(other.accountId, name: other.displayName)
                    }
                    Button("Block \(other.displayName)", systemImage: "hand.raised", role: .destructive) {
                        blockTarget = BlockTarget(accountId: other.accountId, displayName: other.displayName)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("More")
            }
        }
    }

    @ViewBuilder
    private func composer(_ chat: Chat) -> some View {
        if chat.status == .closed {
            Label(chat.otherMember.isDeleted
                  ? "\(chat.otherMember.displayName) left BoulderMe, so this chat is closed."
                  : "This chat is closed. A new accepted invite opens it again.",
                  systemImage: "lock.fill")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
                .frame(maxWidth: .infinity)
                .padding(Spacing.m)
                .background(Palette.surfaceSunken)
        } else {
            HStack(spacing: Spacing.xs) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(Typography.body)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                    .onChange(of: draft) { _, value in
                        if value.count > ChatThreadModel.messageLimit { draft = String(value.prefix(ChatThreadModel.messageLimit)) }
                    }
                Button {
                    Task {
                        if await model.send(draft, app: app, chatId: chatId) { draft = "" }
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Palette.accent)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.sending)
                .accessibilityLabel("Send")
            }
            .padding(Spacing.s)
            .floatingGlass(in: RoundedRectangle(cornerRadius: Radius.l + Spacing.s, style: .continuous))
            .padding(.horizontal, Spacing.s)
            .padding(.bottom, Spacing.xs)
        }
    }
}

/// State and server calls for one chat thread, kept apart from the view so the
/// polling and paging rules can be tested.
@MainActor
@Observable
final class ChatThreadModel {
    private(set) var chat: Chat?
    /// Oldest first.
    private(set) var messages: [Message] = []
    /// Cursor for the next older page, `nil` when the start of the chat is loaded.
    private(set) var olderCursor: String?
    private(set) var loadingOlder = false
    private(set) var sending = false
    /// Set when the chat can't be shown at all (blocked, gone, offline on first load).
    private(set) var loadError: AppError?
    /// A send or other action failed.
    var actionError: AppError?
    /// Kept for a failed send, so retrying the same text never posts it twice.
    private var pendingSend: (body: String, key: UUID)?
    private var pollsSinceChatRefresh = 0

    static let messageLimit = 1000
    /// Re-read the chat (status, upcoming session) every this many polls.
    static let chatRefreshEvery = 6

    func loadInitial(app: AppModel, chatId: EntityID) async {
        do {
            let chat = try await app.services.chats.chat(id: chatId)
            let page = try await app.services.chats.messages(chatId: chatId, after: nil, cursor: nil)
            self.chat = chat
            // Keep anything older the member already paged back to.
            merge(page.items)
            if messages.count <= page.items.count { olderCursor = page.nextCursor }
            loadError = nil
            await app.refreshBadges()
        } catch {
            guard !Task.isCancelled else { return }
            handle(error.asAppError)
        }
    }

    func poll(app: AppModel, chatId: EntityID) async {
        do {
            let page: Page<Message>
            if let last = messages.last?.messageId {
                page = try await app.services.chats.messages(chatId: chatId, after: last, cursor: nil)
            } else {
                page = try await app.services.chats.messages(chatId: chatId, after: nil, cursor: nil)
                olderCursor = page.nextCursor
            }
            merge(page.items)
            pollsSinceChatRefresh += 1
            if !page.items.isEmpty || pollsSinceChatRefresh >= Self.chatRefreshEvery {
                pollsSinceChatRefresh = 0
                chat = try await app.services.chats.chat(id: chatId)
                if !page.items.isEmpty { await app.refreshBadges() }
            }
        } catch {
            // Offline or a hiccup: keep showing what we have and try again next tick.
            let appError = error.asAppError
            if appError.code == .notFound { handle(appError) }
        }
    }

    func loadOlder(app: AppModel, chatId: EntityID) async {
        guard let cursor = olderCursor, !loadingOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await app.services.chats.messages(chatId: chatId, after: nil, cursor: cursor)
            merge(page.items)
            olderCursor = page.nextCursor
        } catch {
            actionError = error.asAppError
        }
    }

    /// Returns `true` when the message was sent (the composer then clears).
    func send(_ text: String, app: AppModel, chatId: EntityID) async -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending else { return false }
        let key = pendingSend?.body == body ? pendingSend!.key : UUID()
        pendingSend = (body, key)
        sending = true
        defer { sending = false }
        do {
            let message = try await app.services.chats.send(chatId: chatId, body: body, idempotencyKey: key)
            pendingSend = nil
            merge([message])
            return true
        } catch {
            let appError = error.asAppError
            if appError.code == .chatClosed || appError.code == .notFound {
                pendingSend = nil
                if let fresh = try? await app.services.chats.chat(id: chatId) { chat = fresh }
            }
            if appError.code == .notFound { handle(appError) } else { actionError = appError }
            return false
        }
    }

    private func handle(_ error: AppError) {
        if error.code == .notFound {
            // Blocked or gone: show it as unavailable, like the Worker's `not_found`.
            chat = nil
            messages = []
        }
        if chat == nil {
            loadError = error
        } else {
            actionError = error
        }
    }

    /// Adds messages by id, keeping the list oldest first with no duplicates.
    func merge(_ incoming: [Message]) {
        guard !incoming.isEmpty else { return }
        var byId = Dictionary(messages.map { ($0.messageId, $0) }, uniquingKeysWith: { first, _ in first })
        for message in incoming { byId[message.messageId] = message }
        messages = byId.values.sorted { ($0.createdAt, $0.messageId.description) < ($1.createdAt, $1.messageId.description) }
    }

    /// A time caption before the first message and after a 30 minute gap.
    static func showsTime(at index: Int, in messages: [Message]) -> Bool {
        guard index > 0 else { return true }
        return messages[index].createdAt.timeIntervalSince(messages[index - 1].createdAt) > 30 * 60
    }
}

struct MessageBubble: View {
    let message: Message
    let isMine: Bool
    var senderName = ""

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: Spacing.xxl) }
            Text(message.body)
                .font(Typography.body)
                .foregroundStyle(isMine ? Palette.onAccent : Palette.ink)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
                .background(isMine ? Palette.accent : Palette.surface,
                            in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                .textSelection(.enabled)
            if !isMine { Spacer(minLength: Spacing.xxl) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isMine ? "You" : senderName): \(message.body)")
        .accessibilityValue(message.createdAt.formatted(date: .omitted, time: .shortened))
    }
}

struct UpcomingSessionCard: View {
    let invitation: Invitation

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "calendar.badge.clock")
                .font(.title2)
                .foregroundStyle(Palette.denim)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Upcoming session").font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                Text(invitation.proposedStartAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Typography.headline).foregroundStyle(Palette.ink)
                Text("\(invitation.gym.name) · \(InviteSheet.durationLabel(invitation.durationMinutes))")
                    .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Palette.inkSecondary)
                .accessibilityHidden(true)
        }
        .padding(Spacing.m)
        .background(Palette.denim.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview("Chats") {
    NavigationStack { ChatsView() }.environment(AppModel.preview())
}

#Preview("Chat thread") {
    NavigationStack { ChatThreadView(chatId: DemoFixtures.id(401)) }.environment(AppModel.preview())
}

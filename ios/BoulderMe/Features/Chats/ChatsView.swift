import SwiftUI

/// Chat list. Chats exist only after an invite is accepted.
struct ChatsView: View {
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<[Chat]> = .loading

    var body: some View {
        LoadStateView(state: state, retry: { Task { await load() } }) { chats in
            ScrollView {
                VStack(spacing: Spacing.m) {
                    if chats.isEmpty {
                        EmptyStateView(systemImage: "bubble.left.and.bubble.right",
                                       title: "No chats yet",
                                       message: "Chats open once an invite is accepted.")
                    } else {
                        ForEach(chats) { chat in
                            NavigationLink(value: ChatsRoute.chat(chat.chatId)) {
                                ChatRow(chat: chat)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(Spacing.m)
            }
            .refreshable { await load() }
        }
        .cozyNavigation(title: "Chats")
        .task { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await app.services.chats.chats(cursor: nil).items)
        } catch {
            state = .failed(error.asAppError)
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
    }
}

/// A basic thread: history, a pinned upcoming session, polling every 5 seconds
/// while visible, and a composer. T7 adds paging back, report and block.
struct ChatThreadView: View {
    let chatId: EntityID
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var chat: Chat?
    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var error: AppError?

    static let pollInterval: Duration = .seconds(5)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Spacing.xs) {
                    if let session = chat?.upcomingSession {
                        UpcomingSessionCard(invitation: session)
                            .padding(.bottom, Spacing.s)
                    }
                    ForEach(messages) { message in
                        MessageBubble(message: message, isMine: message.senderAccountId == app.currentAccountId)
                            .id(message.messageId)
                    }
                }
                .padding(Spacing.m)
            }
            .onChange(of: messages.last?.messageId) { _, last in
                if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .cozyNavigation(title: chat?.otherMember.displayName ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    app.router.sheet = .safetyTips
                } label: {
                    Image(systemName: "heart.text.square").accessibilityLabel("Safety tips")
                }
            }
        }
        .alert(error?.title ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error?.userMessage ?? "")
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await loadInitial()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                await poll()
            }
        }
    }

    @ViewBuilder
    private var composer: some View {
        if chat?.status == .closed {
            Text(AppError.api(.chatClosed, requestId: nil).userMessage)
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
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Palette.accent)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
            .padding(Spacing.s)
            .floatingGlass(in: RoundedRectangle(cornerRadius: Radius.l + Spacing.s, style: .continuous))
            .padding(.horizontal, Spacing.s)
            .padding(.bottom, Spacing.xs)
        }
    }

    private func loadInitial() async {
        do {
            chat = try await app.services.chats.chat(id: chatId)
            let page = try await app.services.chats.messages(chatId: chatId, after: nil, cursor: nil)
            messages = page.items.reversed()
            await app.refreshBadges()
        } catch {
            self.error = error.asAppError
        }
    }

    private func poll() async {
        guard let last = messages.last?.messageId,
              let page = try? await app.services.chats.messages(chatId: chatId, after: last, cursor: nil) else { return }
        messages.append(contentsOf: page.items)
    }

    private func send() async {
        let body = draft
        draft = ""
        do {
            let message = try await app.services.chats.send(chatId: chatId, body: body, idempotencyKey: UUID())
            messages.append(message)
        } catch {
            draft = body
            self.error = error.asAppError
        }
    }
}

struct MessageBubble: View {
    let message: Message
    let isMine: Bool

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
            if !isMine { Spacer(minLength: Spacing.xxl) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isMine ? "You: \(message.body)" : message.body)
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
                Text(invitation.gym.name).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .background(Palette.denim.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview("Chats") {
    NavigationStack { ChatsView() }.environment(AppModel.preview())
}

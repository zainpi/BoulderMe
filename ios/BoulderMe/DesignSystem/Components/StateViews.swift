import SwiftUI

/// The five states every data screen implements (docs/screen-map.md).
enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(AppError)
    /// Offline with cached data: show it with a "last updated" note.
    case offline(cached: Value?, lastUpdated: Date?)

    var value: Value? {
        switch self {
        case let .loaded(value): value
        case let .offline(cached, _): cached
        default: nil
        }
    }
}

/// Friendly illustration + one action.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.m) {
            ZStack {
                Circle().fill(Palette.accentSoft).frame(width: 112, height: 112)
                Image(systemName: systemImage)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.accent)
            }
            .accessibilityHidden(true)
            Text(title)
                .font(Typography.title)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Typography.body)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.cozyPrimary)
                    .padding(.top, Spacing.xs)
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }
}

/// Error from an error code + Retry.
struct ErrorStateView: View {
    let error: AppError
    var retry: (() -> Void)?

    var body: some View {
        EmptyStateView(
            systemImage: error == .offline ? "wifi.slash" : "exclamationmark.bubble.fill",
            title: error.title,
            message: error.userMessage,
            actionTitle: retry == nil ? nil : "Try again",
            action: retry)
    }
}

/// Shown above cached content when offline. Writes are disabled with a reason.
struct OfflineBanner: View {
    var lastUpdated: Date?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "wifi.slash")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("You're offline")
                    .font(Typography.caption.weight(.bold))
                if let lastUpdated {
                    Text("Last updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                        .font(Typography.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.ink)
        .padding(Spacing.s)
        .background(Palette.sunny.opacity(0.3), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Skeleton card for loading states (no spinners on cozy surfaces).
struct SkeletonCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        CozyCard {
            HStack(spacing: Spacing.s) {
                Circle().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    RoundedRectangle(cornerRadius: 6).frame(width: 120, height: 14)
                    RoundedRectangle(cornerRadius: 6).frame(width: 180, height: 10)
                }
            }
            RoundedRectangle(cornerRadius: 6).frame(height: 10)
        }
        .foregroundStyle(Palette.surfaceSunken)
        .opacity(pulse ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityHidden(true)
    }
}

struct SkeletonList: View {
    var count = 3

    var body: some View {
        VStack(spacing: Spacing.m) {
            ForEach(0..<count, id: \.self) { _ in SkeletonCard() }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// Renders a `LoadState` with the shared loading / error / offline views and
/// hands loaded (or cached) values to `content`.
struct LoadStateView<Value, Content: View>: View {
    let state: LoadState<Value>
    var retry: (() -> Void)?
    @ViewBuilder var content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            ScrollView { SkeletonList().padding(Spacing.m) }
        case let .failed(error):
            ScrollView { ErrorStateView(error: error, retry: retry).padding(.top, Spacing.xxl) }
        case let .loaded(value):
            content(value)
        case let .offline(cached, lastUpdated):
            VStack(spacing: Spacing.s) {
                OfflineBanner(lastUpdated: lastUpdated).padding(.horizontal, Spacing.m)
                if let cached {
                    content(cached)
                } else {
                    ErrorStateView(error: .offline, retry: retry)
                    Spacer()
                }
            }
        }
    }
}

#Preview("States") {
    ScrollView {
        VStack(spacing: Spacing.xl) {
            SkeletonList(count: 2)
            EmptyStateView(systemImage: "figure.climbing", title: "No one's here yet",
                           message: "Invite a friend or try another gym.", actionTitle: "Pick a gym") {}
            ErrorStateView(error: .api(.rateLimited, requestId: nil)) {}
            OfflineBanner(lastUpdated: .now.addingTimeInterval(-600))
        }
        .padding()
    }
    .background(Palette.background)
}

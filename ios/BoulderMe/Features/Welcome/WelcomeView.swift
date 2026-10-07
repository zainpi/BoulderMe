import SwiftUI

/// First screen when signed out: Sign in with Apple, or explore the demo.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cardsIn = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                Spacer(minLength: Spacing.xl)
                hero
                VStack(spacing: Spacing.s) {
                    Text("BoulderMe")
                        .font(Typography.display)
                        .foregroundStyle(Palette.ink)
                    Text("Find climbing partners at your gym who climb like you do.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                previewStack
                if let notice = app.notice {
                    Label(notice, systemImage: "info.circle.fill")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.ink)
                        .padding(Spacing.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                }
                VStack(spacing: Spacing.s) {
                    AppleSignInButton(isWorking: app.isSigningIn) {
                        Task { await app.signInWithApple() }
                    }
                    if let error = app.signInError {
                        Text(error.userMessage)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.danger)
                            .multilineTextAlignment(.center)
                    }

                    Button("Explore the demo") { app.enterDemo() }
                        .buttonStyle(.cozySecondary)
                        .accessibilityHint("Look around with made-up climbers. Nothing is sent.")
                }
                Text("18+ only. Gym access is self-reported and never verified.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.l)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background.ignoresSafeArea())
        .onAppear {
            withAnimation(Motion.bouncy(reduceMotion: reduceMotion)?.delay(0.15)) { cardsIn = true }
        }
    }

    private var hero: some View {
        ZStack {
            Circle().fill(Palette.accent.gradient).frame(width: 132, height: 132)
            Image(systemName: "figure.climbing")
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.white)
            Circle().fill(Palette.sunny).frame(width: 26, height: 26).offset(x: 52, y: -46)
            Circle().fill(Palette.moss).frame(width: 18, height: 18).offset(x: -56, y: 40)
        }
        .accessibilityHidden(true)
    }

    /// A playful fanned stack of sample cards.
    private var previewStack: some View {
        let samples = Array(DemoFixtures.climbers(now: .now).prefix(3))
        return ZStack {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, climber in
                let profile = climber.profile
                HStack(spacing: Spacing.s) {
                    Avatar(name: profile.displayName, seed: profile.accountId, size: 40)
                    Text(profile.displayName).font(Typography.headline).foregroundStyle(Palette.ink)
                    Spacer()
                    GradeBadge(min: profile.gradeMin, max: profile.gradeMax)
                }
                .padding(Spacing.m)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).stroke(Palette.outline))
                .rotationEffect(.degrees(cardsIn ? Double(index - 1) * 4 : 0))
                .offset(y: cardsIn ? CGFloat(index) * 18 : 0)
                .zIndex(Double(-index))
            }
        }
        .padding(.bottom, Spacing.xl)
        .accessibilityHidden(true)
    }
}

/// Shown when a demo user taps something that needs a real account.
struct SignInRequiredSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Spacing.l) {
            EmptyStateView(systemImage: "person.badge.key.fill", title: AppError.requiresAccount.title,
                           message: AppError.requiresAccount.userMessage)
            AppleSignInButton(isWorking: app.isSigningIn) {
                Task {
                    await app.signInWithApple()
                    if !app.isDemo { dismiss() }
                }
            }
            if let error = app.signInError {
                Text(error.userMessage).font(Typography.caption).foregroundStyle(Palette.danger)
            }
            Button("Keep exploring") { dismiss() }
                .buttonStyle(.cozySecondary)
            Button("Leave the demo") {
                dismiss()
                app.leaveDemo()
            }
            .font(Typography.callout)
        }
        .padding(Spacing.l)
        .presentationDetents([.medium, .large])
        .background(Palette.background.ignoresSafeArea())
    }
}

/// Sign in with Apple in the system's black/white style (Apple's HIG), sized
/// like the cozy buttons. A custom button so the nonce can be fetched first.
struct AppleSignInButton: View {
    @Environment(\.colorScheme) private var colorScheme
    var isWorking = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if isWorking {
                    ProgressView().tint(colorScheme == .dark ? .black : .white)
                } else {
                    Image(systemName: "apple.logo")
                }
                Text("Sign in with Apple")
            }
            .font(.system(.headline, design: .default).weight(.semibold))
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(colorScheme == .dark ? Color.white : Color.black,
                        in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityLabel("Sign in with Apple")
    }
}

/// Static safety tips (screen map: global sheet).
struct SafetyTipsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let tips: [(String, String, String)] = [
        ("building.2.fill", "Meet at the gym", "Keep first sessions inside the gym, with staff and other climbers around."),
        ("person.2.fill", "Tell a friend", "Let someone know who you're climbing with and when."),
        ("flag.fill", "Report concerns", "Report or block anyone who makes you uncomfortable. They aren't told."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.m) {
                    ForEach(tips, id: \.1) { symbol, title, text in
                        CozyCard {
                            Label(title, systemImage: symbol)
                                .font(Typography.headline)
                                .foregroundStyle(Palette.ink)
                            Text(text).font(Typography.body).foregroundStyle(Palette.inkSecondary)
                        }
                    }
                    Button("Got it") { dismiss() }.buttonStyle(.cozyPrimary)
                }
                .padding(Spacing.m)
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Climb safe")
        }
    }
}

#Preview("Welcome") {
    WelcomeView().environment(AppModel.preview(demo: false))
}

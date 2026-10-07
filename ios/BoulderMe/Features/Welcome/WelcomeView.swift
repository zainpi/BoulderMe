import SwiftUI

/// First screen when signed out. Sign in with Apple is wired in T6; until then
/// it explains that and points to the demo.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSignInSoon = false
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
                VStack(spacing: Spacing.s) {
                    Button {
                        showSignInSoon = true
                    } label: {
                        Label("Sign in with Apple", systemImage: "apple.logo")
                    }
                    .buttonStyle(.cozyPrimary)

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
        .alert("Sign in is almost ready", isPresented: $showSignInSoon) {
            Button("Explore the demo") { app.enterDemo() }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Sign in with Apple arrives in the next build. The demo shows everything in the meantime.")
        }
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
            Button("Keep exploring") { dismiss() }
                .buttonStyle(.cozyPrimary)
            Button("Leave the demo") {
                dismiss()
                app.leaveDemo()
            }
            .buttonStyle(.cozySecondary)
        }
        .padding(Spacing.l)
        .presentationDetents([.medium, .large])
        .background(Palette.background.ignoresSafeArea())
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

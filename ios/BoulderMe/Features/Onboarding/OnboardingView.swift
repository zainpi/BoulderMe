import SwiftUI

/// Guided setup after Sign in with Apple. Resumes at the first unfinished step
/// (see `OnboardingPlan`); every step saves before moving on.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: OnboardingModel
    @State private var slots: [AvailabilitySlot] = []
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    progress
                    content
                    if let error = model.error {
                        Text(error.userMessage)
                            .font(Typography.callout)
                            .foregroundStyle(Palette.danger)
                    }
                }
                .padding(Spacing.m)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { actions }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle(model.step.title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.canGoBack {
                        Button {
                            model.back()
                        } label: {
                            Label("Back", systemImage: "chevron.backward").labelStyle(.titleAndIcon)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Sign out", role: .destructive) { confirmSignOut = true }
                    } label: {
                        Image(systemName: "ellipsis.circle").accessibilityLabel("More")
                    }
                }
            }
            .confirmationDialog("Sign out?", isPresented: $confirmSignOut) {
                Button("Sign out", role: .destructive) { Task { await app.signOut() } }
            } message: {
                Text("What you've saved so far stays with your account.")
            }
            .animation(.easeInOut(duration: 0.2), value: model.step)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Step \(model.stepNumber) of \(model.stepCount)")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
            ProgressView(value: Double(model.stepNumber), total: Double(model.stepCount))
                .tint(Palette.accent)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .basics:
            intro("Pick the name other climbers will see. You can change it any time.")
            NameIntroFields(draft: $model.draft)
            Toggle(isOn: $model.draft.adultConfirmed) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("I'm 18 or older").font(Typography.headline).foregroundStyle(Palette.ink)
                    Text("BoulderMe is for adults only.").font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                }
            }
            .tint(Palette.accent)
        case .climbing:
            intro("This helps you find partners who climb at a similar level.")
            GradeRangePicker(min: $model.draft.gradeMin, max: $model.draft.gradeMax)
            StylePicker(draft: $model.draft)
        case .gyms:
            intro("Add the gyms you climb at. Climbers only see you at gyms you've added.")
            GymsEditor(gyms: model.gyms) { model.gymsChanged($0) }
        case .availability:
            intro("Tap the times you usually climb. You can skip this and add them later.")
            AvailabilityEditor { slots = $0 }
        case .visibility:
            intro("Here's exactly what other signed-in climbers will see when you're discoverable.")
            ProfileCardView(card: model.previewCard(slots: slots))
            visibilityFacts
        case .discovery:
            intro("Turn on discovery so climbers at your gyms can find you and send invites. You can pause it any time in Settings.")
            discoveryChoice
        }
    }

    private func intro(_ text: String) -> some View {
        Text(text).font(Typography.body).foregroundStyle(Palette.inkSecondary)
    }

    private var visibilityFacts: some View {
        CozyCard {
            fact("eye.fill", "Your card shows your name, grades, styles, gyms and when you climb.")
            fact("person.2.fill", "Only signed-in members see it, and only at gyms you share.")
            fact("ticket.fill", "Gym access is self-reported and labeled that way.")
            fact("hand.raised.fill", "Chat opens only after you accept an invitation. Block or report anyone, any time.")
            fact("eye.slash.fill", "Pause discovery whenever you like. You'll disappear from search right away.")
        }
        .task {
            if slots.isEmpty, let loaded = try? await app.services.availability.slots() { slots = loaded }
        }
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(Typography.body).foregroundStyle(Palette.ink)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Palette.accent)
        }
    }

    private var discoveryChoice: some View {
        VStack(spacing: Spacing.m) {
            ZStack {
                Circle().fill(Palette.accentSoft).frame(width: 120, height: 120)
                Image(systemName: "figure.climbing").font(.system(size: 54, weight: .bold)).foregroundStyle(Palette.accent)
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: Spacing.s) {
            switch model.step {
            case .discovery:
                Button(model.isWorking ? "Saving…" : "Turn on discovery") {
                    Task { if await model.chooseDiscovery(true) { app.finishOnboarding() } }
                }
                .buttonStyle(.cozyPrimary)
                .disabled(model.isWorking)
                Button("Not now") {
                    Task { if await model.chooseDiscovery(false) { app.finishOnboarding() } }
                }
                .buttonStyle(.cozySecondary)
                .disabled(model.isWorking)
            case .availability:
                Button(model.isWorking ? "Saving…" : "Next") { Task { await model.advance() } }
                    .buttonStyle(.cozyPrimary)
                    .disabled(!model.canContinue || slots.isEmpty)
                Button("Skip for now") { model.skipAvailability() }
                    .buttonStyle(.cozySecondary)
            case .visibility:
                Button(model.isWorking ? "Saving…" : "I understand") { Task { await model.advance() } }
                    .buttonStyle(.cozyPrimary)
                    .disabled(!model.canContinue)
            default:
                Button(model.isWorking ? "Saving…" : "Next") { Task { await model.advance() } }
                    .buttonStyle(.cozyPrimary)
                    .disabled(!model.canContinue)
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .floatingGlass(in: Rectangle())
    }
}

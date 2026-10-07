import SwiftUI

/// Full-width, pill-shaped primary action.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.button)
            .foregroundStyle(Palette.onAccent)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, Spacing.l)
            .background(Palette.accent.opacity(isEnabled ? 1 : 0.4), in: Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(Motion.bouncy(reduceMotion: reduceMotion), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Soft secondary action on a tinted background.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.button)
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, Spacing.l)
            .background(Palette.accentSoft, in: Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(Motion.bouncy(reduceMotion: reduceMotion), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Destructive actions (block, delete). Same shape, danger color.
struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.button)
            .foregroundStyle(Palette.danger)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Palette.danger.opacity(configuration.isPressed ? 0.18 : 0.1), in: Capsule())
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var cozyPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var cozySecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == DestructiveButtonStyle {
    static var cozyDestructive: DestructiveButtonStyle { DestructiveButtonStyle() }
}

#Preview("Buttons") {
    VStack(spacing: Spacing.m) {
        Button("Invite to climb") {}.buttonStyle(.cozyPrimary)
        Button("Explore the demo") {}.buttonStyle(.cozySecondary)
        Button("Block") {}.buttonStyle(.cozyDestructive)
        Button("Disabled") {}.buttonStyle(.cozyPrimary).disabled(true)
    }
    .padding()
    .background(Palette.background)
}

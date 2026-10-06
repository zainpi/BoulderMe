import SwiftUI

/// A tappable row for picking one or several options (access type, report
/// reason, time of day). Large hit target, clear selected state that doesn't
/// rely on color alone.
struct ChoiceRow: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(Palette.accent)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title)
                        .font(Typography.headline)
                        .foregroundStyle(Palette.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Palette.accent : Palette.outline)
                    .accessibilityHidden(true)
            }
            .padding(Spacing.m)
            .frame(minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .fill(isSelected ? Palette.accentSoft : Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .stroke(isSelected ? Palette.accent : Palette.outline, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("Choice rows") {
    struct Demo: View {
        @State private var access: AccessType = .membership
        var body: some View {
            VStack(spacing: Spacing.s) {
                ForEach(AccessType.allCases) { type in
                    ChoiceRow(title: type.title, subtitle: "Self-reported", systemImage: type.symbol,
                              isSelected: access == type) { access = type }
                }
            }
            .padding()
            .background(Palette.background)
        }
    }
    return Demo()
}

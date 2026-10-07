import SwiftUI

/// Every token and component in one scrollable page. Reachable from Settings in
/// non-production builds; also the quickest preview to check dark mode,
/// Increase Contrast and large text.
struct DesignSystemGallery: View {
    @State private var access: AccessType = .membership
    @State private var styles: Set<ClimbingStyle> = [.slab, .crimps]

    private let swatches: [(String, Color)] = [
        ("background", Palette.background), ("surface", Palette.surface), ("surfaceSunken", Palette.surfaceSunken),
        ("ink", Palette.ink), ("inkSecondary", Palette.inkSecondary), ("accent", Palette.accent),
        ("accentSoft", Palette.accentSoft), ("sunny", Palette.sunny), ("moss", Palette.moss),
        ("denim", Palette.denim), ("wall", Palette.wall), ("danger", Palette.danger),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                SectionHeader(title: "Colors", subtitle: "Light, dark and Increase Contrast variants")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Spacing.s)], spacing: Spacing.s) {
                    ForEach(swatches, id: \.0) { name, color in
                        VStack(spacing: Spacing.xxs) {
                            RoundedRectangle(cornerRadius: Radius.s).fill(color).frame(height: 48)
                                .overlay(RoundedRectangle(cornerRadius: Radius.s).stroke(Palette.outline))
                            Text(name).font(Typography.caption).foregroundStyle(Palette.inkSecondary)
                        }
                    }
                }

                SectionHeader(title: "Type")
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Display").font(Typography.display)
                    Text("Title").font(Typography.title)
                    Text("Headline").font(Typography.headline)
                    Text("Body text for intros and messages.").font(Typography.body)
                    Text("Caption").font(Typography.caption)
                }
                .foregroundStyle(Palette.ink)

                SectionHeader(title: "Buttons")
                Button("Primary") {}.buttonStyle(.cozyPrimary)
                Button("Secondary") {}.buttonStyle(.cozySecondary)
                Button("Destructive") {}.buttonStyle(.cozyDestructive)

                SectionHeader(title: "Choice rows")
                ForEach(AccessType.allCases) { type in
                    ChoiceRow(title: type.title, subtitle: "Self-reported", systemImage: type.symbol,
                              isSelected: access == type) { access = type }
                }

                SectionHeader(title: "Chips")
                FlowLayout(spacing: Spacing.xs) {
                    ForEach(ClimbingStyle.allCases) { style in
                        Chip(title: style.title, isSelected: styles.contains(style)) {
                            if styles.contains(style) { styles.remove(style) } else if styles.count < ClimbingStyle.maxSelected { styles.insert(style) }
                        }
                    }
                }
                HStack { GradeBadge(min: 2, max: 4); DemoBadge() }

                SectionHeader(title: "Floating glass")
                Label("Filters", systemImage: "slider.horizontal.3")
                    .font(Typography.button)
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.s)
                    .floatingGlass(in: Capsule())

                SectionHeader(title: "States")
                SkeletonCard()
                OfflineBanner(lastUpdated: .now.addingTimeInterval(-300))
                CozyCard {
                    ErrorStateView(error: .offline) {}
                }
            }
            .padding(Spacing.m)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Design system")
    }
}

#Preview("Gallery, light") {
    NavigationStack { DesignSystemGallery() }
}

#Preview("Gallery, dark, large text") {
    NavigationStack { DesignSystemGallery() }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}

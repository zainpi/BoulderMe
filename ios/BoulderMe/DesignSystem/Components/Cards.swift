import SwiftUI

/// The basic cozy container: white card, soft outline, rounded corners.
struct CozyCard<Content: View>: View {
    var padding: CGFloat = Spacing.m
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .stroke(Palette.outline, lineWidth: 1)
        )
    }
}

/// Section title used above groups of cards.
struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A round initial "avatar". No photos in v1, so each climber gets a warm color
/// picked from their id.
struct Avatar: View {
    let name: String
    let seed: EntityID
    var size: CGFloat = 48

    /// Fill and a readable initial color for it, in light and dark mode.
    private static let fills: [(fill: Color, text: Color)] = [
        (Palette.accent, Palette.onAccent), (Palette.moss, Palette.onBrand), (Palette.denim, Palette.onBrand),
        (Palette.sunny, Palette.onSunny), (Palette.wall, .white),
    ]

    var body: some View {
        let style = Self.fills[abs(seed.description.hashValueStable) % Self.fills.count]
        Circle()
            .fill(style.fill.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                    .foregroundStyle(style.text)
            )
            .accessibilityHidden(true)
    }
}

private extension String {
    /// Stable across launches, unlike `hashValue`.
    var hashValueStable: Int {
        unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    }
}

/// Climber summary card used in Discover results and previews of your own card.
struct ProfileCardView: View {
    let card: ProfileCard

    var body: some View {
        CozyCard {
            HStack(alignment: .center, spacing: Spacing.s) {
                Avatar(name: card.displayName, seed: card.accountId)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.xs) {
                        Text(card.displayName)
                            .font(Typography.headline)
                            .foregroundStyle(Palette.ink)
                        if card.activeRecently {
                            Circle().fill(Palette.moss).frame(width: 8, height: 8)
                                .accessibilityLabel("Active recently")
                        }
                    }
                    AccessLabel(accessType: card.accessType)
                }
                Spacer(minLength: 0)
                GradeBadge(min: card.gradeMin, max: card.gradeMax)
            }
            ChipFlow(items: card.styles.map(\.title))
            if !card.availabilitySummary.isEmpty {
                AvailabilitySummaryView(items: card.availabilitySummary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Profile card") {
    ScrollView {
        VStack(spacing: Spacing.m) {
            ForEach(DemoFixtures.climbers(now: .now).prefix(3), id: \.profile.accountId) { climber in
                let p = climber.profile
                ProfileCardView(card: ProfileCard(
                    accountId: p.accountId, displayName: p.displayName, gradeMin: p.gradeMin, gradeMax: p.gradeMax,
                    styles: p.styles, accessType: p.gyms[0].accessType,
                    availabilitySummary: p.availability.map { .init(weekday: $0.weekday, timeOfDay: $0.timeOfDay) },
                    activeRecently: p.activeRecently))
            }
        }
        .padding()
    }
    .background(Palette.background)
}

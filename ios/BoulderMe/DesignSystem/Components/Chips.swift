import SwiftUI

/// "V3–V5" badge on a sunny hold-colored pill.
struct GradeBadge: View {
    let min: Grade
    let max: Grade

    var body: some View {
        Text(Grades.label(min: min, max: max))
            .font(Typography.headline.monospacedDigit())
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xxs + 2)
            .background(Palette.sunny.opacity(0.35), in: Capsule())
            .accessibilityLabel("Grades V\(min) to V\(max)")
    }
}

/// Small tag, optionally selectable (used for climbing styles and filters).
struct Chip: View {
    let title: String
    var isSelected = false
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            label
        }
    }

    private var label: some View {
        Text(title)
            .font(Typography.caption)
            .foregroundStyle(isSelected ? Palette.onAccent : Palette.ink)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs - 2)
            .frame(minHeight: action == nil ? 0 : 36)
            .background(isSelected ? Palette.accent : Palette.surfaceSunken, in: Capsule())
            .overlay(Capsule().stroke(isSelected ? Color.clear : Palette.outline, lineWidth: 1))
    }
}

/// Wraps chips onto as many lines as needed.
struct ChipFlow: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: Spacing.xs) {
            ForEach(items, id: \.self) { Chip(title: $0) }
        }
    }
}

/// Self-reported access label. Always says "self-reported", per the spec.
struct AccessLabel: View {
    let accessType: AccessType

    var body: some View {
        Label {
            Text("\(accessType.title) · self-reported")
        } icon: {
            Image(systemName: accessType.symbol)
        }
        .font(Typography.caption)
        .foregroundStyle(Palette.inkSecondary)
    }
}

/// "Tue evening · Sat morning" as small icon pills.
struct AvailabilitySummaryView: View {
    let items: [AvailabilitySummaryItem]

    var body: some View {
        FlowLayout(spacing: Spacing.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label("\(item.weekday.shortName) \(item.timeOfDay.title.lowercased())", systemImage: item.timeOfDay.symbol)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.denim)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, Spacing.xxs)
                    .background(Palette.denim.opacity(0.12), in: Capsule())
            }
        }
    }
}

/// Minimal flow layout: left to right, wrapping to a new row when full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview("Chips") {
    VStack(alignment: .leading, spacing: Spacing.m) {
        GradeBadge(min: 3, max: 5)
        ChipFlow(items: ClimbingStyle.allCases.map(\.title))
        HStack { Chip(title: "Selected", isSelected: true) {}; Chip(title: "Not selected") {} }
        AccessLabel(accessType: .guestPass)
        AvailabilitySummaryView(items: [.init(weekday: .tuesday, timeOfDay: .evening), .init(weekday: .saturday, timeOfDay: .morning)])
    }
    .padding()
    .background(Palette.background)
}

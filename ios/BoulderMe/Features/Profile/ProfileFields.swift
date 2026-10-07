import SwiftUI

// Profile field editors shared by onboarding and Edit profile.

/// Display name and intro, with live character counts.
struct NameIntroFields: View {
    @Binding var draft: ProfileDraft
    @FocusState private var focused: Field?

    private enum Field { case name, intro }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                fieldLabel("Display name", count: draft.displayName.count, limit: ProfileDraft.nameLimit)
                TextField("What climbers call you", text: $draft.displayName)
                    .textContentType(.givenName)
                    .submitLabel(.next)
                    .focused($focused, equals: .name)
                    .onSubmit { focused = .intro }
                    .cozyField()
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                fieldLabel("Intro (optional)", count: draft.intro.count, limit: ProfileDraft.introLimit)
                TextField("Projecting the purple V4, love a slab day…", text: $draft.intro, axis: .vertical)
                    .lineLimit(3...6)
                    .focused($focused, equals: .intro)
                    .cozyField()
            }
        }
    }

    private func fieldLabel(_ title: String, count: Int, limit: Int) -> some View {
        HStack {
            Text(title).font(Typography.headline).foregroundStyle(Palette.ink)
            Spacer()
            Text("\(count)/\(limit)")
                .font(Typography.caption)
                .foregroundStyle(count > limit ? Palette.danger : Palette.inkSecondary)
                .accessibilityLabel("\(count) of \(limit) characters")
        }
    }
}

/// V-scale range with two steppers that never cross.
struct GradeRangePicker: View {
    @Binding var min: Grade
    @Binding var max: Grade

    var body: some View {
        CozyCard {
            HStack {
                Text("Grade range").font(Typography.headline).foregroundStyle(Palette.ink)
                Spacer()
                GradeBadge(min: min, max: max)
            }
            Stepper(value: Binding(get: { min }, set: { value in
                min = value
                if max < value { max = value }
            }), in: Grades.range) {
                Text("From \(Grades.label(min))").font(Typography.body).foregroundStyle(Palette.ink)
            }
            .accessibilityValue(Grades.label(min))
            Stepper(value: Binding(get: { max }, set: { value in
                max = value
                if min > value { min = value }
            }), in: Grades.range) {
                Text("Up to \(Grades.label(max))").font(Typography.body).foregroundStyle(Palette.ink)
            }
            .accessibilityValue(Grades.label(max))
        }
    }
}

/// Style chips, up to `ClimbingStyle.maxSelected`.
struct StylePicker: View {
    @Binding var draft: ProfileDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader(title: "Styles you love",
                          subtitle: "Pick up to \(ClimbingStyle.maxSelected). \(draft.styles.count) chosen.")
            FlowLayout(spacing: Spacing.xs) {
                ForEach(ClimbingStyle.allCases) { style in
                    let selected = draft.styles.contains(style)
                    Chip(title: style.title, isSelected: selected) { draft.toggle(style) }
                        .opacity(!selected && draft.styles.count >= ClimbingStyle.maxSelected ? 0.5 : 1)
                }
            }
        }
    }
}

extension View {
    /// Rounded input field on a cozy surface.
    func cozyField() -> some View {
        self
            .font(Typography.body)
            .foregroundStyle(Palette.ink)
            .padding(Spacing.s)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).stroke(Palette.outline))
    }
}

#Preview("Profile fields") {
    struct Demo: View {
        @State private var draft = ProfileDraft()
        var body: some View {
            ScrollView {
                VStack(spacing: Spacing.l) {
                    NameIntroFields(draft: $draft)
                    GradeRangePicker(min: $draft.gradeMin, max: $draft.gradeMax)
                    StylePicker(draft: $draft)
                }
                .padding()
            }
            .background(Palette.background)
        }
    }
    return Demo()
}

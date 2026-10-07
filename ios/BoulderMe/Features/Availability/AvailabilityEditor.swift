import SwiftUI

/// Preset windows behind each cell of the weekly grid.
enum AvailabilityWindow {
    static func minutes(for timeOfDay: TimeOfDay) -> (start: Int, end: Int) {
        switch timeOfDay {
        case .morning: (420, 720)     // 7:00–12:00
        case .afternoon: (720, 1020)  // 12:00–17:00
        case .evening: (1020, 1320)   // 17:00–22:00
        }
    }

    static func label(for timeOfDay: TimeOfDay) -> String {
        switch timeOfDay {
        case .morning: "7–12"
        case .afternoon: "12–5"
        case .evening: "5–10"
        }
    }

    static func input(weekday: Weekday, timeOfDay: TimeOfDay, timeZone: TimeZone = .current) -> AvailabilitySlotInput {
        let window = minutes(for: timeOfDay)
        return AvailabilitySlotInput(weekday: weekday, startMinute: window.start, endMinute: window.end,
                                     timeZone: timeZone.identifier, gymId: nil)
    }
}

/// Weekday × morning/afternoon/evening grid. Each tap saves right away.
struct AvailabilityEditor: View {
    @Environment(AppModel.self) private var app
    /// Called with the current slots after loading and after every change.
    var onChange: ([AvailabilitySlot]) -> Void = { _ in }

    @State private var state: LoadState<[AvailabilitySlot]> = .loading
    @State private var working: Set<String> = []
    @State private var error: AppError?

    var body: some View {
        Group {
            switch state {
            case .loading:
                SkeletonList(count: 2)
            case let .failed(error):
                ErrorStateView(error: error) { Task { await load() } }
            case .loaded, .offline:
                grid(state.value ?? [])
            }
        }
        .task { await load() }
    }

    private func grid(_ slots: [AvailabilitySlot]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                Text("").frame(width: 44)
                ForEach(TimeOfDay.allCases) { time in
                    VStack(spacing: 2) {
                        Image(systemName: time.symbol).foregroundStyle(Palette.accent)
                        Text(time.title).font(Typography.caption).foregroundStyle(Palette.ink)
                        Text(AvailabilityWindow.label(for: time)).font(.caption2).foregroundStyle(Palette.inkSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                }
            }
            ForEach(Weekday.allCases) { day in
                HStack(spacing: Spacing.xs) {
                    Text(day.shortName)
                        .font(Typography.headline)
                        .foregroundStyle(Palette.ink)
                        .frame(width: 44, alignment: .leading)
                    ForEach(TimeOfDay.allCases) { time in
                        cell(day: day, time: time, slots: slots)
                    }
                }
            }
            if let error {
                Text(error.userMessage).font(Typography.caption).foregroundStyle(Palette.danger)
            }
            Text("Times are in your time zone (\(TimeZone.current.identifier)).")
                .font(Typography.caption).foregroundStyle(Palette.inkSecondary)
        }
    }

    private func cell(day: Weekday, time: TimeOfDay, slots: [AvailabilitySlot]) -> some View {
        let matching = slots.filter { $0.weekday == day && $0.timeOfDay == time }
        let isOn = !matching.isEmpty
        let key = "\(day.rawValue)-\(time.rawValue)"
        return Button {
            Task { await toggle(day: day, time: time, matching: matching, key: key) }
        } label: {
            Image(systemName: isOn ? "checkmark" : "plus")
                .font(.body.weight(.bold))
                .foregroundStyle(isOn ? Palette.onAccent : Palette.inkSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(isOn ? Palette.accent : Palette.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).stroke(isOn ? Color.clear : Palette.outline))
                .opacity(working.contains(key) ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(working.contains(key))
        .accessibilityLabel("\(day.shortName) \(time.title)")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private func load() async {
        do {
            let slots = try await app.services.availability.slots()
            state = .loaded(slots)
            onChange(slots)
        } catch {
            state = .failed(error.asAppError)
        }
    }

    private func toggle(day: Weekday, time: TimeOfDay, matching: [AvailabilitySlot], key: String) async {
        working.insert(key)
        defer { working.remove(key) }
        do {
            if matching.isEmpty {
                let slot = try await app.services.availability.addSlot(AvailabilityWindow.input(weekday: day, timeOfDay: time))
                update { list in list.append(slot) }
            } else {
                for slot in matching {
                    try await app.services.availability.removeSlot(id: slot.slotId)
                    update { list in list.removeAll { $0.slotId == slot.slotId } }
                }
            }
            error = nil
        } catch {
            self.error = error.asAppError
        }
    }

    /// Applies a change to the latest slots (other cells may have saved meanwhile).
    private func update(_ change: (inout [AvailabilitySlot]) -> Void) {
        var slots = state.value ?? []
        change(&slots)
        state = .loaded(slots)
        onChange(slots)
    }
}

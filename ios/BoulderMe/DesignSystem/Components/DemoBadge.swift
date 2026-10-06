import SwiftUI

/// The persistent "Demo" label shown in every navigation bar while in demo mode.
struct DemoBadge: View {
    var body: some View {
        Label("Demo", systemImage: "sparkles")
            .font(Typography.caption.weight(.bold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xxs)
            .background(Palette.sunny, in: Capsule())
            .accessibilityLabel("Demo mode. Data is made up and nothing is sent.")
    }
}

extension View {
    /// Adds the shared nav bar styling plus the Demo label when in demo mode.
    func cozyNavigation(title: String) -> some View {
        modifier(CozyNavigationModifier(title: title))
    }
}

private struct CozyNavigationModifier: ViewModifier {
    let title: String
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .toolbar {
                if app.isDemo {
                    ToolbarItem(placement: .topBarLeading) { DemoBadge() }
                }
            }
            .background(Palette.background.ignoresSafeArea())
            .scrollContentBackground(.hidden)
    }
}

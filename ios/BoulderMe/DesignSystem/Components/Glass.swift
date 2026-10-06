import SwiftUI

extension View {
    /// Liquid Glass for floating controls only (a floating action, a filter
    /// pill). On iOS 26 this uses the system glass effect; earlier versions get
    /// a material. Reduce Transparency always gets a solid surface.
    func floatingGlass<S: Shape>(in shape: S) -> some View {
        modifier(FloatingGlassModifier(shape: shape))
    }
}

private struct FloatingGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Palette.surface, in: shape)
                .overlay(shape.stroke(Palette.outline, lineWidth: 1))
        } else {
            glass(content)
        }
    }

    @ViewBuilder
    private func glass(_ content: Content) -> some View {
        // `glassEffect` only exists in the iOS 26 SDK (Swift 6.2, Xcode 26).
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
        #else
        content.background(.regularMaterial, in: shape)
        #endif
    }
}

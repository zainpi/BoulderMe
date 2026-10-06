import SwiftUI

/// Spacing scale (points). Use these instead of literal paddings.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
}

/// Corner radii. Cozy means soft: cards are generously rounded.
enum Radius {
    static let s: CGFloat = 10
    static let m: CGFloat = 16
    static let l: CGFloat = 24
}

/// Type styles. All are Dynamic Type text styles in SF Rounded, so they scale
/// with the user's text size setting.
enum Typography {
    static let display = Font.system(.largeTitle, design: .rounded).weight(.heavy)
    static let title = Font.system(.title2, design: .rounded).weight(.bold)
    static let headline = Font.system(.headline, design: .rounded)
    static let body = Font.system(.body, design: .rounded)
    static let callout = Font.system(.callout, design: .rounded)
    static let caption = Font.system(.caption, design: .rounded).weight(.medium)
    static let button = Font.system(.headline, design: .rounded).weight(.bold)
}

/// Motion that respects Reduce Motion.
enum Motion {
    static func bouncy(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7)
    }
}

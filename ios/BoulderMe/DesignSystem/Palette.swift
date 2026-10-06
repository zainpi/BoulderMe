import SwiftUI
import UIKit

/// Semantic colors for BoulderMe's cozy look, drawn from the app icon: warm
/// orange, chalky cream, charcoal wall, sunny holds, moss and denim.
///
/// Each color resolves for light, dark, and Increase Contrast. Screens use
/// these names only, never raw hex values.
enum Palette {
    // Surfaces
    static let background = dynamic(light: 0xFFF6EC, dark: 0x1C1613, lightHC: 0xFFFBF6, darkHC: 0x000000)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x2A221D, lightHC: 0xFFFFFF, darkHC: 0x1A1512)
    static let surfaceSunken = dynamic(light: 0xFBE9D7, dark: 0x231C18, lightHC: 0xF4DCC4, darkHC: 0x120E0C)
    static let outline = dynamic(light: 0xEED6BF, dark: 0x45372E, lightHC: 0x8A6F5B, darkHC: 0xB59A85)

    // Text
    static let ink = dynamic(light: 0x2B211C, dark: 0xFBEFE4, lightHC: 0x000000, darkHC: 0xFFFFFF)
    static let inkSecondary = dynamic(light: 0x6B5A4F, dark: 0xCBB8AA, lightHC: 0x3D302A, darkHC: 0xEADBCF)

    // Brand
    /// Primary actions. White text on it in light mode, dark ink on it in dark mode.
    static let accent = dynamic(light: 0xBF4A00, dark: 0xFF8A3D, lightHC: 0xA33E00, darkHC: 0xFFB27F)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x1C1613, lightHC: 0xFFFFFF, darkHC: 0x000000)
    static let accentSoft = dynamic(light: 0xFFE3CC, dark: 0x4A2A14, lightHC: 0xFFD3B0, darkHC: 0x5C3214)
    static let sunny = dynamic(light: 0xF5B700, dark: 0xFFCB3D, lightHC: 0xB88900, darkHC: 0xFFDA75)
    static let moss = dynamic(light: 0x55703A, dark: 0xA3C27A, lightHC: 0x3B5226, darkHC: 0xC4DDA2)
    static let denim = dynamic(light: 0x2F5F8A, dark: 0x8DB7DE, lightHC: 0x1E4466, darkHC: 0xB8D4EE)
    static let wall = dynamic(light: 0x3A2F2C, dark: 0x5A4A44, lightHC: 0x231C1A, darkHC: 0x7A6860)

    // Feedback
    static let danger = dynamic(light: 0xB3261E, dark: 0xFF8A7A, lightHC: 0x8C1D17, darkHC: 0xFFB4A9)
    static let success = moss

    private static func dynamic(light: UInt32, dark: UInt32, lightHC: UInt32, darkHC: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let isHighContrast = traits.accessibilityContrast == .high
            switch (isDark, isHighContrast) {
            case (false, false): return UIColor(hex: light)
            case (true, false): return UIColor(hex: dark)
            case (false, true): return UIColor(hex: lightHC)
            case (true, true): return UIColor(hex: darkHC)
            }
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

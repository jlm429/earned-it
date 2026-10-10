import SwiftUI
import UIKit

/// Shared presentation colors. Status always retains a text or symbol equivalent.
enum AppTheme {
    static let canvas = adaptive(light: 0xF5F0E7, dark: 0x181E22)
    static let surface = adaptive(light: 0xFFFCF6, dark: 0x242C31)
    static let inset = adaptive(light: 0xEDE7DC, dark: 0x323D44)
    static let border = adaptive(light: 0xD4C9B8, dark: 0x53636C)
    static let accent = adaptive(light: 0x99462F, dark: 0xF2AF91)
    static let success = adaptive(light: 0x24634F, dark: 0x95D7B9)
    static let warning = adaptive(light: 0x805619, dark: 0xEEC477)
    static let info = adaptive(light: 0x355E86, dark: 0xAACDEC)
    static let danger = adaptive(light: 0xA13E3D, dark: 0xF0AEAA)
    static let personal = adaptive(light: 0x745183, dark: 0xD6B8E8)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

struct ThemedSurface: View {
    var tint: Color? = nil
    var cornerRadius: CGFloat = 22
    @Environment(\.accessibilityContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(AppTheme.surface)
            .overlay {
                if let tint {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [tint.opacity(0.13), tint.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppTheme.border.opacity(contrast == .increased ? 1 : 0.55), lineWidth: 1)
            }
    }
}

extension View {
    func themedListBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(AppTheme.canvas)
    }
}

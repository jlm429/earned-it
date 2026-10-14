import SwiftUI
import UIKit

/// Shared presentation colors. Status always retains a text or symbol equivalent.
enum AppTheme {
    static let canvas = adaptive(light: 0xF6F5EF, dark: 0x101E21)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1C2D30)
    static let inset = adaptive(light: 0xECEFE9, dark: 0x2B4043)
    static let border = adaptive(light: 0xC7D2C9, dark: 0x526A6D)
    static let secondaryText = adaptive(light: 0x52635F, dark: 0xBCCDC9)
    static let accent = adaptive(light: 0x17685B, dark: 0x8ED6BD)
    static let success = adaptive(light: 0x216B50, dark: 0x95D7B9)
    static let hero = Color(red: 0.07, green: 0.25, blue: 0.23)
    static let heroHighlight = Color(red: 0.15, green: 0.40, blue: 0.33)
    static let heroText = Color.white
    static let heroSecondary = Color(red: 0.79, green: 0.90, blue: 0.83)
    static let sunshine = adaptive(light: 0x8B5816, dark: 0xF0C57B)
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
    var cornerRadius: CGFloat = 24
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(AppTheme.surface)
            .overlay {
                if let tint {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [tint.opacity(0.08), tint.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppTheme.border.opacity(contrast == .increased ? 1 : 0.45), lineWidth: 1)
            }
    }
}

extension View {
    func themedListBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(AppTheme.canvas)
            .listRowBackground(AppTheme.surface)
            .listSectionSpacing(20)
    }
}

/// Wide screens give the day's work and its context room side by side.
struct HomeColumns<Primary: View, Secondary: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let primary: Primary
    @ViewBuilder let secondary: Secondary

    var body: some View {
        if sizeClass == .regular && !typeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: 28) {
                primary.frame(maxWidth: .infinity)
                secondary.frame(maxWidth: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                primary
                secondary
            }
        }
    }
}

struct ProgressRing: View {
    let completed: Int
    let total: Int
    var onHero = false
    var size: CGFloat = 88
    @Environment(\.dynamicTypeSize) private var typeSize
    @MotionPreference private var reduceMotion

    private var ringSize: CGFloat { typeSize.isAccessibilitySize ? max(size, 160) : size }
    private var fraction: Double { Double(completed) / Double(max(total, 1)) }

    var body: some View {
        ZStack {
            Circle().stroke(onHero ? .white.opacity(0.16) : AppTheme.inset, lineWidth: 7)
            Circle()
                .trim(from: 0, to: min(fraction, 1))
                .stroke(onHero ? AppTheme.heroSecondary : AppTheme.accent,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(completed)").font(.system(size: ringSize * 0.32, weight: .bold, design: .rounded))
                Text("of \(total)").font(.system(size: ringSize * 0.15, weight: .medium))
            }
            .foregroundStyle(onHero ? AppTheme.heroText : .primary)
        }
        .frame(width: ringSize, height: ringSize)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: completed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(completed) of \(total) accounted for")
    }
}

struct HeroSurface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(LinearGradient(colors: [AppTheme.heroHighlight, AppTheme.hero],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// Flexible native caption headings, without letter spacing that clips in the native text audit.
struct FeatureHeading: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(AppTheme.heroSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PressFeedbackStyle: ButtonStyle {
    @MotionPreference private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// The system preference always wins. DEBUG UI QA may additionally request less motion.
@propertyWrapper
struct MotionPreference: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    #if DEBUG
    @Environment(\.previewReduceMotion) private var preview
    #endif
    var wrappedValue: Bool {
        #if DEBUG
        system || preview
        #else
        system
        #endif
    }
}

#if DEBUG
private struct PreviewReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var previewReduceMotion: Bool {
        get { self[PreviewReduceMotionKey.self] }
        set { self[PreviewReduceMotionKey.self] = newValue }
    }
}
#endif

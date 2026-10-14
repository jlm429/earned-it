import SwiftUI

enum AppLinks {
    static let privacyPolicy = URL(string: "https://github.com/jlm429/earned-it/blob/main/docs/app-store/privacy-policy.md")!
    static let support = URL(string: "https://github.com/jlm429/earned-it/issues")!
}

extension AllowanceAmount {
    var weeklyAllowanceAccessibilityLabel: String {
        "Weekly allowance, \(formatted()) \(currencyCode)"
    }
}

/// Reads allowance context and localized currency as one field without relabeling its visual Text.
struct AllowanceValue: View {
    let amount: AllowanceAmount?
    var fallback = "Allowance not set"

    var body: some View {
        HStack(spacing: 0) {
            Text(amount?.formatted() ?? fallback)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Weekly allowance")
        .accessibilityValue(amount.map { "\($0.formatted()) \($0.currencyCode)" } ?? "Not set")
    }
}

struct LegalLinksView: View {
    var body: some View {
        Link("Privacy Policy", destination: AppLinks.privacyPolicy)
            .accessibilityIdentifier("privacy-policy-link")
        Link("Support", destination: AppLinks.support)
            .accessibilityIdentifier("support-link")
    }
}

extension ProgressStatus {
    var tint: Color {
        switch self {
        case .green: AppTheme.success
        case .yellow: AppTheme.warning
        case .red: AppTheme.danger
        case .neutral: AppTheme.secondaryText
        }
    }

    var symbolName: String {
        switch self {
        case .green: "checkmark.circle.fill"
        case .yellow: "exclamationmark.triangle.fill"
        case .red: "exclamationmark.circle.fill"
        case .neutral: "minus.circle"
        }
    }
}

extension DayStatus {
    var tint: Color {
        switch self {
        case .green: AppTheme.success
        case .yellow: AppTheme.warning
        case .red: AppTheme.danger
        case .excused: AppTheme.info
        case .neutral, .future: AppTheme.secondaryText
        }
    }

    var symbolName: String {
        switch self {
        case .green: "checkmark"
        case .yellow: "ellipsis"
        case .red: "xmark"
        case .excused: "heart.fill"
        case .neutral: "minus"
        case .future: "circle"
        }
    }
}

extension ResponsibilityCategory {
    var tint: Color {
        switch self {
        case .home: AppTheme.success
        case .school: AppTheme.info
        case .activities: AppTheme.warning
        case .personal: AppTheme.personal
        }
    }
}

extension DailyStateKind {
    var tint: Color {
        switch self {
        case .unmarked: AppTheme.secondaryText
        case .done: AppTheme.success
        case .notNeeded: AppTheme.info
        case .missed: AppTheme.danger
        }
    }
}

extension String {
    var accessibilitySlug: String {
        lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

struct AvatarView: View {
    let user: FamilyMember
    var size: CGFloat = 52
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image = avatarImage {
                Image(uiImage: image)
            } else {
                avatarGlyph
            }
        }
            .frame(width: size, height: size)
            .background(AppTheme.inset, in: RoundedRectangle(cornerRadius: size * 0.35))
            .overlay(RoundedRectangle(cornerRadius: size * 0.35).strokeBorder(AppTheme.border.opacity(0.5), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var avatarGlyph: some View {
        Text(user.avatar.rawValue)
            .font(.system(size: size * 0.58))
            .frame(width: size, height: size)
    }

    // Emoji are decorative artwork, not text whose shading conveys meaning.
    private var avatarImage: UIImage? {
        let renderer = ImageRenderer(content: avatarGlyph)
        renderer.scale = displayScale
        return renderer.uiImage
    }
}

struct ProfileHeader: View {
    let user: FamilyMember
    let title: String
    let subtitle: String
    var accessibilityIdentifier: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    AvatarView(user: user, size: 58)
                    titleStack
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        AvatarView(user: user, size: 58)
                        titleStack
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        AvatarView(user: user, size: 58)
                        titleStack
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.title, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CategoryBadge: View {
    let category: ResponsibilityCategory

    var body: some View {
        Label(category.rawValue, systemImage: category.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(category.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(category.tint.opacity(0.09), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct StatusBadge: View {
    let status: ProgressStatus

    var body: some View {
        Label {
            Text(status.rawValue).foregroundStyle(.primary)
        } icon: {
            Image(systemName: status.symbolName).foregroundStyle(status.tint)
        }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
            .background(status.tint.opacity(0.10), in: Capsule())
            .accessibilityLabel("Weekly status: \(status.rawValue)")
    }
}

struct SectionCard<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemedSurface(tint: tint))
    }
}

struct SectionHeading: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
        }
        .font(.system(.title2, design: .rounded, weight: .bold))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

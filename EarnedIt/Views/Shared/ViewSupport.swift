import SwiftUI

enum AppLinks {
    static let privacyPolicy = URL(string: "https://github.com/jlm429/earned-it/blob/main/docs/app-store/privacy-policy.md")!
    static let support = URL(string: "https://github.com/jlm429/earned-it/issues")!
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
        case .neutral: .secondary
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
        case .neutral, .future: .secondary
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
        case .unmarked: .secondary
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

    var body: some View {
        Text(user.avatar.rawValue)
            .font(.system(size: size * 0.58))
            .frame(width: size, height: size)
            .background(AppTheme.accent.opacity(0.12), in: Circle())
            .overlay(Circle().strokeBorder(AppTheme.accent.opacity(0.18), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct ProfileHeader: View {
    let user: FamilyMember
    let title: String
    let subtitle: String
    var accessibilityIdentifier: String

    var body: some View {
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
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .foregroundStyle(.secondary)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(category.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
            .background(status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Weekly status: \(status.rawValue)")
    }
}

struct SectionCard<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemedSurface(tint: tint))
    }
}

struct SectionHeading: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            Text(title).foregroundStyle(.primary)
        }
        .font(.title2.bold())
        .accessibilityAddTraits(.isHeader)
    }
}

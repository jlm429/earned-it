import SwiftUI

extension ProgressStatus {
    var tint: Color {
        switch self {
        case .green: .green
        case .yellow: .orange
        case .red: .red
        case .neutral: .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .green: "checkmark.circle.fill"
        case .yellow: "circle.lefthalf.filled"
        case .red: "exclamationmark.circle.fill"
        case .neutral: "minus.circle"
        }
    }
}

extension DayStatus {
    var tint: Color {
        switch self {
        case .green: .green
        case .yellow: .orange
        case .red: .red
        case .excused: .blue
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

extension DailyStateKind {
    var tint: Color {
        switch self {
        case .unmarked: .secondary
        case .done: .green
        case .notNeeded: .blue
        case .missed: .red
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
    let user: FamilyUser
    var size: CGFloat = 52

    var body: some View {
        Text(user.avatar.rawValue)
            .font(.system(size: size * 0.58))
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let status: ProgressStatus

    var body: some View {
        Label(status.rawValue, systemImage: status.symbolName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(status.tint.opacity(0.12), in: Capsule())
            .accessibilityLabel("Weekly status: \(status.rawValue)")
    }
}

struct SectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

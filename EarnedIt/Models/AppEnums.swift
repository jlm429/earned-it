import Foundation

enum UserRole: String, Codable, CaseIterable, Identifiable {
    case parent
    case child

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum AvatarOption: String, Codable, CaseIterable, Identifiable {
    case sun = "☀️"
    case fox = "🦊"
    case turtle = "🐢"
    case star = "⭐️"
    case flower = "🌼"
    case rocket = "🚀"
    case dog = "🐶"
    case cat = "🐱"

    var id: String { rawValue }
}

enum ResponsibilityCategory: String, Codable, CaseIterable, Identifiable {
    case home = "Home"
    case school = "School"
    case activities = "Activities"
    case personal = "Personal"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .home: "house.fill"
        case .school: "book.fill"
        case .activities: "figure.run"
        case .personal: "person.fill"
        }
    }
}

enum DailyStateKind: String, Codable, CaseIterable, Identifiable {
    case unmarked = "Unmarked"
    case done = "Done"
    case notNeeded = "Not Needed Today"
    case missed = "Missed"

    var id: String { rawValue }

    var isAccountedFor: Bool {
        self == .done || self == .notNeeded
    }

    var symbolName: String {
        switch self {
        case .unmarked: "circle"
        case .done: "checkmark.circle.fill"
        case .notNeeded: "minus.circle.fill"
        case .missed: "xmark.circle.fill"
        }
    }
}

enum ProgressStatus: String, Identifiable {
    case green = "On Track"
    case yellow = "Almost There"
    case red = "Needs Attention"
    case neutral = "No Items"

    var id: String { rawValue }
}

enum DayStatus: String, Identifiable {
    case green = "Complete"
    case yellow = "In Progress"
    case red = "Missed"
    case excused = "Excused"
    case neutral = "No Items"
    case future = "Future"

    var id: String { rawValue }
}

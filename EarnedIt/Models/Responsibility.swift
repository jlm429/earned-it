import Foundation
import SwiftData

@Model
final class Responsibility {
    @Attribute(.unique) var id: UUID
    var title: String
    var notes: String
    var categoryRawValue: String
    var creatorID: UUID
    var creatorRoleRawValue: String
    var assignedChildID: UUID
    var isActive: Bool
    var createdAt: Date
    var archivedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        category: ResponsibilityCategory,
        creatorID: UUID,
        creatorRole: UserRole,
        assignedChildID: UUID,
        isActive: Bool = true,
        createdAt: Date = .now,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        categoryRawValue = category.rawValue
        self.creatorID = creatorID
        creatorRoleRawValue = creatorRole.rawValue
        self.assignedChildID = assignedChildID
        self.isActive = isActive
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }

    var category: ResponsibilityCategory {
        get { ResponsibilityCategory(rawValue: categoryRawValue) ?? .personal }
        set { categoryRawValue = newValue.rawValue }
    }

    var creatorRole: UserRole {
        UserRole(rawValue: creatorRoleRawValue) ?? .parent
    }

    func isExpected(on date: Date, calendar: Calendar) -> Bool {
        let day = calendar.startOfDay(for: date)
        let createdDay = calendar.startOfDay(for: createdAt)
        guard day >= createdDay else { return false }
        guard let archivedAt else { return isActive }
        return day < calendar.startOfDay(for: archivedAt)
    }
}

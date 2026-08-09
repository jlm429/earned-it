import Foundation

enum PermissionService {
    static func canManageDefinition(user: FamilyUser, responsibility: Responsibility) -> Bool {
        if user.role == .parent { return true }
        return responsibility.creatorRole == .child
            && responsibility.creatorID == user.id
            && responsibility.assignedChildID == user.id
    }

    static func canAssign(user: FamilyUser, childID: UUID) -> Bool {
        user.role == .parent || user.id == childID
    }

    static func canSetState(
        user: FamilyUser,
        responsibility: Responsibility,
        state: DailyStateKind,
        date: Date,
        today: Date,
        calendar: Calendar = AppCalendar.current
    ) -> Bool {
        if state == .unmarked && calendar.startOfDay(for: date) < calendar.startOfDay(for: today) {
            return false
        }
        if user.role == .parent { return true }
        return responsibility.assignedChildID == user.id
            && calendar.isDate(date, inSameDayAs: today)
            && state != .missed
    }

    static func canRemoveUser(
        _ user: FamilyUser,
        allUsers: [FamilyUser],
        responsibilities: [Responsibility]
    ) -> Bool {
        if user.role == .parent && allUsers.filter({ $0.role == .parent }).count <= 1 {
            return false
        }
        return !responsibilities.contains { responsibility in
            responsibility.isActive && (
                responsibility.creatorID == user.id || responsibility.assignedChildID == user.id
            )
        }
    }
}

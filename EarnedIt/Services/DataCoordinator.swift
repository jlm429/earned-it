import Foundation
import SwiftData

@MainActor
enum DataCoordinator {
    static func prepareDailyData(
        context: ModelContext,
        today: Date = .now,
        calendar: Calendar = AppCalendar.current
    ) throws {
        let normalizedToday = calendar.startOfDay(for: today)
        let responsibilities = try context.fetch(FetchDescriptor<Responsibility>())
        var records = try context.fetch(FetchDescriptor<DailyRecord>())
        var keys = Set(records.map(\.uniqueKey))

        for responsibility in responsibilities {
            let start = calendar.startOfDay(for: responsibility.createdAt)
            for day in AppCalendar.dates(from: start, through: normalizedToday, calendar: calendar)
            where responsibility.isExpected(on: day, calendar: calendar) {
                let key = DailyRecord.key(responsibilityID: responsibility.id, day: day)
                guard !keys.contains(key) else { continue }
                let record = DailyRecord(
                    responsibilityID: responsibility.id,
                    childID: responsibility.assignedChildID,
                    day: day,
                    calendar: calendar
                )
                context.insert(record)
                records.append(record)
                keys.insert(key)
            }
        }

        DailyRolloverService.rollOver(records: records, today: normalizedToday, calendar: calendar)
        try context.save()
    }

    static func record(
        for responsibility: Responsibility,
        on date: Date,
        records: [DailyRecord],
        context: ModelContext,
        calendar: Calendar = AppCalendar.current
    ) -> DailyRecord {
        if let existing = records.first(where: {
            $0.responsibilityID == responsibility.id && calendar.isDate($0.day, inSameDayAs: date)
        }) {
            return existing
        }
        let newRecord = DailyRecord(
            responsibilityID: responsibility.id,
            childID: responsibility.assignedChildID,
            day: date,
            calendar: calendar
        )
        context.insert(newRecord)
        return newRecord
    }

    static func setState(
        _ state: DailyStateKind,
        actor: FamilyUser,
        responsibility: Responsibility,
        date: Date,
        today: Date = .now,
        records: [DailyRecord],
        context: ModelContext,
        calendar: Calendar = AppCalendar.current
    ) throws {
        guard PermissionService.canSetState(
            user: actor,
            responsibility: responsibility,
            state: state,
            date: date,
            today: today,
            calendar: calendar
        ) else { return }
        let dailyRecord = record(
            for: responsibility,
            on: date,
            records: records,
            context: context,
            calendar: calendar
        )
        dailyRecord.state = state
        try context.save()
    }

    static func toggleExcused(
        childID: UUID,
        date: Date,
        excusedDays: [ExcusedDay],
        context: ModelContext,
        calendar: Calendar = AppCalendar.current
    ) throws {
        if let existing = excusedDays.first(where: {
            $0.childID == childID && calendar.isDate($0.day, inSameDayAs: date)
        }) {
            context.delete(existing)
        } else {
            context.insert(ExcusedDay(childID: childID, day: date, calendar: calendar))
        }
        try context.save()
    }

    static func archive(
        _ responsibility: Responsibility,
        actor: FamilyUser,
        context: ModelContext,
        now: Date = .now
    ) throws {
        guard PermissionService.canManageDefinition(user: actor, responsibility: responsibility) else { return }
        responsibility.isActive = false
        responsibility.archivedAt = now
        try context.save()
    }
}

import Foundation
import SwiftData

@MainActor
enum DataCoordinator {
    static func updateResponsibilityDraft(
        id: UUID,
        title: String,
        notes: String,
        category: ResponsibilityCategory,
        actor: FamilyUser,
        assignedChildID: UUID,
        context: ModelContext
    ) throws {
        let responsibilities = try context.fetch(FetchDescriptor<Responsibility>())
        if let draft = responsibilities.first(where: { $0.id == id }) {
            let records = try context.fetch(FetchDescriptor<DailyRecord>(
                predicate: #Predicate { $0.responsibilityID == id }
            ))
            for record in records {
                record.childID = assignedChildID
            }
            draft.title = title
            draft.notes = notes
            draft.category = category
            draft.assignedChildID = assignedChildID
        } else {
            context.insert(Responsibility(
                id: id,
                title: title,
                notes: notes,
                category: category,
                creatorID: actor.id,
                creatorRole: actor.role,
                assignedChildID: assignedChildID
            ))
        }
    }

    static func prepareDailyData(
        context: ModelContext,
        today: Date = .now,
        calendar: Calendar = AppCalendar.current
    ) throws {
        let responsibilities = try context.fetch(FetchDescriptor<Responsibility>())
        var records = try context.fetch(FetchDescriptor<DailyRecord>())
        let excusedDays = try context.fetch(FetchDescriptor<ExcusedDay>())
        migratePersistedDays(records: records, excusedDays: excusedDays, context: context, calendar: calendar)
        let normalizedToday = calendar.startOfDay(for: today)
        var keys = Set(records.map(\.uniqueKey))

        for responsibility in responsibilities {
            let start = calendar.startOfDay(for: responsibility.createdAt)
            for day in AppCalendar.dates(from: start, through: normalizedToday, calendar: calendar)
            where responsibility.isExpected(on: day, calendar: calendar) {
                let key = DailyRecord.key(responsibilityID: responsibility.id, day: day, calendar: calendar)
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

        DailyRolloverService.rollOver(records: records, today: today, calendar: calendar)
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
            $0.responsibilityID == responsibility.id
                && AppCalendar.isPersistedDay($0.day, sameDayAs: date, calendar: calendar)
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
            $0.childID == childID
                && AppCalendar.isPersistedDay($0.day, sameDayAs: date, calendar: calendar)
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

    static func reassign(
        _ responsibility: Responsibility,
        to childID: UUID,
        actor: FamilyUser,
        title: String,
        notes: String,
        category: ResponsibilityCategory,
        context: ModelContext,
        now: Date = .now
    ) throws {
        guard actor.role == .parent, responsibility.assignedChildID != childID else { return }
        responsibility.isActive = false
        responsibility.archivedAt = now
        context.insert(Responsibility(
            title: title,
            notes: notes,
            category: category,
            creatorID: actor.id,
            creatorRole: actor.role,
            assignedChildID: childID,
            createdAt: now
        ))
        try context.save()
        try prepareDailyData(context: context, today: now)
    }

    private static func migratePersistedDays(
        records: [DailyRecord],
        excusedDays: [ExcusedDay],
        context: ModelContext,
        calendar: Calendar
    ) {
        let groupedRecords = Dictionary(grouping: records) { record in
            let identifier = DailyRecord.dayIdentifier(from: record.uniqueKey)
                ?? AppCalendar.dayIdentifier(for: record.day, calendar: calendar)
            return DailyRecord.key(responsibilityID: record.responsibilityID, dayIdentifier: identifier)
        }
        for (key, duplicates) in groupedRecords {
            guard let survivor = duplicates.max(by: { $0.updatedAt < $1.updatedAt }),
                  let identifier = key.split(separator: "|").last.map(String.init),
                  let day = AppCalendar.persistedDay(for: identifier) else { continue }
            duplicates.filter { $0 !== survivor }.forEach(context.delete)
            survivor.uniqueKey = key
            survivor.day = day
        }

        let groupedExcuses = Dictionary(grouping: excusedDays) { excusedDay in
            let identifier = ExcusedDay.dayIdentifier(from: excusedDay.uniqueKey)
                ?? AppCalendar.dayIdentifier(for: excusedDay.day, calendar: calendar)
            return ExcusedDay.key(childID: excusedDay.childID, dayIdentifier: identifier)
        }
        for (key, duplicates) in groupedExcuses {
            guard let survivor = duplicates.first,
                  let identifier = key.split(separator: "|").last.map(String.init),
                  let day = AppCalendar.persistedDay(for: identifier) else { continue }
            duplicates.dropFirst().forEach(context.delete)
            survivor.uniqueKey = key
            survivor.day = day
        }
    }
}

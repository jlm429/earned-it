import Foundation
import SwiftData

@MainActor
enum SampleDataService {
    static let parentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let childOneID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let childTwoID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    static func seed(
        context: ModelContext,
        today: Date = .now,
        calendar: Calendar = AppCalendar.current
    ) throws {
        try clearAll(context: context)

        let normalizedToday = calendar.startOfDay(for: today)
        let weekStart = AppCalendar.weekStart(containing: normalizedToday, calendar: calendar)
        let createdAt = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart

        let parent = FamilyUser(id: parentID, displayName: "Parent", role: .parent, avatar: .sun, createdAt: createdAt)
        let childOne = FamilyUser(id: childOneID, displayName: "Child One", role: .child, avatar: .fox, createdAt: createdAt)
        let childTwo = FamilyUser(id: childTwoID, displayName: "Child Two", role: .child, avatar: .turtle, createdAt: createdAt)
        [parent, childOne, childTwo].forEach(context.insert)

        let childOneDefinitions: [(String, ResponsibilityCategory, UUID, UserRole)] = [
            ("Make bed", .home, parentID, .parent),
            ("Pack backpack", .school, parentID, .parent),
            ("Feed pet", .home, childOneID, .child),
            ("Practice reading", .personal, childOneID, .child),
            ("Put away clothes", .home, parentID, .parent),
            ("Clear dishes", .home, parentID, .parent),
            ("Brush teeth", .personal, parentID, .parent),
            ("Prepare water bottle", .activities, childOneID, .child)
        ]
        let childTwoDefinitions: [(String, ResponsibilityCategory, UUID, UserRole)] = [
            ("Tidy room", .home, parentID, .parent),
            ("Homework check", .school, parentID, .parent),
            ("Activity gear", .activities, childTwoID, .child),
            ("Write in journal", .personal, childTwoID, .child)
        ]

        var responsibilities: [Responsibility] = []
        for (offset, definition) in childOneDefinitions.enumerated() {
            let item = Responsibility(
                id: stableResponsibilityID(100 + offset),
                title: definition.0,
                category: definition.1,
                creatorID: definition.2,
                creatorRole: definition.3,
                assignedChildID: childOneID,
                createdAt: createdAt
            )
            responsibilities.append(item)
            context.insert(item)
        }
        for (offset, definition) in childTwoDefinitions.enumerated() {
            let item = Responsibility(
                id: stableResponsibilityID(200 + offset),
                title: definition.0,
                category: definition.1,
                creatorID: definition.2,
                creatorRole: definition.3,
                assignedChildID: childTwoID,
                createdAt: createdAt
            )
            responsibilities.append(item)
            context.insert(item)
        }

        let sampleDates = AppCalendar.dates(from: createdAt, through: normalizedToday, calendar: calendar)
        for day in sampleDates {
            for item in responsibilities {
                var state = DailyStateKind.done
                if calendar.isDate(day, inSameDayAs: normalizedToday) {
                    if item.title == "Pack backpack" || item.title == "Homework check" {
                        state = .notNeeded
                    } else if item.title == "Feed pet" || item.title == "Practice reading" || item.title == "Activity gear" {
                        state = .unmarked
                    }
                }

                let childTwoMissedDay = calendar.date(byAdding: .day, value: 1, to: weekStart) ?? weekStart
                if item.assignedChildID == childTwoID
                    && calendar.isDate(day, inSameDayAs: childTwoMissedDay)
                    && item.title == "Tidy room" {
                    state = .unmarked
                }

                context.insert(DailyRecord(
                    responsibilityID: item.id,
                    childID: item.assignedChildID,
                    day: day,
                    state: state,
                    calendar: calendar,
                    updatedAt: day
                ))
            }
        }

        let currentWeekDates = AppCalendar.dates(from: weekStart, through: normalizedToday, calendar: calendar)
        if let excusedDate = currentWeekDates.dropFirst(2).first ?? currentWeekDates.first {
            context.insert(ExcusedDay(childID: childOneID, day: excusedDate, calendar: calendar))
        }

        context.insert(AppSetting(key: SettingsStore.setupCompleteKey, value: "true"))
        context.insert(AppSetting(key: SettingsStore.dataModeKey, value: "sample"))
        try context.save()
        try DataCoordinator.prepareDailyData(context: context, today: normalizedToday, calendar: calendar)
    }

    static func clearAll(context: ModelContext) throws {
        try context.fetch(FetchDescriptor<DailyRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<ExcusedDay>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<Responsibility>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<FamilyUser>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<AppSetting>()).forEach(context.delete)
        try context.save()
    }

    private static func stableResponsibilityID(_ value: Int) -> UUID {
        let suffix = String(format: "%012d", value)
        return UUID(uuidString: "10000000-0000-0000-0000-\(suffix)")!
    }
}

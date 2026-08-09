import Foundation

struct DayFacts: Equatable {
    let date: Date
    let states: [DailyStateKind]
    let isExcused: Bool

    var expectedCount: Int { isExcused ? 0 : states.count }
    var accountedCount: Int { isExcused ? 0 : states.filter(\.isAccountedFor).count }
}

struct WeeklySummary: Equatable {
    let accountedCount: Int
    let expectedCount: Int

    var completion: Double? {
        expectedCount == 0 ? nil : Double(accountedCount) / Double(expectedCount)
    }

    var status: ProgressStatus {
        WeeklyScoringService.status(accounted: accountedCount, expected: expectedCount)
    }
}

enum MetricsService {
    static func facts(
        childID: UUID,
        dates: [Date],
        responsibilities: [Responsibility],
        records: [DailyRecord],
        excusedDays: [ExcusedDay],
        calendar: Calendar = AppCalendar.current
    ) -> [DayFacts] {
        let childResponsibilities = responsibilities.filter { $0.assignedChildID == childID }
        let childRecords = records.filter { $0.childID == childID }
        let childExcuses = excusedDays.filter { $0.childID == childID }

        return dates.map { date in
            let day = calendar.startOfDay(for: date)
            let expected = childResponsibilities.filter { $0.isExpected(on: day, calendar: calendar) }
            let states = expected.map { responsibility in
                childRecords.first {
                    $0.responsibilityID == responsibility.id
                        && AppCalendar.isPersistedDay($0.day, sameDayAs: day, calendar: calendar)
                }?.state ?? .unmarked
            }
            let isExcused = childExcuses.contains {
                AppCalendar.isPersistedDay($0.day, sameDayAs: day, calendar: calendar)
            }
            return DayFacts(date: day, states: states, isExcused: isExcused)
        }
    }

    static func currentWeekFacts(
        childID: UUID,
        today: Date,
        responsibilities: [Responsibility],
        records: [DailyRecord],
        excusedDays: [ExcusedDay],
        calendar: Calendar = AppCalendar.current
    ) -> [DayFacts] {
        weekFacts(
            childID: childID,
            containing: today,
            responsibilities: responsibilities,
            records: records,
            excusedDays: excusedDays,
            calendar: calendar
        )
    }

    static func previousCompletedWeekFacts(
        childID: UUID,
        today: Date,
        responsibilities: [Responsibility],
        records: [DailyRecord],
        excusedDays: [ExcusedDay],
        calendar: Calendar = AppCalendar.current
    ) -> [DayFacts] {
        let currentStart = AppCalendar.weekStart(containing: today, calendar: calendar)
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: currentStart) else { return [] }
        return weekFacts(
            childID: childID,
            containing: previousDay,
            responsibilities: responsibilities,
            records: records,
            excusedDays: excusedDays,
            calendar: calendar
        )
    }

    private static func weekFacts(
        childID: UUID,
        containing date: Date,
        responsibilities: [Responsibility],
        records: [DailyRecord],
        excusedDays: [ExcusedDay],
        calendar: Calendar
    ) -> [DayFacts] {
        let start = AppCalendar.weekStart(containing: date, calendar: calendar)
        let dates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        return facts(
            childID: childID,
            dates: dates,
            responsibilities: responsibilities,
            records: records,
            excusedDays: excusedDays,
            calendar: calendar
        )
    }

    static func streakFacts(
        childID: UUID,
        today: Date,
        responsibilities: [Responsibility],
        records: [DailyRecord],
        excusedDays: [ExcusedDay],
        calendar: Calendar = AppCalendar.current
    ) -> [DayFacts] {
        let relevant = responsibilities.filter { $0.assignedChildID == childID }
        guard let earliest = relevant.map(\.createdAt).min() else { return [] }
        return facts(
            childID: childID,
            dates: AppCalendar.dates(from: earliest, through: today, calendar: calendar),
            responsibilities: responsibilities,
            records: records,
            excusedDays: excusedDays,
            calendar: calendar
        )
    }
}

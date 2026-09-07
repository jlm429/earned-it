import Foundation

struct DayFacts: Equatable {
    let date: Date
    let states: [DailyStateKind]
    let isExcused: Bool
    var requiredStates: [DailyStateKind]? = nil
    var expectedCount: Int { isExcused ? 0 : states.count }
    var accountedCount: Int { isExcused ? 0 : states.filter(\.isAccountedFor).count }
}

struct WeeklySummary: Equatable {
    let accountedCount: Int
    let expectedCount: Int
    var completion: Double? { expectedCount == 0 ? nil : Double(accountedCount) / Double(expectedCount) }
    var status: ProgressStatus { WeeklyScoringService.status(accounted: accountedCount, expected: expectedCount) }
}

enum MetricsService {
    static func facts(childID: UUID, dates: [Date], snapshot: HouseholdSnapshot, today: Date) -> [DayFacts] {
        guard let household = snapshot.household else { return [] }
        let calendar = household.calendar
        let currentDay = CivilDay(today, calendar: calendar)
        return dates.map { date in
            let day = CivilDay(date, calendar: calendar)
            let chores = ChoreRules.dailyList(snapshot: snapshot, day: day, today: currentDay)
            let states = chores.compactMap { $0.creditState(for: childID) }
            let excused = snapshot.excuses.contains { $0.memberID == childID && $0.day == day && $0.isExcused }
            return DayFacts(date: day.date(in: calendar), states: states, isExcused: excused,
                            requiredStates: chores.filter { $0.requiredMemberIDs.contains(childID) }.map { $0.state(for: childID) })
        }
    }

    static func weekFacts(childID: UUID, containing date: Date, snapshot: HouseholdSnapshot, today: Date) -> [DayFacts] {
        guard let calendar = snapshot.household?.calendar else { return [] }
        let start = AppCalendar.weekStart(containing: date, calendar: calendar)
        let dates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        return facts(childID: childID, dates: dates, snapshot: snapshot, today: today)
    }

    static func streak(childID: UUID, snapshot: HouseholdSnapshot, today: Date) -> Int {
        guard let household = snapshot.household else { return 0 }
        let calendar = household.calendar
        let days = AppCalendar.dates(from: household.createdDay.date(in: calendar), through: today, calendar: calendar)
        return StreakService.currentStreak(days: facts(childID: childID, dates: days, snapshot: snapshot, today: today),
                                          today: today, calendar: calendar)
    }
}

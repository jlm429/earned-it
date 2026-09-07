import Foundation

enum WeeklyScoringService {
    static func summary(
        days: [DayFacts],
        today: Date,
        calendar: Calendar = AppCalendar.current
    ) -> WeeklySummary {
        let start = AppCalendar.weekStart(containing: today, calendar: calendar)
        let normalizedToday = calendar.startOfDay(for: today)
        let included = days.filter {
            let day = calendar.startOfDay(for: $0.date)
            return day >= start && day <= normalizedToday && !$0.isExcused
        }
        return WeeklySummary(
            accountedCount: included.reduce(0) { $0 + $1.accountedCount },
            expectedCount: included.reduce(0) { $0 + $1.expectedCount }
        )
    }

    static func status(accounted: Int, expected: Int) -> ProgressStatus {
        guard expected > 0 else { return .neutral }
        return accounted >= expected ? .green : .yellow
    }

    static func allowanceEarned(
        days: [DayFacts],
        asOf date: Date,
        calendar: Calendar = AppCalendar.current
    ) -> Bool? {
        guard let firstDay = days.map(\.date).min() else { return nil }
        let start = AppCalendar.weekStart(containing: firstDay, calendar: calendar)
        guard let periodEnd = calendar.date(byAdding: .day, value: 7, to: start),
              calendar.startOfDay(for: date) >= periodEnd else { return nil }
        let lastDay = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let required = days.map { DayFacts(date: $0.date, states: $0.requiredStates ?? $0.states, isExcused: $0.isExcused) }
        let weekly = summary(days: required, today: lastDay, calendar: calendar)
        guard let completion = weekly.completion else { return nil }
        return completion == 1
    }

    static func dayStatus(
        _ facts: DayFacts,
        today: Date,
        calendar: Calendar = AppCalendar.current
    ) -> DayStatus {
        let day = calendar.startOfDay(for: facts.date)
        let normalizedToday = calendar.startOfDay(for: today)
        if day > normalizedToday { return .future }
        if facts.isExcused { return .excused }
        if facts.states.isEmpty { return .neutral }
        if facts.states.allSatisfy(\.isAccountedFor) { return .green }
        if day == normalizedToday { return .yellow }
        return .red
    }
}

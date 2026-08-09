import Foundation

enum StreakService {
    static func currentStreak(
        days: [DayFacts],
        today: Date,
        calendar: Calendar = AppCalendar.current
    ) -> Int {
        let normalizedToday = calendar.startOfDay(for: today)
        let eligible = days
            .filter { calendar.startOfDay(for: $0.date) <= normalizedToday }
            .sorted { $0.date > $1.date }

        var streak = 0
        for facts in eligible {
            if facts.isExcused || facts.states.isEmpty { continue }
            if facts.states.contains(.missed) { break }

            let isToday = calendar.isDate(facts.date, inSameDayAs: normalizedToday)
            if facts.states.allSatisfy(\.isAccountedFor) {
                streak += 1
            } else if isToday {
                continue
            } else {
                break
            }
        }
        return streak
    }
}

import Foundation

enum AppCalendar {
    private static var persisted: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static var current: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    static func weekStart(containing date: Date, calendar: Calendar = current) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: day) ?? day
    }

    static func dates(from start: Date, through end: Date, calendar: Calendar = current) -> [Date] {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard first <= last else { return [] }

        var result: [Date] = []
        var cursor = first
        while cursor <= last {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    static func dayIdentifier(for date: Date, calendar: Calendar = current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func persistedDay(for date: Date, calendar: Calendar = current) -> Date {
        persistedDay(for: dayIdentifier(for: date, calendar: calendar)) ?? date
    }

    static func persistedDay(for identifier: String) -> Date? {
        let parts = identifier.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return persisted.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func persistedDayIdentifier(for date: Date) -> String {
        dayIdentifier(for: date, calendar: persisted)
    }

    static func isPersistedDay(
        _ persistedDate: Date,
        sameDayAs date: Date,
        calendar: Calendar = current
    ) -> Bool {
        persistedDayIdentifier(for: persistedDate) == dayIdentifier(for: date, calendar: calendar)
    }
}

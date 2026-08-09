import Foundation

enum DailyRolloverService {
    @discardableResult
    static func rollOver(
        records: [DailyRecord],
        today: Date,
        calendar: Calendar = AppCalendar.current
    ) -> Int {
        let normalizedToday = calendar.startOfDay(for: today)
        var changed = 0
        for record in records where record.day < normalizedToday && record.state == .unmarked {
            record.state = .missed
            changed += 1
        }
        return changed
    }
}

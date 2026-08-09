import Foundation
import SwiftData

@Model
final class ExcusedDay {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var uniqueKey: String
    var childID: UUID
    var day: Date

    init(id: UUID = UUID(), childID: UUID, day: Date, calendar: Calendar = AppCalendar.current) {
        let dayIdentifier = AppCalendar.dayIdentifier(for: day, calendar: calendar)
        self.id = id
        uniqueKey = Self.key(childID: childID, dayIdentifier: dayIdentifier)
        self.childID = childID
        self.day = AppCalendar.persistedDay(for: day, calendar: calendar)
    }

    static func key(
        childID: UUID,
        day: Date,
        calendar: Calendar = AppCalendar.current
    ) -> String {
        key(childID: childID, dayIdentifier: AppCalendar.dayIdentifier(for: day, calendar: calendar))
    }

    static func key(childID: UUID, dayIdentifier: String) -> String {
        "\(childID.uuidString)|\(dayIdentifier)"
    }

    static func dayIdentifier(from uniqueKey: String) -> String? {
        guard let identifier = uniqueKey.split(separator: "|").last.map(String.init),
              AppCalendar.persistedDay(for: identifier) != nil else { return nil }
        return identifier
    }
}

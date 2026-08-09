import Foundation
import SwiftData

@Model
final class DailyRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var uniqueKey: String
    var responsibilityID: UUID
    var childID: UUID
    var day: Date
    var stateRawValue: String
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        responsibilityID: UUID,
        childID: UUID,
        day: Date,
        state: DailyStateKind = .unmarked,
        calendar: Calendar = AppCalendar.current,
        updatedAt: Date = .now
    ) {
        let dayIdentifier = AppCalendar.dayIdentifier(for: day, calendar: calendar)
        self.id = id
        uniqueKey = Self.key(responsibilityID: responsibilityID, dayIdentifier: dayIdentifier)
        self.responsibilityID = responsibilityID
        self.childID = childID
        self.day = AppCalendar.persistedDay(for: day, calendar: calendar)
        stateRawValue = state.rawValue
        self.updatedAt = updatedAt
    }

    var state: DailyStateKind {
        get { DailyStateKind(rawValue: stateRawValue) ?? .unmarked }
        set {
            stateRawValue = newValue.rawValue
            updatedAt = .now
        }
    }

    static func key(
        responsibilityID: UUID,
        day: Date,
        calendar: Calendar = AppCalendar.current
    ) -> String {
        key(responsibilityID: responsibilityID, dayIdentifier: AppCalendar.dayIdentifier(for: day, calendar: calendar))
    }

    static func key(responsibilityID: UUID, dayIdentifier: String) -> String {
        "\(responsibilityID.uuidString)|\(dayIdentifier)"
    }

    static func dayIdentifier(from uniqueKey: String) -> String? {
        guard let identifier = uniqueKey.split(separator: "|").last.map(String.init),
              AppCalendar.persistedDay(for: identifier) != nil else { return nil }
        return identifier
    }
}

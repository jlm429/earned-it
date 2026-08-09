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
        let normalizedDay = calendar.startOfDay(for: day)
        self.id = id
        uniqueKey = Self.key(responsibilityID: responsibilityID, day: normalizedDay)
        self.responsibilityID = responsibilityID
        self.childID = childID
        self.day = normalizedDay
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

    static func key(responsibilityID: UUID, day: Date) -> String {
        "\(responsibilityID.uuidString)|\(Int(day.timeIntervalSinceReferenceDate))"
    }
}

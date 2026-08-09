import Foundation
import SwiftData

@Model
final class ExcusedDay {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var uniqueKey: String
    var childID: UUID
    var day: Date

    init(id: UUID = UUID(), childID: UUID, day: Date, calendar: Calendar = AppCalendar.current) {
        let normalizedDay = calendar.startOfDay(for: day)
        self.id = id
        uniqueKey = Self.key(childID: childID, day: normalizedDay)
        self.childID = childID
        self.day = normalizedDay
    }

    static func key(childID: UUID, day: Date) -> String {
        "\(childID.uuidString)|\(Int(day.timeIntervalSinceReferenceDate))"
    }
}

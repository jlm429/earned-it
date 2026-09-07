import Foundation

/// Integer minor units avoid binary floating point and preserve the original currency.
struct AllowanceAmount: Codable, Equatable {
    let minorUnits: Int64
    let currencyCode: String

    static func fractionDigits(for code: String) -> Int {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US@currency=\(code)")
        formatter.numberStyle = .currency
        return formatter.maximumFractionDigits
    }

    var decimal: Decimal {
        Decimal(minorUnits) / pow(Decimal(10), Self.fractionDigits(for: currencyCode))
    }

    func formatted(locale: Locale = .autoupdatingCurrent) -> String {
        decimal.formatted(.currency(code: currencyCode).locale(locale))
    }

    func inputText(locale: Locale = .autoupdatingCurrent) -> String {
        decimal.formatted(.number.locale(locale).grouping(.never)
            .precision(.fractionLength(Self.fractionDigits(for: currencyCode))))
    }

    static func parse(_ text: String, currencyCode: String, locale: Locale = .autoupdatingCurrent) throws -> Self? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Locale.commonISOCurrencyCodes.contains(currencyCode) else { throw HouseholdError.invalidAllowance }
        if text.isEmpty { return nil }
        let separator = locale.decimalSeparator ?? "."
        let parts = text.components(separatedBy: separator)
        let digits = fractionDigits(for: currencyCode)
        guard parts.count <= 2, !parts[0].isEmpty,
              parts.allSatisfy({ $0.allSatisfy { character in
                  character.wholeNumberValue.map { (0...9).contains($0) } ?? false
              } }),
              parts.count == 1 || (!parts[1].isEmpty && parts[1].count <= digits),
              let value = Decimal(string: parts.map { $0.compactMap(\.wholeNumberValue).map(String.init).joined() }.joined(separator: "."), locale: Locale(identifier: "en_US_POSIX")),
              value >= 0, value <= 999_999 else { throw HouseholdError.invalidAllowance }
        let scaled = value * pow(Decimal(10), digits)
        return Self(minorUnits: NSDecimalNumber(decimal: scaled).int64Value, currencyCode: currencyCode)
    }

    var isValid: Bool {
        Locale.commonISOCurrencyCodes.contains(currencyCode) && minorUnits >= 0 && decimal <= 999_999
    }
}

/// A revision applies to its Monday and later weeks. Finished weeks keep their rate.
struct AllowanceRevision: Codable, Equatable {
    let memberID: UUID
    let effectiveWeek: CivilDay
    let amount: AllowanceAmount?
}

struct WeeklyItem: Identifiable, Equatable {
    let choreID: UUID
    let day: CivilDay
    let title: String
    let state: DailyStateKind
    var id: String { "\(day)/\(choreID)" }
}

struct AllowanceWeek: Identifiable, Equatable {
    let memberID: UUID
    let start: CivilDay
    let end: CivilDay
    let today: CivilDay
    let amount: AllowanceAmount?
    let items: [WeeklyItem]
    var id: String { "\(memberID)/\(start)" }
    var isFinished: Bool { end < today }
    var missing: [WeeklyItem] { items.filter { $0.day < today && !$0.state.isAccountedFor } }
    var dueToday: [WeeklyItem] { items.filter { $0.day == today && !$0.state.isAccountedFor } }
    var scheduled: [WeeklyItem] { items.filter { $0.day > today } }
    var accountedCount: Int { items.filter { $0.day <= today && $0.state.isAccountedFor }.count }
    var dueCount: Int { items.filter { $0.day <= today }.count }
    var earned: Bool { isFinished && !items.isEmpty && missing.isEmpty }
    var status: ProgressStatus {
        guard dueCount > 0 else { return .neutral }
        return missing.isEmpty && dueToday.isEmpty ? .green : .yellow
    }
}

enum AllowanceService {
    static let completedWeekLimit = 12

    static func week(childID: UUID, containing date: Date, snapshot: HouseholdSnapshot, today: Date) -> AllowanceWeek {
        let calendar = snapshot.household?.calendar ?? AppCalendar.current
        let start = CivilDay(AppCalendar.weekStart(containing: date, calendar: calendar), calendar: calendar)
        let current = CivilDay(today, calendar: calendar)
        let items = (0..<7).flatMap { offset -> [WeeklyItem] in
            let day = start.adding(days: offset, calendar: calendar)
            if snapshot.excuses.contains(where: { $0.memberID == childID && $0.day == day && $0.isExcused }) { return [] }
            return ChoreRules.dailyList(snapshot: snapshot, day: day, today: current)
                .filter { $0.requiredMemberIDs.contains(childID) }
                .map { WeeklyItem(choreID: $0.id, day: day, title: $0.configuration.title, state: $0.state(for: childID)) }
        }
        let revision = snapshot.allowances.filter { $0.memberID == childID && $0.effectiveWeek <= start }
            .enumerated().max {
                $0.element.effectiveWeek == $1.element.effectiveWeek
                    ? $0.offset < $1.offset : $0.element.effectiveWeek < $1.element.effectiveWeek
            }?.element
        return AllowanceWeek(memberID: childID, start: start, end: start.adding(days: 6, calendar: calendar),
                             today: current, amount: revision?.amount, items: items)
    }

    /// Bounded projections, not materialized summary records or broad journal deletion.
    static func history(childID: UUID, snapshot: HouseholdSnapshot, today: Date) -> [AllowanceWeek] {
        guard let household = snapshot.household else { return [] }
        let calendar = household.calendar
        let first = AppCalendar.weekStart(containing: household.createdDay.date(in: calendar), calendar: calendar)
        let current = AppCalendar.weekStart(containing: today, calendar: calendar)
        return (0...completedWeekLimit).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -7 * offset, to: current), date >= first else { return nil }
            return week(childID: childID, containing: date, snapshot: snapshot, today: today)
        }
    }
}

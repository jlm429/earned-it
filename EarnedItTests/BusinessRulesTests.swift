import XCTest
@testable import EarnedIt

final class BusinessRulesTests: XCTestCase {
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
    }

    func testNewCurrentDayRecordBeginsUnmarked() {
        let record = DailyRecord(
            responsibilityID: UUID(),
            childID: UUID(),
            day: date(2026, 8, 9),
            calendar: calendar
        )

        XCTAssertEqual(record.state, .unmarked)
    }

    func testDoneAndNotNeededCountEquallyAsAccountedFor() {
        let done = DayFacts(date: date(2026, 8, 3), states: [.done], isExcused: false)
        let notNeeded = DayFacts(date: date(2026, 8, 4), states: [.notNeeded], isExcused: false)

        let summary = WeeklyScoringService.summary(
            days: [done, notNeeded],
            today: date(2026, 8, 4),
            calendar: calendar
        )

        XCTAssertEqual(done.accountedCount, notNeeded.accountedCount)
        XCTAssertEqual(summary.accountedCount, 2)
        XCTAssertEqual(summary.expectedCount, 2)
    }

    func testPastUnmarkedRollsToMissedButTodayStaysUnmarked() {
        let today = date(2026, 8, 9)
        let past = DailyRecord(responsibilityID: UUID(), childID: UUID(), day: date(2026, 8, 8), calendar: calendar)
        let current = DailyRecord(responsibilityID: UUID(), childID: UUID(), day: today, calendar: calendar)

        let changed = DailyRolloverService.rollOver(records: [past, current], today: today, calendar: calendar)

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(past.state, .missed)
        XCTAssertEqual(current.state, .unmarked)
    }

    func testMissedLowersScoreAndFutureDaysDoNotAffectIt() {
        let today = date(2026, 8, 5)
        let days = [
            DayFacts(date: date(2026, 8, 3), states: [.done], isExcused: false),
            DayFacts(date: date(2026, 8, 4), states: [.missed], isExcused: false),
            DayFacts(date: date(2026, 8, 6), states: [.missed, .missed], isExcused: false)
        ]

        let summary = WeeklyScoringService.summary(days: days, today: today, calendar: calendar)

        XCTAssertEqual(summary.accountedCount, 1)
        XCTAssertEqual(summary.expectedCount, 2)
        XCTAssertEqual(summary.completion, 0.5)
    }

    func testStatusThresholdsAreExact() {
        XCTAssertEqual(WeeklyScoringService.status(accounted: 95, expected: 100), .green)
        XCTAssertEqual(WeeklyScoringService.status(accounted: 94, expected: 100), .yellow)
        XCTAssertEqual(WeeklyScoringService.status(accounted: 85, expected: 100), .yellow)
        XCTAssertEqual(WeeklyScoringService.status(accounted: 84, expected: 100), .red)
        XCTAssertEqual(WeeklyScoringService.status(accounted: 0, expected: 0), .neutral)
    }

    func testSundayAllowanceBoundary() {
        let sunday = date(2026, 8, 9)
        let earns = DayFacts(
            date: sunday,
            states: Array(repeating: .done, count: 85) + Array(repeating: .missed, count: 15),
            isExcused: false
        )
        let below = DayFacts(
            date: sunday,
            states: Array(repeating: .done, count: 84) + Array(repeating: .missed, count: 16),
            isExcused: false
        )

        XCTAssertEqual(WeeklyScoringService.allowanceEarned(days: [earns], asOf: sunday, calendar: calendar), true)
        XCTAssertEqual(WeeklyScoringService.allowanceEarned(days: [below], asOf: sunday, calendar: calendar), false)
        XCTAssertNil(WeeklyScoringService.allowanceEarned(days: [earns], asOf: date(2026, 8, 8), calendar: calendar))
    }

    func testExcusedDaysAreExcludedFromDenominator() {
        let days = [
            DayFacts(date: date(2026, 8, 3), states: [.done], isExcused: false),
            DayFacts(date: date(2026, 8, 4), states: [.missed, .missed], isExcused: true)
        ]

        let summary = WeeklyScoringService.summary(days: days, today: date(2026, 8, 4), calendar: calendar)

        XCTAssertEqual(summary.accountedCount, 1)
        XCTAssertEqual(summary.expectedCount, 1)
    }

    func testStreakCompleteDaysExtendWhileExcusedAndZeroItemDaysAreNeutral() {
        let days = [
            DayFacts(date: date(2026, 8, 3), states: [.done, .notNeeded], isExcused: false),
            DayFacts(date: date(2026, 8, 4), states: [.missed], isExcused: true),
            DayFacts(date: date(2026, 8, 5), states: [], isExcused: false),
            DayFacts(date: date(2026, 8, 6), states: [.done], isExcused: false),
            DayFacts(date: date(2026, 8, 7), states: [.unmarked], isExcused: false)
        ]

        XCTAssertEqual(StreakService.currentStreak(days: days, today: date(2026, 8, 7), calendar: calendar), 2)

        let broken = days + [DayFacts(date: date(2026, 8, 8), states: [.missed], isExcused: false)]
        XCTAssertEqual(StreakService.currentStreak(days: broken, today: date(2026, 8, 8), calendar: calendar), 0)
    }

    func testChildCannotEditParentCreatedDefinition() {
        let child = FamilyUser(displayName: "Child", role: .child, avatar: .fox)
        let parentID = UUID()
        let item = Responsibility(
            title: "Make bed",
            category: .home,
            creatorID: parentID,
            creatorRole: .parent,
            assignedChildID: child.id
        )

        XCTAssertFalse(PermissionService.canManageDefinition(user: child, responsibility: item))
        XCTAssertTrue(PermissionService.canSetState(
            user: child,
            responsibility: item,
            state: .done,
            date: date(2026, 8, 9),
            today: date(2026, 8, 9),
            calendar: calendar
        ))
        XCTAssertFalse(PermissionService.canSetState(
            user: child,
            responsibility: item,
            state: .missed,
            date: date(2026, 8, 9),
            today: date(2026, 8, 9),
            calendar: calendar
        ))
    }

    func testParentCanResetDoneAndNotNeededToUnmarked() {
        let parent = FamilyUser(displayName: "Parent", role: .parent, avatar: .sun)
        let childID = UUID()
        let item = Responsibility(
            title: "Pack bag",
            category: .school,
            creatorID: parent.id,
            creatorRole: .parent,
            assignedChildID: childID
        )

        for originalState in [DailyStateKind.done, .notNeeded] {
            let record = DailyRecord(
                responsibilityID: item.id,
                childID: childID,
                day: date(2026, 8, 9),
                state: originalState,
                calendar: calendar
            )
            XCTAssertTrue(PermissionService.canSetState(
                user: parent,
                responsibility: item,
                state: .unmarked,
                date: record.day,
                today: date(2026, 8, 9),
                calendar: calendar
            ))
            record.state = .unmarked
            XCTAssertEqual(record.state, .unmarked)
        }
    }

    func testWeeklyCalculationUsesMondayThroughTodayOnly() {
        let today = date(2026, 8, 5)
        let days = [
            DayFacts(date: date(2026, 8, 2), states: [.missed], isExcused: false),
            DayFacts(date: date(2026, 8, 3), states: [.done], isExcused: false),
            DayFacts(date: date(2026, 8, 5), states: [.notNeeded], isExcused: false),
            DayFacts(date: date(2026, 8, 6), states: [.missed], isExcused: false)
        ]

        let summary = WeeklyScoringService.summary(days: days, today: today, calendar: calendar)

        XCTAssertEqual(summary.accountedCount, 2)
        XCTAssertEqual(summary.expectedCount, 2)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}

import XCTest
@testable import EarnedIt

@MainActor
final class BusinessRulesTests: XCTestCase {
    func testSevenCanonicalListsAndMondayRecurrenceWithoutCompletionRecurrence() throws {
        let family = try TestFamily()
        XCTAssertEqual(family.store.household?.weekdayLists.map(\.weekday), Weekday.allCases)
        XCTAssertEqual(Set(family.store.household!.weekdayLists.map(\.id)).count, 7)
        let id = try family.chore()
        try family.complete(id, as: family.hanna)
        family.move(to: "2026-09-08T16:00:00Z")
        XCTAssertTrue(family.store.dailyList().isEmpty)
        family.move(to: "2026-09-14T16:00:00Z")
        let chore = try XCTUnwrap(family.store.dailyList().first)
        XCTAssertEqual(chore.id, id)
        XCTAssertEqual(chore.state(for: family.hanna.id), .unmarked)
        XCTAssertFalse(chore.isFullyComplete)
        XCTAssertEqual(family.store.snapshot.completions.count, 1)
    }

    func testTwoIndependentCompletionsOnOneChoreSurviveReopening() throws {
        let family = try TestFamily()
        let id = try family.chore()
        try family.complete(id, as: family.hanna)
        try family.complete(id, as: family.alek)
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.dailyList().count, 1)
        XCTAssertEqual(Set(reopened.dailyList()[0].completedMembers.map(\.id)), [family.hanna.id, family.alek.id])
        XCTAssertTrue(reopened.dailyList()[0].isFullyComplete)
    }

    func testHannaCompletionDoesNotCreditAlekOnRequiredChore() throws {
        let family = try TestFamily()
        let id = try family.chore(.multiple, ids: [family.hanna.id, family.alek.id])
        try family.complete(id, as: family.hanna)
        let hanna = WeeklyScoringService.summary(days: family.store.weekFacts(for: family.hanna.id), today: family.clock.now, calendar: family.store.calendar)
        let alek = WeeklyScoringService.summary(days: family.store.weekFacts(for: family.alek.id), today: family.clock.now, calendar: family.store.calendar)
        XCTAssertEqual(hanna, WeeklySummary(accountedCount: 1, expectedCount: 1))
        XCTAssertEqual(alek, WeeklySummary(accountedCount: 0, expectedCount: 1))
        XCTAssertFalse(family.store.dailyList()[0].isFullyComplete)
    }

    func testAllRequirementModesSeparateEligibilityAndFullCompletion() throws {
        for mode in RequirementMode.allCases {
            let family = try TestFamily()
            let ids = mode == .particular ? [family.hanna.id] : [family.hanna.id, family.alek.id]
            let id = try family.chore(mode, ids: ids)
            let expectedCount = mode == .particular ? 1 : 2
            XCTAssertEqual(family.store.dailyList()[0].eligibleMembers.count, expectedCount, mode.rawValue)
            XCTAssertEqual(family.store.dailyList()[0].requiredMembers.count, mode == .anyOne ? 0 : expectedCount)
            XCTAssertEqual(family.store.dailyList()[0].requiredCompletionCount, mode == .anyOne ? 1 : expectedCount)
            try family.complete(id, as: family.hanna)
            XCTAssertEqual(family.store.dailyList()[0].isFullyComplete, mode == .particular || mode == .anyOne, mode.rawValue)
            if expectedCount == 2 {
                try family.complete(id, as: family.alek)
                XCTAssertTrue(family.store.dailyList()[0].isFullyComplete)
            }
        }
    }

    func testAnyOneContributionCreditsOnlyContributorAndOthersAreNeutral() throws {
        let family = try TestFamily()
        let id = try family.chore(.anyOne, ids: [family.hanna.id, family.alek.id])
        XCTAssertEqual(family.store.weekFacts(for: family.hanna.id)[0].expectedCount, 0)
        try family.complete(id, as: family.hanna)
        XCTAssertTrue(family.store.dailyList()[0].isFullyComplete)
        XCTAssertEqual(family.store.weekFacts(for: family.hanna.id)[0].accountedCount, 1)
        XCTAssertEqual(family.store.weekFacts(for: family.hanna.id)[0].expectedCount, 1)
        XCTAssertEqual(family.store.weekFacts(for: family.alek.id)[0].accountedCount, 0)
        XCTAssertEqual(family.store.weekFacts(for: family.alek.id)[0].expectedCount, 0)
        family.move(to: "2026-09-14T16:00:00Z")
        let previous = ISO8601DateFormatter().date(from: "2026-09-07T16:00:00Z")!
        XCTAssertEqual(WeeklyScoringService.allowanceEarned(days: family.store.weekFacts(for: family.hanna.id, containing: previous), asOf: family.clock.now, calendar: family.store.calendar), true)
        XCTAssertNil(WeeklyScoringService.allowanceEarned(days: family.store.weekFacts(for: family.alek.id, containing: previous), asOf: family.clock.now, calendar: family.store.calendar))
    }

    func testRemovalChangesOnlySelectedMembersDatedContribution() throws {
        let family = try TestFamily()
        let id = try family.chore()
        try family.complete(id, as: family.hanna)
        try family.complete(id, as: family.alek)
        try family.complete(id, as: family.hanna, state: .unmarked)
        XCTAssertEqual(family.store.dailyList()[0].state(for: family.hanna.id), .unmarked)
        XCTAssertEqual(family.store.dailyList()[0].state(for: family.alek.id), .done)
        XCTAssertEqual(family.store.snapshot.completions.count, 2)
    }

    func testParentSeesAllExpectedCompletedAndRemainingMembersOnSameList() throws {
        let family = try TestFamily()
        let id = try family.chore()
        try family.complete(id, as: family.hanna)
        let list = ChoreRules.visibleList(family.store.dailyList(), to: family.parent)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(Set(list[0].eligibleMembers.map(\.id)), [family.hanna.id, family.alek.id])
        XCTAssertEqual(list[0].completedMembers.map(\.id), [family.hanna.id])
        XCTAssertEqual(list[0].remainingMembers.map(\.id), [family.alek.id])
        XCTAssertFalse(list[0].isFullyComplete)
    }

    func testChildCannotChangeOthersOrParentConfiguration() throws {
        let family = try TestFamily()
        let id = try family.chore()
        try family.store.selectProfile(family.hanna.id)
        XCTAssertThrowsError(try family.store.setCompletion(choreID: id, memberID: family.alek.id, date: family.clock.now, state: .done))
        XCTAssertThrowsError(try family.chore())
        XCTAssertThrowsError(try family.store.archiveChore(id))
        XCTAssertThrowsError(try family.store.saveMember(name: "Extra", role: .parent, avatar: .sun))
        XCTAssertThrowsError(try family.store.archiveMember(family.alek.id))
        XCTAssertThrowsError(try family.store.setExcused(memberID: family.hanna.id, date: family.clock.now, excused: true))
        XCTAssertThrowsError(try family.store.resetLocalData())
        XCTAssertTrue(family.store.snapshot.completions.isEmpty)
    }

    func testChildVisibilityAndIneligibleCompletion() throws {
        let family = try TestFamily()
        let id = try family.chore(.particular, ids: [family.hanna.id])
        XCTAssertTrue(ChoreRules.visibleList(family.store.dailyList(), to: family.alek).isEmpty)
        XCTAssertEqual(ChoreRules.visibleList(family.store.dailyList(), to: family.hanna).count, 1)
        try family.store.selectProfile(family.alek.id)
        XCTAssertThrowsError(try family.store.setCompletion(choreID: id, memberID: family.alek.id, date: family.clock.now, state: .done))
    }

    func testSameDayReassignmentPreservesTodaysHistoryAndStartsTomorrow() throws {
        let family = try TestFamily()
        let id = try family.chore(.particular, ids: [family.hanna.id])
        try family.complete(id, as: family.hanna)
        try family.store.selectProfile(family.parent.id)
        try family.store.saveChore(choreID: id, weekday: .monday, title: "Water plants", mode: .particular, memberIDs: [family.alek.id])
        XCTAssertEqual(family.store.dailyList()[0].eligibleMembers.map(\.id), [family.hanna.id])
        XCTAssertEqual(family.store.weekFacts(for: family.hanna.id)[0].accountedCount, 1)
        XCTAssertEqual(family.store.weekFacts(for: family.alek.id)[0].expectedCount, 0)
        family.move(to: "2026-09-14T16:00:00Z")
        XCTAssertEqual(family.store.dailyList()[0].eligibleMembers.map(\.id), [family.alek.id])
        XCTAssertEqual(family.store.dailyList()[0].state(for: family.alek.id), .unmarked)
    }

    func testCreationAndArchiveUseHouseholdDayAcrossTimezoneAndDSTBoundaries() throws {
        let family = try TestFamily()
        family.move(to: "2026-11-02T04:30:00Z") // Still Sunday in New York after the DST transition.
        let id = try family.chore(.all, weekday: .sunday)
        XCTAssertEqual(family.store.day.rawValue, "2026-11-01")
        try family.complete(id, as: family.hanna)
        try family.store.selectProfile(family.parent.id)
        try family.store.archiveChore(id)
        XCTAssertEqual(family.store.dailyList().count, 1)
        let persisted = family.store.snapshot.revisions.last!
        XCTAssertEqual(persisted.effectiveDay.rawValue, "2026-11-02")
        family.move(to: "2026-11-02T05:30:00Z")
        XCTAssertEqual(family.store.day.rawValue, "2026-11-02")
        XCTAssertTrue(family.store.dailyList().isEmpty)
        var tokyo = AppCalendar.current
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let completionDay = family.store.snapshot.completions[0].day
        XCTAssertEqual(completionDay.rawValue, "2026-11-01")
        XCTAssertEqual(CivilDay(completionDay.date(in: tokyo), calendar: tokyo), completionDay)
    }

    func testMembershipChangesPreserveTodayAndHistoricalAllChildrenRequirements() throws {
        let family = try TestFamily()
        let id = try family.chore()
        try family.complete(id, as: family.hanna)
        try family.store.selectProfile(family.parent.id)
        let extra = try family.store.saveMember(name: "Later Child", role: .child, avatar: .star)
        try family.store.archiveMember(family.alek.id)
        XCTAssertEqual(Set(family.store.dailyList()[0].eligibleMembers.map(\.id)), [family.hanna.id, family.alek.id])
        family.move(to: "2026-09-14T16:00:00Z")
        XCTAssertEqual(Set(family.store.dailyList()[0].eligibleMembers.map(\.id)), [family.hanna.id, extra.id])
        let previous = ISO8601DateFormatter().date(from: "2026-09-07T16:00:00Z")!
        XCTAssertEqual(family.store.dailyList(on: previous)[0].state(for: family.hanna.id), .done)
        XCTAssertEqual(family.store.dailyList(on: previous)[0].state(for: family.alek.id), .missed)
    }

    func testPastUnmarkedDerivesMissedAndParentCanCorrectHistory() throws {
        let family = try TestFamily()
        let id = try family.chore()
        let monday = family.clock.now
        family.move(to: "2026-09-08T16:00:00Z")
        XCTAssertEqual(family.store.dailyList(on: monday)[0].state(for: family.hanna.id), .missed)
        try family.store.selectProfile(family.hanna.id)
        XCTAssertThrowsError(try family.store.setCompletion(choreID: id, memberID: family.hanna.id, date: monday, state: .done))
        try family.store.selectProfile(family.parent.id)
        try family.store.setCompletion(choreID: id, memberID: family.hanna.id, date: monday, state: .done)
        XCTAssertEqual(family.store.dailyList(on: monday)[0].state(for: family.hanna.id), .done)
        XCTAssertThrowsError(try family.store.setCompletion(choreID: id, memberID: family.hanna.id, date: monday, state: .unmarked))
        XCTAssertEqual(family.store.snapshot.completions.count, 1)
    }


    func testAnyOnePersonalExemptionDoesNotClearAnotherChildsOpportunity() throws {
        let family = try TestFamily()
        let id = try family.chore(.anyOne, ids: [family.hanna.id, family.alek.id])
        try family.complete(id, as: family.hanna, state: .notNeeded)
        XCTAssertFalse(family.store.dailyList()[0].isFullyComplete)
        XCTAssertEqual(family.store.dailyList()[0].remainingMembers.map(\.id), [family.alek.id])
        try family.complete(id, as: family.alek, state: .notNeeded)
        XCTAssertTrue(family.store.dailyList()[0].isFullyComplete)
        XCTAssertTrue(family.store.dailyList()[0].completedMembers.isEmpty)
    }

    func testInvalidRequirementCombinationsAreRejected() throws {
        let family = try TestFamily()
        XCTAssertThrowsError(try family.chore(.particular, ids: []))
        XCTAssertThrowsError(try family.chore(.particular, ids: [family.hanna.id, family.alek.id]))
        XCTAssertThrowsError(try family.chore(.multiple, ids: [family.hanna.id]))
        XCTAssertThrowsError(try family.chore(.anyOne, ids: [family.parent.id]))
        XCTAssertTrue(family.store.snapshot.revisions.isEmpty)
    }


    func testMixedRequiredAndOptionalWeeklyCreditMatchesDocumentedExample() throws {
        let family = try TestFamily()
        var required: [UUID] = []
        for index in 1...4 {
            required.append(try family.store.saveChore(weekday: .monday, title: "Required \(index)", mode: .all, memberIDs: []))
        }
        let optional = try family.chore(.anyOne, ids: [family.hanna.id, family.alek.id])
        for id in required.prefix(3) { try family.complete(id, as: family.hanna) }
        try family.complete(optional, as: family.hanna)
        try family.complete(optional, as: family.hanna) // Repeating an action does not earn extra credit.
        let summary = WeeklyScoringService.summary(days: family.store.weekFacts(for: family.hanna.id),
                                                   today: family.clock.now, calendar: family.store.calendar)
        XCTAssertEqual(summary, WeeklySummary(accountedCount: 4, expectedCount: 5))
        XCTAssertEqual(family.store.weekFacts(for: family.alek.id)[0].expectedCount, 4)
        XCTAssertEqual(family.store.weekFacts(for: family.alek.id)[0].accountedCount, 0)
    }

    func testWeeklyThresholdsAllowanceAndFutureExclusion() throws {
        let family = try TestFamily()
        let calendar = family.store.calendar
        let monday = family.clock.now
        let sunday = calendar.date(byAdding: .day, value: 6, to: monday)!
        let nextMonday = calendar.date(byAdding: .day, value: 7, to: monday)!
        XCTAssertEqual(WeeklyScoringService.status(accounted: 95, expected: 100), .green)
        XCTAssertEqual(WeeklyScoringService.status(accounted: 94, expected: 100), .yellow)
        XCTAssertEqual(WeeklyScoringService.status(accounted: 85, expected: 100), .yellow)
        XCTAssertEqual(WeeklyScoringService.status(accounted: 84, expected: 100), .red)
        XCTAssertEqual(WeeklyScoringService.status(accounted: 0, expected: 0), .neutral)
        let days = [DayFacts(date: monday, states: Array(repeating: .done, count: 85) + Array(repeating: .missed, count: 15), isExcused: false)]
        XCTAssertNil(WeeklyScoringService.allowanceEarned(days: days, asOf: sunday, calendar: calendar))
        XCTAssertEqual(WeeklyScoringService.allowanceEarned(days: days, asOf: nextMonday, calendar: calendar), true)
        let future = DayFacts(date: sunday, states: [.missed], isExcused: false)
        XCTAssertEqual(WeeklyScoringService.summary(days: days + [future], today: monday, calendar: calendar).expectedCount, 100)
    }

    func testDoneNotNeededExcusesAndStreakNeutrality() throws {
        let family = try TestFamily()
        let id = try family.chore()
        try family.complete(id, as: family.hanna, state: .notNeeded)
        XCTAssertEqual(family.store.weekFacts(for: family.hanna.id)[0].accountedCount, 1)
        XCTAssertEqual(MetricsService.streak(childID: family.hanna.id, snapshot: family.store.snapshot, today: family.clock.now), 1)
        try family.store.selectProfile(family.parent.id)
        try family.store.setExcused(memberID: family.alek.id, date: family.clock.now, excused: true)
        XCTAssertEqual(family.store.weekFacts(for: family.alek.id)[0].expectedCount, 0)
        XCTAssertEqual(family.store.weekFacts(for: family.alek.id)[0].accountedCount, 0)
        let calendar = family.store.calendar
        let tuesday = calendar.date(byAdding: .day, value: 1, to: family.clock.now)!
        let wednesday = calendar.date(byAdding: .day, value: 2, to: family.clock.now)!
        let days = [DayFacts(date: family.clock.now, states: [.done], isExcused: false),
                    DayFacts(date: tuesday, states: [.missed], isExcused: true),
                    DayFacts(date: wednesday, states: [], isExcused: false)]
        XCTAssertEqual(StreakService.currentStreak(days: days, today: wednesday, calendar: calendar), 1)
    }
    func testMutationRefreshesHouseholdMidnightWithoutDeviceDayNotification() throws {
        let family = try TestFamily()
        family.move(to: "2026-09-08T03:59:59Z")
        let monday = try family.chore()
        let tuesday = try family.chore(.all, weekday: .tuesday)
        let staleDate = family.store.today
        let midnight = family.store.nextHouseholdMidnight
        XCTAssertEqual(midnight, ISO8601DateFormatter().date(from: "2026-09-08T04:00:00Z"))
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        try family.store.selectProfile(family.hanna.id)
        family.clock.set("2026-09-08T04:00:01Z")
        XCTAssertEqual(CivilDay(staleDate, calendar: tokyo), CivilDay(family.clock.now, calendar: tokyo))
        XCTAssertThrowsError(try family.store.setCompletion(choreID: monday, memberID: family.hanna.id,
                                                            date: staleDate, state: .done))
        try family.store.setCompletion(choreID: tuesday, memberID: family.hanna.id,
                                       date: family.clock.now, state: .done)
        XCTAssertEqual(family.store.snapshot.completions.first?.day.rawValue, "2026-09-08")
        try family.store.selectProfile(family.parent.id)
        family.clock.set("2026-09-09T04:00:01Z")
        try family.store.archiveChore(tuesday)
        XCTAssertEqual(family.store.snapshot.revisions.last?.effectiveDay.rawValue, "2026-09-10")
        XCTAssertEqual(family.store.day.rawValue, "2026-09-09")
        XCTAssertGreaterThan(family.store.nextHouseholdMidnight, family.clock.now)
    }

    func testSignificantClockChangeInvalidatesSameDayMidnightSchedule() throws {
        let family = try TestFamily()
        family.move(to: "2026-09-08T01:00:00Z")
        let midnight = family.store.nextHouseholdMidnight
        let revision = family.store.midnightTimerRevision
        let originalDelay = midnight.timeIntervalSince(family.clock.now)
        family.clock.set("2026-09-08T03:00:00Z")
        family.store.significantTimeChanged()
        XCTAssertEqual(family.store.nextHouseholdMidnight, midnight)
        XCTAssertNotEqual(family.store.midnightTimerRevision, revision)
        XCTAssertEqual(family.store.today, family.clock.now)
        XCTAssertEqual(family.store.nextHouseholdMidnight.timeIntervalSince(family.store.today), originalDelay - 7200)
        family.clock.set("2026-09-08T04:00:00Z")
        family.store.refreshDate()
        XCTAssertEqual(family.store.day.rawValue, "2026-09-08")
    }

}

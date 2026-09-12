import XCTest
@testable import EarnedIt

@MainActor
final class AllowanceTests: XCTestCase {
    private let us = Locale(identifier: "en_US")

    func testDecimalInputCurrencyPrecisionAndValidation() throws {
        let usd = try XCTUnwrap(AllowanceAmount.parse("12.34", currencyCode: "USD", locale: us))
        XCTAssertEqual(usd.minorUnits, 1234)
        XCTAssertEqual(usd.formatted(locale: us), "$12.34")
        let arabic = Locale(identifier: "ar_SA")
        XCTAssertEqual(try AllowanceAmount.parse(usd.inputText(locale: arabic), currencyCode: "USD", locale: arabic), usd)
        XCTAssertEqual(try AllowanceAmount.parse("12,34", currencyCode: "EUR", locale: Locale(identifier: "de_DE"))?.minorUnits, 1234)
        XCTAssertEqual(try AllowanceAmount.parse("123", currencyCode: "JPY", locale: us)?.minorUnits, 123)
        XCTAssertEqual(try AllowanceAmount.parse("1.234", currencyCode: "KWD", locale: us)?.minorUnits, 1234)
        XCTAssertEqual(try AllowanceAmount.parse("0", currencyCode: "USD", locale: us)?.minorUnits, 0)
        XCTAssertNil(try AllowanceAmount.parse(" ", currencyCode: "USD", locale: us))
        for input in ["-1", "NaN", "1e2", "1,000", "1.001", "1000000", ".", "12.", "1.2.3", "+1"] {
            XCTAssertThrowsError(try AllowanceAmount.parse(input, currencyCode: "USD", locale: us), input)
        }
        XCTAssertThrowsError(try AllowanceAmount.parse("1.1", currencyCode: "JPY", locale: us))
        XCTAssertThrowsError(try AllowanceAmount.parse("1", currencyCode: "BAD", locale: us))
    }

    func testLegacyJournalReopensUnsetAndAmountsPersistIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let family = try TestFamily(url: directory.appending(path: "migration.store"))
        // Existing household/session and chore fact payloads predate allowance facts.
        let chore = try family.chore()
        try family.complete(chore, as: family.hanna)
        let original = try family.repository.facts(householdID: family.store.household!.id)
        let legacySessionData = try JSONEncoder().encode(family.store.session)
        XCTAssertNil(try JSONDecoder().decode(DeviceSession.self, from: legacySessionData).celebratedWeeks)
        let reopenedRepository = try HouseholdRepository(url: directory.appending(path: "migration.store"))
        let reopened = try HouseholdStore(repository: reopenedRepository, clock: { family.clock.now }, automaticSync: false)
        XCTAssertNil(reopened.allowanceWeek(for: family.hanna.id).amount)
        XCTAssertEqual(reopened.snapshot.members, family.store.snapshot.members)
        XCTAssertEqual(reopened.dailyList(), family.store.dailyList())
        try reopened.selectProfile(family.parent.id)
        try reopened.saveAllowance(memberID: family.hanna.id, text: "12.34", currencyCode: "USD", locale: us)
        try reopened.saveAllowance(memberID: family.alek.id, text: "7.89", currencyCode: "EUR", locale: us)
        let again = try HouseholdStore(repository: reopenedRepository, clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(again.allowanceWeek(for: family.hanna.id).amount?.minorUnits, 1234)
        XCTAssertEqual(again.allowanceWeek(for: family.alek.id).amount?.currencyCode, "EUR")
        XCTAssertTrue(Set(try reopenedRepository.facts(householdID: family.store.household!.id).map(\.id)).isSuperset(of: original.map(\.id)))
        try again.selectProfile(family.hanna.id)
        XCTAssertThrowsError(try again.saveAllowance(memberID: family.hanna.id, text: "100", currencyCode: "USD"))
        XCTAssertThrowsError(try again.saveAllowance(memberID: family.alek.id, text: "100", currencyCode: "USD"))
    }

    func testFinishedAmountsAndMissingTitlesSurviveEditsReassignmentAndArchive() throws {
        let family = try TestFamily()
        let monday = family.clock.now
        let chore = try family.chore(.particular, ids: [family.hanna.id])
        try family.store.saveAllowance(memberID: family.hanna.id, text: "12.34", currencyCode: "USD", locale: us)
        // Same-day edits start tomorrow; today's original assignment/title remain authoritative.
        try family.store.saveChore(choreID: chore, weekday: .monday, title: "New title", mode: .particular, memberIDs: [family.alek.id])
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id).dueToday.map(\.title), ["Water plants"])
        family.move(to: "2026-09-14T16:00:00Z")
        try family.store.saveAllowance(memberID: family.hanna.id, text: "20.05", currencyCode: "USD", locale: us)
        try family.store.archiveChore(chore)
        try family.store.archiveMember(family.hanna.id)
        family.move(to: "2026-09-15T16:00:00Z")
        let old = family.store.allowanceWeek(for: family.hanna.id, containing: monday)
        XCTAssertEqual(old.amount?.minorUnits, 1234)
        XCTAssertEqual(old.missing.map(\.title), ["Water plants"])
        XCTAssertEqual(old.missing.map(\.day.rawValue), ["2026-09-07"])
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id).amount?.minorUnits, 2005)
        try family.store.setCompletion(choreID: chore, memberID: family.hanna.id, date: monday, state: .done)
        XCTAssertTrue(family.store.allowanceWeek(for: family.hanna.id, containing: monday).earned)
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.allowanceHistory(for: family.hanna.id), family.store.allowanceHistory(for: family.hanna.id))
    }

    func testNoEmptyOptionalOnlyOrEarlyBadgeAndFutureIsNotMissing() throws {
        let family = try TestFamily()
        let monday = family.clock.now
        XCTAssertFalse(family.store.allowanceWeek(for: family.hanna.id).earned)
        let optional = try family.chore(.anyOne, ids: [family.hanna.id])
        try family.complete(optional, as: family.hanna)
        XCTAssertTrue(family.store.allowanceWeek(for: family.hanna.id).items.isEmpty)
        family.move(to: "2026-09-14T16:00:00Z")
        XCTAssertFalse(family.store.allowanceWeek(for: family.hanna.id, containing: monday).earned)
        try family.store.selectProfile(family.parent.id)
        let required = try family.chore(weekday: .sunday)
        let current = family.store.allowanceWeek(for: family.hanna.id)
        XCTAssertEqual(current.scheduled.count, 1)
        XCTAssertTrue(current.missing.isEmpty)
        XCTAssertEqual(current.status, .neutral)
        family.move(to: "2026-09-20T16:00:00Z")
        try family.complete(required, as: family.hanna)
        XCTAssertFalse(family.store.allowanceWeek(for: family.hanna.id).earned)
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id).status, .green)
        family.move(to: "2026-09-21T04:00:00Z")
        XCTAssertTrue(family.store.allowanceHistory(for: family.hanna.id)[1].earned)
        XCTAssertFalse(family.store.allowanceHistory(for: family.alek.id)[1].earned)
    }

    func testSundayGraceCorrectionAndCelebrationReceiptSurviveRelaunch() throws {
        let family = try TestFamily()
        let sundayChore = try family.chore(weekday: .sunday)
        family.move(to: "2026-09-13T16:00:00Z")
        let sunday = family.clock.now
        try family.store.selectProfile(family.hanna.id)
        family.move(to: "2026-09-14T04:00:00Z")
        XCTAssertFalse(try family.store.consumeCelebration(for: family.hanna.id))
        try family.store.setCompletion(choreID: sundayChore, memberID: family.hanna.id, date: sunday, state: .done)
        XCTAssertTrue(try family.store.consumeCelebration(for: family.hanna.id))
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        XCTAssertFalse(try reopened.consumeCelebration(for: family.hanna.id))
        family.clock.set("2026-09-15T03:59:59Z")
        try reopened.setCompletion(choreID: sundayChore, memberID: family.hanna.id, date: sunday, state: .unmarked)
        XCTAssertFalse(reopened.allowanceHistory(for: family.hanna.id)[1].earned)
        family.clock.set("2026-09-15T04:00:00Z")
        XCTAssertThrowsError(try reopened.setCompletion(choreID: sundayChore, memberID: family.hanna.id, date: sunday, state: .done)) {
            XCTAssertEqual($0 as? HouseholdError, .completionLocked)
        }
        try reopened.selectProfile(family.parent.id)
        try reopened.setCompletion(choreID: sundayChore, memberID: family.hanna.id, date: sunday, state: .done)
        XCTAssertTrue(reopened.allowanceHistory(for: family.hanna.id)[1].earned)
        try reopened.selectProfile(family.hanna.id)
        XCTAssertFalse(try reopened.consumeCelebration(for: family.hanna.id))
    }

    func testThirteenWeekRetentionWithoutDeletingSourceFactsAfterAbsence() throws {
        let family = try TestFamily()
        _ = try family.chore()
        let originalIDs = try family.repository.facts(householdID: family.store.household!.id).map(\.id)
        family.move(to: "2027-01-05T17:00:00Z")
        let history = family.store.allowanceHistory(for: family.hanna.id)
        XCTAssertEqual(history.count, 13)
        XCTAssertEqual(history.first?.start.rawValue, "2027-01-04")
        XCTAssertEqual(history.last?.start.rawValue, "2026-10-12")
        XCTAssertEqual(history.filter(\.isFinished).count, 12)
        XCTAssertEqual(history.first?.dueToday.count, 0)
        XCTAssertEqual(history.first?.missing.count, 1)
        XCTAssertEqual(try family.repository.facts(householdID: family.store.household!.id).map(\.id), originalIDs)
    }

    func testGraceAndMondayRolloverUseCivilDatesAcrossDSTAndYearBoundary() throws {
        let cases = [
            ("2026-03-08", "2026-03-10T03:59:59Z", "2026-03-10T04:00:00Z"),
            ("2026-11-01", "2026-11-03T04:59:59Z", "2026-11-03T05:00:00Z"),
            ("2026-12-31", "2027-01-02T04:59:59Z", "2027-01-02T05:00:00Z")
        ]
        var calendar = AppCalendar.current
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        for (scheduled, allowed, locked) in cases {
            let day = CivilDay(rawValue: scheduled)!
            let before = CivilDay(ISO8601DateFormatter().date(from: allowed)!, calendar: calendar)
            let after = CivilDay(ISO8601DateFormatter().date(from: locked)!, calendar: calendar)
            XCTAssertTrue(PermissionService.canChildEdit(day: day, today: before))
            XCTAssertFalse(PermissionService.canChildEdit(day: day, today: after))
        }
        let family = try TestFamily()
        family.move(to: "2027-01-04T04:59:59Z")
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id).start.rawValue, "2026-12-28")
        family.clock.set("2027-01-04T05:00:00Z")
        family.store.significantTimeChanged()
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id).start.rawValue, "2027-01-04")
    }

    func testExcusesAndNotNeededAccountForRequiredItemsWithoutSiblingCredit() throws {
        let family = try TestFamily()
        let chore = try family.chore()
        try family.complete(chore, as: family.hanna, state: .notNeeded)
        family.move(to: "2026-09-14T16:00:00Z")
        XCTAssertTrue(family.store.allowanceHistory(for: family.hanna.id)[1].earned)
        XCTAssertFalse(family.store.allowanceHistory(for: family.alek.id)[1].earned)
        try family.store.selectProfile(family.parent.id)
        try family.store.setExcused(memberID: family.alek.id, date: CivilDay(rawValue: "2026-09-07")!.date(in: family.store.calendar), excused: true)
        XCTAssertTrue(family.store.allowanceHistory(for: family.alek.id)[1].items.isEmpty)
        XCTAssertFalse(family.store.allowanceHistory(for: family.alek.id)[1].earned)
    }

    func testOfflineAllowanceAndHistoricalCorrectionsConvergeWithTransportDouble() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: transport)
        let chore = try family.chore()
        let monday = family.clock.now
        try family.store.saveAllowance(memberID: family.hanna.id, text: "12.34", currencyCode: "USD", locale: us)
        try await family.store.connect()
        let other = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                       transport: TestTransport(server: server, account: "owner"),
                                       clock: { family.clock.now }, automaticSync: false)
        try await other.joinExisting(family.store.session.location!)
        try other.requestProfiles([family.parent.id], deviceName: "Existing parent installation")
        try await other.synchronize()
        try await family.store.synchronize()
        try family.store.approve(XCTUnwrap(family.store.pendingRequests.first), memberIDs: [family.parent.id])
        try await family.store.synchronize()
        try await other.synchronize()
        try other.selectProfile(family.parent.id)
        family.move(to: "2026-09-14T16:00:00Z")
        try family.store.saveAllowance(memberID: family.hanna.id, text: "20.50", currencyCode: "USD", locale: us)
        try family.store.setCompletion(choreID: chore, memberID: family.hanna.id, date: monday, state: .done)
        transport.fetchError = HouseholdError.cloudUnavailable
        do { try await family.store.synchronize(); XCTFail("Expected offline failure") } catch {}
        XCTAssertGreaterThan(family.store.pendingCount, 0)
        XCTAssertTrue(family.store.allowanceHistory(for: family.hanna.id)[1].earned)
        transport.fetchError = nil
        try await family.store.synchronize()
        try await other.synchronize()
        XCTAssertEqual(other.allowanceHistory(for: family.hanna.id), family.store.allowanceHistory(for: family.hanna.id))
        XCTAssertEqual(other.allowanceHistory(for: family.hanna.id)[1].amount?.minorUnits, 1234)
        XCTAssertEqual(other.allowanceWeek(for: family.hanna.id).amount?.minorUnits, 2050)
    }
}

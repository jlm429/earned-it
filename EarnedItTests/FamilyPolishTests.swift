import CloudKit
import XCTest
@testable import EarnedIt

@MainActor
final class FamilyPolishTests: XCTestCase {
    func testNudgeCanBeSentAgainAfterShortCooldown() throws {
        let family = try TestFamily()
        let chore = try family.chore()
        try family.store.nudge(choreID: chore)
        XCTAssertThrowsError(try family.store.nudge(choreID: chore))
        family.move(to: "2026-09-07T16:00:59Z")
        XCTAssertFalse(family.store.canNudge(try XCTUnwrap(family.store.dailyList().first)))
        family.move(to: "2026-09-07T16:01:00Z")
        XCTAssertTrue(family.store.canNudge(try XCTUnwrap(family.store.dailyList().first)))
        XCTAssertNoThrow(try family.store.nudge(choreID: chore))
    }

    func testLegacyNudgeRoundTripKeepsReceiptWithoutBlockingNewReminders() throws {
        let family = try TestFamily()
        let chore = try family.chore()
        let row = try XCTUnwrap(family.store.dailyList().first)
        let legacy = ChoreNudge(scope: ChoreScope(row), memberID: family.hanna.id,
                                recordedByMemberID: family.parent.id)
        let decoded = try JSONDecoder().decode(ChoreNudge.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.sentAt)
        XCTAssertEqual(decoded.activityID(householdID: family.store.household!.id),
                       legacy.activityID(householdID: family.store.household!.id))
        try family.repository.commit(facts: [fact(family, body: .choreNudge(decoded), author: family.parent.id)])
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        XCTAssertTrue(reopened.canNudge(row))
        try reopened.nudge(choreID: chore)
        try reopened.selectProfile(family.hanna.id)
        XCTAssertEqual(reopened.activity.filter { $0.title == "A little reminder" }.count, 2)
    }

    func testSelectedWeekAmountIncludesOnlyItsBonuses() throws {
        let family = try TestFamily()
        try family.store.saveAllowance(memberID: family.hanna.id, text: "12", currencyCode: "USD")
        let firstWeek = family.clock.now
        try family.store.awardBonus(memberID: family.hanna.id, text: "3", currencyCode: "USD",
                                   note: "Helping", awardID: UUID())
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id).amount?.minorUnits, 1500)
        family.move(to: "2026-09-14T04:00:00Z")
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id).amount?.minorUnits, 1200)
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id, containing: firstWeek).amount?.minorUnits, 1500)
    }

    func testBonusWeekBoundariesCurrenciesAndRepeatedProjectionSurviveRelaunch() throws {
        let family = try TestFamily()
        try family.store.saveAllowance(memberID: family.hanna.id, text: "12", currencyCode: "USD")
        family.move(to: "2026-09-14T03:59:59Z")
        let sunday = family.clock.now
        let awardID = UUID()
        for _ in 0..<2 {
            try family.store.awardBonus(memberID: family.hanna.id, text: "3", currencyCode: "USD",
                                       note: "Sunday", awardID: awardID)
        }
        family.move(to: "2026-09-14T04:00:00Z")
        try family.store.awardBonus(memberID: family.hanna.id, text: "2", currencyCode: "USD", note: "Monday", awardID: UUID())
        try family.store.awardBonus(memberID: family.hanna.id, text: "500", currencyCode: "JPY", note: "", awardID: UUID())
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        for _ in 0..<3 {
            let previous = reopened.allowanceWeek(for: family.hanna.id, containing: sunday)
            XCTAssertEqual(previous.amount?.minorUnits, 1500)
            XCTAssertEqual(previous.bonuses, [AllowanceAmount(minorUnits: 300, currencyCode: "USD")])
            let current = reopened.allowanceWeek(for: family.hanna.id)
            XCTAssertEqual(current.amount, AllowanceAmount(minorUnits: 1400, currencyCode: "USD"))
            XCTAssertEqual(current.baseAmount?.minorUnits, 1200)
            XCTAssertEqual(current.bonuses, [AllowanceAmount(minorUnits: 500, currencyCode: "JPY"),
                                            AllowanceAmount(minorUnits: 200, currencyCode: "USD")])
            XCTAssertEqual(reopened.allowanceWeek(for: family.alek.id).bonuses, [])
        }
        family.move(to: "2026-09-21T04:00:00Z")
        reopened.refreshDate()
        XCTAssertEqual(reopened.allowanceWeek(for: family.hanna.id).amount?.minorUnits, 1200)
        XCTAssertTrue(reopened.allowanceWeek(for: family.hanna.id).bonuses.isEmpty)
    }

    func testNudgeBadgeReadCompletionRelaunchAndPreference() async throws {
        let family = try TestFamily()
        let chore = try family.chore()
        let alerts = PolishAlerts()
        let child = try HouseholdStore(repository: family.repository, clock: { family.clock.now },
                                       automaticSync: false, activityAlerts: alerts)
        try child.selectProfile(family.hanna.id)
        await child.setActivityAlertsEnabled(true)
        try family.store.nudge(choreID: chore)
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now },
                                          automaticSync: false, activityAlerts: alerts)
        await reopened.processActivityAlerts()
        XCTAssertEqual(alerts.deliveries, 1)
        XCTAssertEqual(alerts.badgeCount, reopened.unreadActivityCount)
        for item in reopened.activity { try reopened.markActivityRead(item) }
        await reopened.processActivityAlerts()
        XCTAssertEqual(alerts.badgeCount, 0)
        let again = try HouseholdStore(repository: family.repository, clock: { family.clock.now },
                                       automaticSync: false, activityAlerts: alerts)
        await again.processActivityAlerts()
        XCTAssertEqual(alerts.badgeCount, 0)
        XCTAssertEqual(alerts.deliveries, 1)
        family.move(to: "2026-09-07T16:01:00Z")
        again.refreshDate()
        try again.selectProfile(family.parent.id)
        try again.nudge(choreID: chore)
        try again.selectProfile(family.hanna.id)
        await again.processActivityAlerts()
        XCTAssertEqual(alerts.deliveries, 2)
        XCTAssertEqual(alerts.badgeCount, 1)
        try again.setCompletion(choreID: chore, memberID: family.hanna.id, date: family.clock.now, state: .done)
        await again.processActivityAlerts()
        XCTAssertEqual(alerts.badgeCount, 0)
        await again.setActivityAlertsEnabled(false)
        XCTAssertEqual(alerts.badgeCount, 0)
    }

    private func setupSwap(_ family: TestFamily) throws -> (UUID, UUID) {
        let chore = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        try family.store.selectProfile(family.hanna.id)
        try family.store.requestSwap(choreID: chore, recipientID: family.alek.id)
        return (chore, try XCTUnwrap(family.store.swaps.last?.id))
    }

    private func accept(_ family: TestFamily, _ id: UUID) throws {
        try family.store.selectProfile(family.alek.id)
        try family.store.decideSwap(requestFactID: id, kind: .accepted)
    }

    private func fact(_ family: TestFamily, body: HouseholdFactBody, author: UUID,
                      sequence: Int64? = nil, id: UUID = UUID()) -> HouseholdFact {
        HouseholdFact(id: id, householdID: family.store.household!.id,
                      sequence: sequence ?? (family.store.snapshot.orderedFacts.last!.sequence + 1),
                      authorDeviceID: UUID(), authorMemberID: author, body: body)
    }

    func testBonusIsParentAuthorizedIdempotentAndIndependentOfWeeklyOutcomes() throws {
        let family = try TestFamily()
        _ = try family.chore()
        try family.store.saveAllowance(memberID: family.hanna.id, text: "12.34", currencyCode: "USD")
        let before = family.store.allowanceWeek(for: family.hanna.id)
        let awardID = UUID()
        for _ in 0..<2 {
            try family.store.awardBonus(memberID: family.hanna.id, text: "2.05", currencyCode: "USD",
                                       note: "Helped a sibling", awardID: awardID)
        }
        let after = family.store.allowanceWeek(for: family.hanna.id)
        XCTAssertEqual(after.amount?.minorUnits, 1439)
        XCTAssertEqual(after.baseAmount, before.baseAmount)
        XCTAssertEqual(after.items, before.items)
        XCTAssertEqual(after.earned, before.earned)
        XCTAssertEqual(family.store.bonusHistory(for: family.hanna.id).map(\.award.amount.minorUnits), [205])
        family.move(to: "2026-09-21T16:00:00Z")
        try family.store.saveAllowance(memberID: family.hanna.id, text: "20", currencyCode: "USD")
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.bonusHistory(for: family.hanna.id).first?.award.note, "Helped a sibling")
        try reopened.selectProfile(family.hanna.id)
        XCTAssertTrue(reopened.activity.contains { $0.title == "Bonus awarded" })
        XCTAssertThrowsError(try reopened.awardBonus(memberID: family.hanna.id, text: "2", currencyCode: "USD",
                                                    note: "", awardID: UUID()))
        XCTAssertThrowsError(try reopened.nudge(choreID: UUID()))
    }

    func testBonusValidationAndCurrencyRemainExplicit() throws {
        let family = try TestFamily()
        for invalid in ["", "0", "-1", "2.001", "1000000"] {
            XCTAssertThrowsError(try family.store.awardBonus(memberID: family.hanna.id, text: invalid,
                currencyCode: "USD", note: "", awardID: UUID()))
        }
        XCTAssertThrowsError(try family.store.awardBonus(memberID: family.parent.id, text: "5",
            currencyCode: "USD", note: "", awardID: UUID()))
        try family.store.awardBonus(memberID: family.hanna.id, text: "500", currencyCode: "JPY", note: "", awardID: UUID())
        try family.store.awardBonus(memberID: family.hanna.id, text: "2", currencyCode: "EUR", note: "", awardID: UUID())
        XCTAssertEqual(Set(family.store.bonusHistory(for: family.hanna.id).map(\.award.amount.currencyCode)), ["JPY", "EUR"])
    }

    func testManualNudgeOnlyTargetsIncompleteUnexcusedChildrenAndDeduplicates() throws {
        let family = try TestFamily()
        let chore = try family.chore()
        try family.complete(chore, as: family.hanna)
        try family.store.selectProfile(family.parent.id)
        try family.store.nudge(choreID: chore)
        let nudges = family.store.snapshot.orderedFacts.filter { if case .choreNudge = $0.body { return true }; return false }
        XCTAssertEqual(nudges.count, 1)
        XCTAssertThrowsError(try family.store.nudge(choreID: chore))
        let original = try XCTUnwrap(nudges.first)
        try family.repository.commit(facts: [fact(family, body: original.body, author: family.parent.id)])
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        try reopened.selectProfile(family.alek.id)
        XCTAssertEqual(reopened.activity.filter { $0.title == "A little reminder" }.count, 1)
        try reopened.setCompletion(choreID: chore, memberID: family.alek.id, date: family.clock.now, state: .done)
        XCTAssertFalse(reopened.activity.contains { $0.title == "A little reminder" })
        try reopened.selectProfile(family.parent.id)
        XCTAssertFalse(reopened.canNudge(try XCTUnwrap(reopened.dailyList().first)))
    }

    func testNudgeSupportsEachAsNeededOccurrenceButNotInactiveCompletedOrExcusedWork() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(weekday: .monday, title: "Bins", mode: .particular,
            memberIDs: [family.hanna.id], schedulingMode: .asNeeded)
        XCTAssertThrowsError(try family.store.nudge(choreID: chore))
        try family.store.activateAsNeededChore(choreID: chore)
        let first = try XCTUnwrap(family.store.dailyList().first?.occurrenceID)
        try family.store.setExcused(memberID: family.hanna.id, date: family.clock.now, excused: true)
        XCTAssertThrowsError(try family.store.nudge(choreID: chore, occurrenceID: first))
        try family.store.setExcused(memberID: family.hanna.id, date: family.clock.now, excused: false)
        try family.store.nudge(choreID: chore, occurrenceID: first)
        try family.store.setCompletion(choreID: chore, occurrenceID: first, memberID: family.hanna.id,
                                       date: family.clock.now, state: .done)
        XCTAssertThrowsError(try family.store.nudge(choreID: chore, occurrenceID: first))
        try family.store.activateAsNeededChore(choreID: chore)
        let second = try XCTUnwrap(family.store.dailyList().first { $0.asNeededStatus == .open }?.occurrenceID)
        XCTAssertNotEqual(first, second)
        try family.store.nudge(choreID: chore, occurrenceID: second)
        try family.store.selectProfile(family.hanna.id)
        XCTAssertEqual(family.store.activity.filter { $0.title == "A little reminder" }.count, 1)
    }

    func testNudgeAlertPermissionRelaunchAndNoCompletedBacklog() async throws {
        let family = try TestFamily()
        let chore = try family.chore()
        let alerts = PolishAlerts()
        let store = try HouseholdStore(repository: family.repository, clock: { family.clock.now },
                                       automaticSync: false, activityAlerts: alerts)
        try store.selectProfile(family.hanna.id)
        await store.setActivityAlertsEnabled(true)
        try family.store.nudge(choreID: chore)
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now },
                                          automaticSync: false, activityAlerts: alerts)
        await reopened.processActivityAlerts()
        XCTAssertEqual(alerts.deliveries, 1)
        let again = try HouseholdStore(repository: family.repository, clock: { family.clock.now },
                                       automaticSync: false, activityAlerts: alerts)
        await again.processActivityAlerts()
        XCTAssertEqual(alerts.deliveries, 1)
        try again.setCompletion(choreID: chore, memberID: family.hanna.id, date: family.clock.now, state: .done)
        await again.processActivityAlerts()
        XCTAssertEqual(alerts.deliveries, 1)
        XCTAssertFalse(again.activity.contains { $0.title == "A little reminder" })
        alerts.current = .denied
        try again.selectProfile(family.parent.id)
        let second = try again.saveChore(weekday: .monday, title: "Wash bowls", mode: .all, memberIDs: [])
        try again.nudge(choreID: second)
        try again.selectProfile(family.hanna.id)
        await again.processActivityAlerts()
        XCTAssertEqual(alerts.deliveries, 1)
        XCTAssertTrue(again.activity.contains { $0.title == "A little reminder" && $0.detail.contains("Wash bowls") })
    }

    func testSwapRequiresRecipientAcceptanceAndChangesBothDatesWithoutMovingRotation() throws {
        let family = try TestFamily()
        let (chore, requestID) = try setupSwap(family)
        XCTAssertEqual(family.store.dailyList().first?.turnOwnerID, family.hanna.id)
        XCTAssertThrowsError(try family.store.decideSwap(requestFactID: requestID, kind: .accepted))
        try family.store.selectProfile(family.parent.id)
        XCTAssertThrowsError(try family.store.decideSwap(requestFactID: requestID, kind: .accepted))
        try accept(family, requestID)
        XCTAssertEqual(family.store.dailyList().first?.turnOwnerID, family.alek.id)
        XCTAssertEqual(family.store.dailyList().first?.requiredMemberIDs, [family.alek.id])
        XCTAssertFalse(family.store.allowanceWeek(for: family.hanna.id).items.contains { $0.choreID == chore })
        try family.complete(chore, as: family.alek)
        XCTAssertEqual(family.store.swaps.first?.status, .accepted)
        family.move(to: "2026-09-14T16:00:00Z")
        XCTAssertEqual(family.store.dailyList().first?.turnOwnerID, family.hanna.id)
        XCTAssertEqual(ChoreRules.rotationOwner(choreID: chore, on: family.store.day, snapshot: family.store.snapshot)?.id, family.alek.id)
        try family.complete(chore, as: family.hanna)
        XCTAssertEqual(family.store.swaps.first?.status, .completed)
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id).items.first?.state, .done)
        XCTAssertFalse(family.store.allowanceWeek(for: family.alek.id).items.contains { $0.choreID == chore })
        family.move(to: "2026-09-21T16:00:00Z")
        XCTAssertEqual(family.store.dailyList().first?.turnOwnerID, family.hanna.id)
        XCTAssertTrue(family.store.allowanceHistory(for: family.alek.id).contains { $0.earned })
    }

    func testReservationCoversBothChildrenThroughRepaymentAndPreventsChains() throws {
        let family = try TestFamily()
        let other = try family.store.saveChore(weekday: .monday, title: "Dishes", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id], firstAlternatingMemberID: family.alek.id)
        let (chore, requestID) = try setupSwap(family)
        try family.store.selectProfile(family.alek.id)
        XCTAssertThrowsError(try family.store.requestSwap(choreID: other, recipientID: family.hanna.id))
        try accept(family, requestID)
        XCTAssertThrowsError(try family.store.requestSwap(choreID: chore, recipientID: family.hanna.id))
        try family.complete(chore, as: family.alek)
        family.move(to: "2026-09-14T16:00:00Z")
        try family.store.selectProfile(family.hanna.id)
        XCTAssertThrowsError(try family.store.requestSwap(choreID: chore, recipientID: family.alek.id))
        try family.complete(chore, as: family.hanna)
        XCTAssertThrowsError(try family.store.requestSwap(choreID: chore, recipientID: family.alek.id))
    }

    func testDeclineCancellationExpiryAndCompletedSourceReleaseRequests() throws {
        for action in ["decline", "cancel", "expire", "complete"] {
            let family = try TestFamily()
            let (chore, requestID) = try setupSwap(family)
            switch action {
            case "decline":
                try family.store.selectProfile(family.alek.id)
                try family.store.decideSwap(requestFactID: requestID, kind: .declined)
            case "cancel": try family.store.decideSwap(requestFactID: requestID, kind: .cancelled)
            case "expire": family.move(to: "2026-09-08T16:00:00Z")
            default: try family.complete(chore, as: family.hanna)
            }
            XCTAssertFalse(try XCTUnwrap(family.store.swaps.first).isActive)
            XCTAssertEqual(family.store.dailyList(on: TestClock().now).first?.turnOwnerID, family.hanna.id)
            try family.store.selectProfile(family.alek.id)
            XCTAssertThrowsError(try family.store.decideSwap(requestFactID: requestID, kind: .accepted))
        }
    }

    func testOverdueChoreCannotStartSwapAndRepaymentWindowReleasesWithoutErasingMissedHistory() throws {
        let family = try TestFamily()
        let (chore, requestID) = try setupSwap(family)
        try accept(family, requestID)
        family.move(to: "2026-09-15T16:00:00Z")
        XCTAssertEqual(family.store.swaps.first?.status, .accepted, "The existing next-day completion grace remains available")
        family.move(to: "2026-09-16T16:00:00Z")
        XCTAssertEqual(family.store.swaps.first?.status, .ended)
        XCTAssertEqual(family.store.allowanceHistory(for: family.alek.id).dropFirst().first?.items.first?.state, .missed)
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id).items.first?.state, .missed)
        XCTAssertThrowsError(try family.store.requestSwap(choreID: chore, recipientID: family.hanna.id))
    }

    func testScheduleMembershipDeletionAndNotNeededReleaseRepaymentWithoutRewritingCoveredTurn() throws {
        for action in ["schedule", "member", "delete", "notNeeded"] {
            let family = try TestFamily()
            let (chore, requestID) = try setupSwap(family)
            try accept(family, requestID)
            try family.complete(chore, as: family.alek)
            let original = family.clock.now
            try family.store.selectProfile(family.parent.id)
            switch action {
            case "schedule":
                try family.store.saveChore(choreID: chore, weekday: .tuesday, title: "Water plants", mode: .alternating,
                    memberIDs: [family.hanna.id, family.alek.id])
            case "member": try family.store.archiveMember(family.hanna.id)
            case "delete": try family.store.deleteChore(chore)
            default:
                family.move(to: "2026-09-14T16:00:00Z")
                try family.store.markOccurrenceNotNeeded(choreID: chore, date: family.clock.now, alternatingSkipBehavior: .advanceRotation)
            }
            XCTAssertEqual(family.store.swaps.first?.status, .released)
            let past = try XCTUnwrap(family.store.dailyList(on: original).first)
            XCTAssertEqual(past.turnOwnerID, family.alek.id)
            XCTAssertEqual(past.state(for: family.alek.id), .done)
        }
    }

    func testTitleEditsPreservePromisedRepaymentAndJournalRelaunch() throws {
        let family = try TestFamily()
        let (chore, requestID) = try setupSwap(family)
        try accept(family, requestID)
        try family.store.selectProfile(family.parent.id)
        try family.store.saveChore(choreID: chore, weekday: .monday, title: "Water the garden", mode: .alternating,
                                  memberIDs: [family.hanna.id, family.alek.id])
        family.move(to: "2026-09-14T16:00:00Z")
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.dailyList().first?.turnOwnerID, family.hanna.id)
        XCTAssertEqual(reopened.dailyList().first?.configuration.title, "Water the garden")
        XCTAssertEqual(reopened.swaps.first?.status, .accepted)
    }

    func testExchangedDoneWinsConcurrentNotNeededWithoutChangingBaseRotation() throws {
        let family = try TestFamily()
        let (chore, requestID) = try setupSwap(family)
        try accept(family, requestID)
        let row = try XCTUnwrap(family.store.dailyList().first)
        let disposition = fact(family, body: .occurrence(ChoreOccurrenceDisposition(
            choreID: chore, revisionID: row.configuration.id, day: row.day, state: .notNeeded,
            alternatingSkipBehavior: .keepTurn, recordedByMemberID: family.parent.id,
            assignedMemberID: family.alek.id)), author: family.parent.id)
        let done = fact(family, body: .completion(DatedCompletion(choreID: chore, revisionID: row.configuration.id,
            memberID: family.alek.id, day: row.day, state: .done, eligibleMemberIDs: [family.alek.id],
            mode: .alternating, recordedByMemberID: family.alek.id)), author: family.alek.id,
            sequence: disposition.sequence + 1)
        let facts = family.store.snapshot.orderedFacts + [disposition, done]
        for delivered in [facts, facts.reversed().map { $0 }] {
            let snapshot = HouseholdSnapshot(facts: delivered)
            let next = row.day.adding(days: 7, calendar: family.store.calendar)
            XCTAssertEqual(SwapRules.project(snapshot: snapshot, today: row.day).first?.status, .accepted)
            XCTAssertEqual(ChoreRules.dailyList(snapshot: snapshot, day: row.day, today: row.day).first?.state(for: family.alek.id), .done)
            XCTAssertEqual(ChoreRules.dailyList(snapshot: snapshot, day: row.day, today: row.day).first?.isNotNeeded, false)
            XCTAssertEqual(ChoreRules.rotationOwner(choreID: chore, on: next, snapshot: snapshot)?.id, family.alek.id)
            XCTAssertEqual(ChoreRules.dailyList(snapshot: snapshot, day: next, today: next).first?.turnOwnerID, family.hanna.id)
        }
    }

    func testConflictAndDuplicateDecisionsReplayInAnyDeliveryOrder() throws {
        let family = try TestFamily()
        let (chore, requestID) = try setupSwap(family)
        let source = try XCTUnwrap(family.store.swaps.first?.request)
        let seq = family.store.snapshot.orderedFacts.last!.sequence
        let decline = fact(family, body: .swapDecision(SwapDecision(requestFactID: requestID, memberID: family.alek.id,
            day: source.scope.day, kind: .declined)), author: family.alek.id, sequence: seq + 1,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let accept = fact(family, body: .swapDecision(SwapDecision(requestFactID: requestID, memberID: family.alek.id,
            day: source.scope.day, kind: .accepted)), author: family.alek.id, sequence: seq + 1,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let all = family.store.snapshot.orderedFacts + [decline, accept]
        for delivered in [all, all.reversed().map { $0 }, all.shuffled()] {
            let snapshot = HouseholdSnapshot(facts: delivered)
            XCTAssertEqual(SwapRules.project(snapshot: snapshot, today: source.scope.day).first?.status, .declined)
            XCTAssertEqual(ChoreRules.dailyList(snapshot: snapshot, day: source.scope.day, today: source.scope.day)
                .first { $0.choreID == chore }?.turnOwnerID, family.hanna.id)
        }
    }

    func testConcurrentRequestsAcrossChoresReserveBothParticipantsDeterministically() throws {
        let family = try TestFamily()
        let other = try family.store.saveChore(weekday: .monday, title: "Dishes", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id], firstAlternatingMemberID: family.alek.id)
        let (_, _) = try setupSwap(family)
        let row = try XCTUnwrap(family.store.dailyList().first { $0.choreID == other })
        let conflict = fact(family, body: .swapRequest(SwapRequest(scope: ChoreScope(row),
            requesterID: family.alek.id, recipientID: family.hanna.id,
            repaymentDay: family.store.day.adding(days: 7, calendar: family.store.calendar))), author: family.alek.id)
        let snapshot = HouseholdSnapshot(facts: ([conflict] + family.store.snapshot.orderedFacts).reversed())
        XCTAssertEqual(SwapRules.project(snapshot: snapshot, today: family.store.day).filter(\.isActive).count, 1)
    }

    func testDelayedOfflineAcceptanceCannotCrossCompletionOrMidnightButOnTimeFactSurvivesDelayedSync() throws {
        for completedFirst in [false, true] {
            let family = try TestFamily()
            let (chore, requestID) = try setupSwap(family)
            if completedFirst { try family.complete(chore, as: family.hanna) }
            let day = family.store.day
            let decision = fact(family, body: .swapDecision(SwapDecision(requestFactID: requestID,
                memberID: family.alek.id, day: day, kind: .accepted)), author: family.alek.id)
            let snapshot = HouseholdSnapshot(facts: family.store.snapshot.orderedFacts + [decision])
            let tomorrow = day.adding(days: 1, calendar: family.store.calendar)
            XCTAssertEqual(SwapRules.project(snapshot: snapshot, today: tomorrow).first?.wasAccepted, !completedFirst)
            XCTAssertEqual(ChoreRules.dailyList(snapshot: snapshot, day: day, today: tomorrow).first?.turnOwnerID,
                           completedFirst ? family.hanna.id : family.alek.id)
            let late = fact(family, body: .swapDecision(SwapDecision(requestFactID: requestID,
                memberID: family.alek.id, day: tomorrow, kind: .accepted)), author: family.alek.id)
            XCTAssertEqual(SwapRules.project(snapshot: HouseholdSnapshot(facts: family.store.snapshot.orderedFacts + [late]),
                today: tomorrow).first?.wasAccepted, false)
        }
    }

    func testAsNeededAndFarFutureRecipientCannotPromiseUnscheduledRepayment() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(weekday: .monday, title: "Bins", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id], schedulingMode: .asNeeded)
        try family.store.activateAsNeededChore(choreID: chore)
        try family.store.selectProfile(family.hanna.id)
        XCTAssertTrue(family.store.swapCandidates(for: try XCTUnwrap(family.store.dailyList().first)).isEmpty)
        try family.store.selectProfile(family.parent.id)
        var ids = [family.hanna.id, family.alek.id]
        for number in 1...4 { ids.append(try family.store.saveMember(name: "Child \(number)", role: .child, avatar: .star).id) }
        let weekly = try family.store.saveChore(weekday: .monday, title: "Garden", mode: .alternating,
            memberIDs: ids, firstAlternatingMemberID: family.hanna.id)
        try family.store.selectProfile(family.hanna.id)
        let row = try XCTUnwrap(family.store.dailyList().first { $0.choreID == weekly })
        XCTAssertTrue(family.store.swapCandidates(for: row).allSatisfy {
            $0.1 <= family.store.day.adding(days: 28, calendar: family.store.calendar)
        })
        XCTAssertLessThan(family.store.swapCandidates(for: row).count, ids.count - 1)
    }

    func testLegacyPendingOrAcceptedTransferCannotStartAChainedExchange() throws {
        let family = try TestFamily()
        let chore = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        try family.store.selectProfile(family.hanna.id)
        try family.store.requestPunt(choreID: chore, recipientID: family.alek.id)
        let requestID = try XCTUnwrap(family.store.activity.first { $0.punt?.status == .pending }?.id)
        XCTAssertTrue(family.store.swapCandidates(for: try XCTUnwrap(family.store.dailyList().first)).isEmpty)
        try family.store.selectProfile(family.alek.id)
        try family.store.decidePunt(requestFactID: requestID, kind: .accepted)
        XCTAssertTrue(family.store.swapCandidates(for: try XCTUnwrap(family.store.dailyList().first)).isEmpty)
        XCTAssertThrowsError(try family.store.requestSwap(choreID: chore, recipientID: family.hanna.id))
    }

    func testCorrectionAfterBothTurnsWereCompletedKeepsAssignmentAndUpdatesOutcome() throws {
        let family = try TestFamily()
        let (chore, requestID) = try setupSwap(family)
        try accept(family, requestID)
        try family.complete(chore, as: family.alek)
        family.move(to: "2026-09-14T16:00:00Z")
        try family.complete(chore, as: family.hanna)
        XCTAssertEqual(family.store.swaps.first?.status, .completed)
        try family.store.selectProfile(family.parent.id)
        try family.store.setCompletion(choreID: chore, memberID: family.hanna.id,
                                       date: family.clock.now, state: .unmarked)
        XCTAssertEqual(family.store.swaps.first?.status, .ended)
        XCTAssertEqual(family.store.dailyList().first?.turnOwnerID, family.hanna.id)
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id).dueToday.count, 1)
    }

    func testSwapAccountingIgnoresLosingRevisionCompletionsAndReversalsAtBothEndpoints() throws {
        for repayment in [false, true] {
            for losingState in [DailyStateKind.done, .unmarked] {
                let family = try TestFamily()
                let (chore, requestID) = try setupSwap(family)
                try accept(family, requestID)
                let request = try XCTUnwrap(family.store.swaps.first?.request)
                let old = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: request.scope.day))
                let endpointDay = repayment ? request.repaymentDay : request.scope.day
                let endpointMember = repayment ? family.hanna.id : family.alek.id
                let otherDay = repayment ? request.scope.day : request.repaymentDay
                let otherMember = repayment ? family.alek.id : family.hanna.id
                let revision = ChoreRevision(id: UUID(), householdID: old.householdID, choreID: chore,
                    weekday: old.weekday, effectiveDay: endpointDay, title: "Water the garden", notes: old.notes,
                    category: old.category, mode: old.mode, memberIDs: old.memberIDs, isArchived: false)
                let start = try XCTUnwrap(family.store.snapshot.orderedFacts.last?.sequence)
                let edit = fact(family, body: .chore(revision), author: family.parent.id, sequence: start + 1)
                let otherRevision = repayment ? old.id : revision.id
                var merged = [edit, fact(family, body: .completion(DatedCompletion(choreID: chore,
                    revisionID: otherRevision, memberID: otherMember, day: otherDay, state: .done,
                    eligibleMemberIDs: [otherMember], mode: .alternating, recordedByMemberID: otherMember)),
                    author: otherMember, sequence: start + 2)]
                if losingState == .unmarked {
                    merged.append(fact(family, body: .completion(DatedCompletion(choreID: chore,
                        revisionID: revision.id, memberID: endpointMember, day: endpointDay, state: .done,
                        eligibleMemberIDs: [endpointMember], mode: .alternating, recordedByMemberID: endpointMember)),
                        author: endpointMember, sequence: start + 3))
                }
                merged.append(fact(family, body: .completion(DatedCompletion(choreID: chore,
                    revisionID: old.id, memberID: endpointMember, day: endpointDay, state: losingState,
                    eligibleMemberIDs: [endpointMember], mode: .alternating, recordedByMemberID: endpointMember)),
                    author: endpointMember, sequence: start + 4))
                try family.repository.commit(facts: merged)
                family.move(to: "2026-09-14T16:00:00Z")
                let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
                let row = try XCTUnwrap(reopened.dailyList(on: endpointDay.date(in: reopened.calendar)).first)
                let incomplete: DailyStateKind = endpointDay < reopened.day ? .missed : .unmarked
                XCTAssertEqual(row.state(for: endpointMember), losingState == .done ? incomplete : .done)
                XCTAssertEqual(reopened.swaps.first?.status, losingState == .done ? .accepted : .completed)
                if losingState == .done {
                    XCTAssertTrue(reopened.swaps.first?.isActive == true)
                    try reopened.selectProfile(family.parent.id)
                    try reopened.setCompletion(choreID: chore, memberID: endpointMember,
                        date: endpointDay.date(in: reopened.calendar), state: .done)
                    XCTAssertEqual(reopened.swaps.first?.status, .completed)
                }
            }
        }
    }

    func testWinningRevisionDoneAndCorrectionControlRotationAtBothSwapEndpoints() throws {
        for repayment in [false, true] {
            for winningState in [DailyStateKind.done, .unmarked] {
                let family = try TestFamily()
                let (chore, requestID) = try setupSwap(family)
                try accept(family, requestID)
                let request = try XCTUnwrap(family.store.swaps.first?.request)
                let original = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: request.scope.day))
                let day = repayment ? request.repaymentDay : request.scope.day
                let memberID = repayment ? family.hanna.id : family.alek.id
                let revision = ChoreRevision(id: UUID(), householdID: original.householdID, choreID: chore,
                    weekday: original.weekday, effectiveDay: day, title: "Water the garden", notes: original.notes,
                    category: original.category, mode: .alternating, memberIDs: original.memberIDs, isArchived: false)
                let start = try XCTUnwrap(family.store.snapshot.orderedFacts.last?.sequence)
                let merged = family.store.snapshot.orderedFacts + [
                    fact(family, body: .chore(revision), author: family.parent.id, sequence: start + 1),
                    fact(family, body: .occurrence(ChoreOccurrenceDisposition(choreID: chore,
                        revisionID: revision.id, day: day, state: .notNeeded, alternatingSkipBehavior: .keepTurn,
                        recordedByMemberID: family.parent.id, assignedMemberID: memberID)),
                        author: family.parent.id, sequence: start + 2),
                    fact(family, body: .completion(DatedCompletion(choreID: chore, revisionID: revision.id,
                        memberID: memberID, day: day, state: .done, eligibleMemberIDs: [memberID],
                        mode: .alternating, recordedByMemberID: memberID)), author: memberID, sequence: start + 3),
                    fact(family, body: .completion(DatedCompletion(choreID: chore, revisionID: revision.id,
                        memberID: memberID, day: day, state: winningState, eligibleMemberIDs: [memberID],
                        mode: .alternating, recordedByMemberID: family.parent.id)),
                        author: family.parent.id, sequence: start + 4),
                    fact(family, body: .completion(DatedCompletion(choreID: chore, revisionID: original.id,
                        memberID: memberID, day: day, state: winningState == .done ? .unmarked : .done,
                        eligibleMemberIDs: [memberID], mode: .alternating, recordedByMemberID: memberID)),
                        author: memberID, sequence: start + 5)
                ]
                for delivered in [merged, Array(merged.reversed())] {
                    let snapshot = HouseholdSnapshot(facts: delivered)
                    let next = day.adding(days: 7, calendar: family.store.calendar)
                    let row = try XCTUnwrap(ChoreRules.dailyList(snapshot: snapshot, day: day, today: day).first)
                    XCTAssertEqual(row.state(for: memberID), winningState)
                    XCTAssertEqual(row.isNotNeeded, winningState != .done)
                    let expectedOwner = repayment
                        ? (winningState == .done ? family.hanna.id : family.alek.id)
                        : (winningState == .done ? family.alek.id : family.hanna.id)
                    XCTAssertEqual(ChoreRules.rotationOwner(choreID: chore, on: next, snapshot: snapshot)?.id, expectedOwner)
                    XCTAssertEqual(SwapRules.project(snapshot: snapshot, today: day).first?.status,
                                   winningState == .done ? .accepted : .released)
                }
            }
        }
    }

    func testDeclinedSwapCapabilitySurvivesRestorationAndTransportReplay() async throws {
        for decision in [SwapDecisionKind.declined, .cancelled] {
            let server = TestCloudServer()
            let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
            let (chore, firstID) = try setupSwap(family)
            try family.store.selectProfile(decision == .declined ? family.alek.id : family.hanna.id)
            try family.store.decideSwap(requestFactID: firstID, kind: decision)
            try family.store.selectProfile(family.parent.id)
            try family.store.markOccurrenceNotNeeded(choreID: chore, date: family.clock.now,
                                                     alternatingSkipBehavior: .keepTurn)
            try family.store.restoreScheduledRequirement(choreID: chore, date: family.clock.now)
            XCTAssertFalse(family.store.snapshot.orderedFacts.contains {
                if case .journalCapability = $0.body { return true }; return false
            })
            let restored = try XCTUnwrap(family.store.dailyList().first)
            XCTAssertFalse(restored.isNotNeeded)
            let next = family.store.day.adding(days: 7, calendar: family.store.calendar)
            XCTAssertEqual(ChoreRules.rotationOwner(choreID: chore, on: next, snapshot: family.store.snapshot)?.id,
                           family.alek.id)
            let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
            let childRepository = try HouseholdRepository(inMemory: true)
            let child = try HouseholdStore(repository: childRepository,
                transport: TestTransport(server: server, account: "child"), clock: { family.clock.now }, automaticSync: false)
            try await child.redeemInvitation(invitation.qrPayload)
            XCTAssertTrue(child.swapCandidates(for: try XCTUnwrap(child.dailyList().first)).contains { $0.0.id == family.alek.id })
            try child.requestSwap(choreID: chore, recipientID: family.alek.id)
            let secondID = try XCTUnwrap(child.swaps.last?.id)
            XCTAssertNotEqual(secondID, firstID)
            XCTAssertEqual(child.swaps.last?.status, .pending)
            try await child.synchronize()
            try await family.store.synchronize()
            try accept(family, secondID)
            XCTAssertEqual(family.store.swaps.last?.status, .accepted)
            try await family.store.synchronize()
            try await child.synchronize()
            XCTAssertEqual(child.swaps.last?.status, .accepted)
            XCTAssertEqual(child.dailyList().first?.turnOwnerID, family.alek.id)
            let reopened = try HouseholdStore(repository: childRepository,
                clock: { family.clock.now }, automaticSync: false)
            XCTAssertEqual(reopened.swaps.last?.status, .accepted)
            XCTAssertEqual(reopened.snapshot.orderedFacts, family.store.snapshot.orderedFacts)
        }
    }

    func testReleasedSwapEndpointsCannotBeOfferedOrSavedForAnotherExchange() throws {
        let family = try TestFamily()
        let zoe = try family.store.saveMember(name: "Zoe", role: .child, avatar: .star)
        let chore = try family.chore(.alternating, ids: [family.hanna.id, zoe.id, family.alek.id])
        try family.store.selectProfile(family.hanna.id)
        try family.store.requestSwap(choreID: chore, recipientID: family.alek.id)
        let requestID = try XCTUnwrap(family.store.swaps.first?.id)
        XCTAssertEqual(family.store.swaps.first?.request.repaymentDay,
                       family.store.day.adding(days: 14, calendar: family.store.calendar))
        try accept(family, requestID)
        try family.store.selectProfile(family.parent.id)
        try family.store.markOccurrenceNotNeeded(choreID: chore, date: family.clock.now,
                                                 alternatingSkipBehavior: .advanceRotation)
        XCTAssertEqual(family.store.swaps.first?.status, .released)
        family.move(to: "2026-09-14T16:00:00Z")
        try family.store.selectProfile(zoe.id)
        let row = try XCTUnwrap(family.store.dailyList().first)
        XCTAssertEqual(row.turnOwnerID, zoe.id)
        XCTAssertFalse(family.store.swapCandidates(for: row).contains { $0.0.id == family.alek.id })
        let before = family.store.snapshot.orderedFacts
        XCTAssertThrowsError(try family.store.requestSwap(choreID: chore, recipientID: family.alek.id))
        XCTAssertEqual(family.store.snapshot.orderedFacts, before)
        XCTAssertTrue(family.store.swapCandidates(for: row).contains { $0.0.id == family.hanna.id })
        try family.store.requestSwap(choreID: chore, recipientID: family.hanna.id)
        XCTAssertEqual(family.store.swaps.last?.status, .pending)
        XCTAssertEqual(family.store.swaps.last?.request.requesterID, zoe.id)
    }

    func testOnboardingInvitationImmediatelyRedeemsExactProfileAndAllowsFurtherEditing() async throws {
        let server = TestCloudServer()
        let clock = TestClock()
        let repository = try HouseholdRepository(inMemory: true)
        let ownerTransport = TestTransport(server: server, account: "owner")
        let owner = try HouseholdStore(repository: repository, transport: ownerTransport,
            clock: { clock.now }, automaticSync: false)
        try owner.createFamily(name: "Test Family", parentName: "Test Parent",
                               timeZone: TimeZone(identifier: "America/New_York")!)
        let parent = try XCTUnwrap(owner.selectedMember)
        let child = try owner.saveMember(name: "Hanna", role: .child, avatar: .flower)
        XCTAssertEqual(owner.household?.isSetupComplete, false)
        XCTAssertTrue(owner.snapshot.invitations.isEmpty)
        XCTAssertNil(owner.session.location)
        let issued = try await owner.createChildInvitation(memberID: child.id)
        let childRepository = try HouseholdRepository(inMemory: true)
        let childTransport = TestTransport(server: server, account: "child")
        let joining = try HouseholdStore(repository: childRepository, transport: childTransport,
            clock: { clock.now }, automaticSync: false)
        try await joining.redeemInvitation(issued.qrPayload)
        XCTAssertEqual(owner.household?.isSetupComplete, true)
        XCTAssertEqual(joining.household?.id, owner.household?.id)
        XCTAssertEqual(joining.selectedMember?.id, child.id)
        XCTAssertEqual(joining.snapshot.invitationClaim(issued.invitation.id)?.memberID, child.id)
        XCTAssertThrowsError(try joining.selectProfile(parent.id))
        let sibling = try owner.saveMember(name: "Alek", role: .child, avatar: .rocket)
        let chore = try owner.saveChore(weekday: .monday, title: "Water plants", mode: .all, memberIDs: [])
        try owner.renameFamily("Our Team")
        try await owner.synchronize()
        try await joining.synchronize()
        XCTAssertThrowsError(try joining.selectProfile(sibling.id))
        XCTAssertTrue(joining.dailyList().contains { $0.choreID == chore })
        XCTAssertEqual(joining.household?.name, "Our Team")
        let reopened = try HouseholdStore(repository: childRepository, transport: childTransport,
            clock: { clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.selectedMember?.id, child.id)
        XCTAssertEqual(reopened.household?.isSetupComplete, true)
        let retry = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
            transport: TestTransport(server: server, account: "other-child"), clock: { clock.now }, automaticSync: false)
        do {
            try await retry.redeemInvitation(issued.qrPayload)
            XCTFail("A claimed onboarding invitation must not be reusable")
        } catch {}
        XCTAssertNil(retry.household)
    }

    func testOnboardingParentInvitationFinalizesSetupAndRedeemsRawAppleURL() async throws {
        let server = TestCloudServer()
        let clock = TestClock()
        let owner = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
            transport: TestTransport(server: server, account: "owner"), clock: { clock.now }, automaticSync: false)
        try owner.createFamily(name: "Test Family", parentName: "Test Parent",
                               timeZone: TimeZone(identifier: "America/New_York")!)
        _ = try owner.saveMember(name: "Hanna", role: .child, avatar: .flower)
        let issued = try await owner.createParentInvitation(name: "Another Parent", avatar: .sun)
        let transport = TestTransport(server: server, account: "other-parent")
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
            transport: transport, clock: { clock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: issued.shareURL)
        try await joining.acceptSystemInvitation(location: location) {
            try await transport.accept(url: issued.shareURL, expected: location)
        }
        XCTAssertEqual(owner.household?.isSetupComplete, true)
        XCTAssertEqual(joining.selectedMember?.id, issued.invitation.memberID)
        XCTAssertEqual(joining.selectedMember?.role, .parent)
        XCTAssertEqual(joining.household?.id, owner.household?.id)
        XCTAssertEqual(joining.snapshot.invitationClaim(issued.invitation.id)?.memberID, issued.invitation.memberID)
        XCTAssertFalse(joining.session.location?.isOwner == true)
        try joining.renameFamily("Our Team")
        try await joining.synchronize()
        try await owner.synchronize()
        XCTAssertEqual(owner.household?.name, "Our Team")
    }

    func testOnboardingInvitationPreservesMandatoryChildAndRoleValidation() async throws {
        let server = TestCloudServer()
        let clock = TestClock()
        let owner = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
            transport: TestTransport(server: server, account: "owner"), clock: { clock.now }, automaticSync: false)
        try owner.createFamily(name: "Test Family", parentName: "Test Parent",
                               timeZone: TimeZone(identifier: "America/New_York")!)
        do {
            _ = try await owner.createParentInvitation(name: "Another Parent", avatar: .sun)
            XCTFail("An invitation must not bypass the required child profile")
        } catch { XCTAssertEqual(error as? HouseholdError, .missingChildren) }
        XCTAssertEqual(owner.household?.isSetupComplete, false)
        XCTAssertTrue(owner.snapshot.invitations.isEmpty)
        XCTAssertNil(owner.session.location)
        let child = try owner.saveMember(name: "Hanna", role: .child, avatar: .flower)
        try owner.selectProfile(child.id)
        do {
            _ = try await owner.createChildInvitation(memberID: child.id)
            XCTFail("A child cannot finalize setup or issue invitations")
        } catch { XCTAssertEqual(error as? HouseholdError, .permission) }
        XCTAssertEqual(owner.household?.isSetupComplete, false)
    }

    func testSettledSwapCorrectionsPreserveBothAssignmentsCreditAndRotationAcrossDeliveryOrders() throws {
        for disposedRepayment in [false, true] {
            for correctedRepayment in [false, true] {
                for behavior in [AlternatingSkipBehavior.keepTurn, .advanceRotation] {
                    let family = try TestFamily()
                    let (chore, requestID) = try setupSwap(family)
                    try accept(family, requestID)
                    let request = try XCTUnwrap(family.store.swaps.first?.request)
                    let day = disposedRepayment ? request.repaymentDay : request.scope.day
                    let memberID = disposedRepayment ? family.hanna.id : family.alek.id
                    let sequence = try XCTUnwrap(family.store.snapshot.orderedFacts.last?.sequence)
                    let disposition = fact(family, body: .occurrence(ChoreOccurrenceDisposition(choreID: chore,
                        revisionID: request.scope.revisionID, day: day, state: .notNeeded,
                        alternatingSkipBehavior: behavior, recordedByMemberID: family.parent.id,
                        assignedMemberID: memberID)), author: family.parent.id, sequence: sequence + 1)
                    let sourceDone = fact(family, body: .completion(DatedCompletion(choreID: chore,
                        revisionID: request.scope.revisionID, memberID: family.alek.id, day: request.scope.day,
                        state: .done, eligibleMemberIDs: [family.alek.id], mode: .alternating,
                        recordedByMemberID: family.alek.id)), author: family.alek.id, sequence: sequence + 2)
                    let repaymentDone = fact(family, body: .completion(DatedCompletion(choreID: chore,
                        revisionID: request.scope.revisionID, memberID: family.hanna.id, day: request.repaymentDay,
                        state: .done, eligibleMemberIDs: [family.hanna.id], mode: .alternating,
                        recordedByMemberID: family.hanna.id)), author: family.hanna.id, sequence: sequence + 3)
                    try family.repository.commit(facts: [disposition, sourceDone, repaymentDone])
                    family.move(to: "2026-09-21T16:00:00Z")
                    let store = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
                    XCTAssertEqual(store.swaps.first?.status, .completed)
                    try store.selectProfile(family.parent.id)
                    let correctedDay = correctedRepayment ? request.repaymentDay : request.scope.day
                    let correctedMember = correctedRepayment ? family.hanna.id : family.alek.id
                    try store.setCompletion(choreID: chore, memberID: correctedMember,
                        date: correctedDay.date(in: store.calendar), state: .missed)
                    let all = store.snapshot.orderedFacts
                    for delivered in [all, Array(all.reversed()), Array(all.dropFirst()) + [all[0]]] {
                        let snapshot = HouseholdSnapshot(facts: delivered)
                        let swap = try XCTUnwrap(SwapRules.project(snapshot: snapshot, today: store.day).first)
                        XCTAssertEqual(swap.status, .ended)
                        XCTAssertFalse(swap.isActive)
                        XCTAssertFalse(swap.repaymentCancelled)
                        for repayment in [false, true] {
                            let endpointDay = repayment ? request.repaymentDay : request.scope.day
                            let ownerID = repayment ? family.hanna.id : family.alek.id
                            let state: DailyStateKind = repayment == correctedRepayment ? .missed : .done
                            let row = try XCTUnwrap(ChoreRules.dailyList(snapshot: snapshot, day: endpointDay, today: store.day).first)
                            XCTAssertEqual(row.turnOwnerID, ownerID)
                            XCTAssertEqual(row.state(for: ownerID), state)
                            XCTAssertFalse(row.isNotNeeded)
                            let week = AllowanceService.week(childID: ownerID, containing: endpointDay.date(in: store.calendar),
                                snapshot: snapshot, today: family.clock.now)
                            XCTAssertEqual(week.items.first { $0.choreID == chore }?.state, state)
                            XCTAssertEqual(week.earned, state == .done)
                        }
                        XCTAssertEqual(ChoreRules.rotationOwner(choreID: chore, on: store.day, snapshot: snapshot)?.id, family.hanna.id)
                        XCTAssertEqual(ChoreRules.rotationOwner(choreID: chore,
                            on: store.day.adding(days: 7, calendar: store.calendar), snapshot: snapshot)?.id, family.alek.id)
                    }
                    let retainedWeek = try XCTUnwrap(store.allowanceHistory(for: correctedMember).first {
                        $0.items.contains { $0.choreID == chore && $0.day == correctedDay }
                    })
                    XCTAssertFalse(retainedWeek.earned)
                    try store.markOccurrenceNotNeeded(choreID: chore, date: correctedDay.date(in: store.calendar),
                                                     alternatingSkipBehavior: behavior)
                    XCTAssertTrue(store.dailyList(on: correctedDay.date(in: store.calendar)).first?.isNotNeeded == true)
                    XCTAssertEqual(store.swaps.first?.status, .ended)
                    XCTAssertFalse(store.swaps.first?.repaymentCancelled == true)
                }
            }
        }
    }

    func testOfflineOldRevisionNudgeRemainsActionableAndDeduplicatesAcrossTransport() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let chore = try family.store.saveChore(weekday: .monday, title: "Water plants", mode: .particular,
            memberIDs: [family.hanna.id])
        family.move(to: "2026-09-13T16:00:00Z")
        try await family.store.connect()
        let parentInvitation = try await family.store.createParentInvitation(name: "Other Parent", avatar: .sun)
        let parentTransport = TestTransport(server: server, account: "other-parent")
        let parent = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: parentTransport,
            clock: { family.clock.now }, automaticSync: false)
        try await parent.redeemInvitation(parentInvitation.qrPayload)
        let childInvitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let childRepository = try HouseholdRepository(inMemory: true)
        let childTransport = TestTransport(server: server, account: "child")
        let alerts = PolishAlerts()
        let child = try HouseholdStore(repository: childRepository, transport: childTransport,
            clock: { family.clock.now }, automaticSync: false, activityAlerts: alerts)
        try await child.redeemInvitation(childInvitation.qrPayload)
        await child.setActivityAlertsEnabled(true)
        let baselineDeliveries = alerts.deliveries
        try family.store.saveChore(choreID: chore, weekday: .monday, title: "Water the garden", mode: .particular,
            memberIDs: [family.hanna.id])
        try await family.store.synchronize()
        family.move(to: "2026-09-14T16:00:00Z")
        parent.refreshDate()
        child.refreshDate()
        let staleRow = try XCTUnwrap(parent.dailyList().first { $0.choreID == chore })
        parentTransport.fetchError = CKError(.networkUnavailable)
        try parent.nudge(choreID: chore, occurrenceID: staleRow.occurrenceID)
        do { try await parent.synchronize(); XCTFail("The reminder must remain pending while offline") } catch {}
        XCTAssertGreaterThan(parent.pendingCount, 0)
        parentTransport.fetchError = nil
        try await parent.synchronize()
        try await family.store.synchronize()
        try await child.synchronize()
        let reminders = child.activity.filter { $0.title == "A little reminder" }
        XCTAssertEqual(reminders.count, 1)
        let reminderID = reminders.first?.id
        let currentRow = try XCTUnwrap(family.store.dailyList().first { $0.choreID == chore && $0.occurrenceID == staleRow.occurrenceID })
        XCTAssertNotEqual(currentRow.configuration.id, staleRow.configuration.id)
        XCTAssertTrue(reminders.first?.detail.contains("Water the garden") == true)
        XCTAssertFalse(family.store.canNudge(currentRow))
        XCTAssertThrowsError(try family.store.nudge(choreID: chore, occurrenceID: staleRow.occurrenceID))
        await child.processActivityAlerts()
        XCTAssertEqual(alerts.deliveries, baselineDeliveries + 1)
        let reopened = try HouseholdStore(repository: childRepository, transport: childTransport,
            clock: { family.clock.now }, automaticSync: false, activityAlerts: alerts)
        await reopened.processActivityAlerts()
        XCTAssertEqual(alerts.deliveries, baselineDeliveries + 1)
        XCTAssertEqual(reopened.activity.first { $0.title == "A little reminder" }?.id, reminderID)
        XCTAssertEqual(alerts.badgeCount, reopened.unreadActivityCount)
        family.move(to: "2026-09-14T16:01:00Z")
        reopened.refreshDate()
        try family.store.nudge(choreID: chore, occurrenceID: staleRow.occurrenceID)
        try await family.store.synchronize()
        try await reopened.synchronize()
        await reopened.processActivityAlerts()
        XCTAssertEqual(alerts.deliveries, baselineDeliveries + 2)
        XCTAssertEqual(reopened.activity.filter { $0.title == "A little reminder" }.count, 2)
        XCTAssertEqual(alerts.badgeCount, reopened.unreadActivityCount)
        try await reopened.synchronize()
        await reopened.processActivityAlerts()
        XCTAssertEqual(alerts.deliveries, baselineDeliveries + 2)
        let base = reopened.snapshot.orderedFacts
        let row = try XCTUnwrap(reopened.dailyList().first { $0.choreID == chore })
        var removed = family.hanna
        removed.archivedFrom = reopened.day
        let replacement = ChoreRevision(id: UUID(), householdID: row.configuration.householdID, choreID: chore,
            weekday: .monday, effectiveDay: reopened.day, title: row.configuration.title, notes: "",
            category: row.configuration.category, mode: .particular, memberIDs: [family.alek.id], isArchived: false)
        let exclusions: [HouseholdFactBody] = [
            .excuse(Excuse(memberID: family.hanna.id, day: reopened.day, isExcused: true)),
            .member(removed), .chore(replacement),
            .choreDeletion(ChoreDeletion(choreID: chore, day: reopened.day, recordedByMemberID: family.parent.id)),
            .occurrence(ChoreOccurrenceDisposition(choreID: chore, revisionID: row.configuration.id,
                day: reopened.day, state: .notNeeded, alternatingSkipBehavior: nil, recordedByMemberID: family.parent.id))
        ]
        for exclusion in exclusions {
            let excluded = HouseholdSnapshot(facts: base + [fact(family, body: exclusion,
                author: family.parent.id, sequence: (base.last?.sequence ?? 0) + 1)])
            XCTAssertFalse(FamilyActivityRules.activity(snapshot: excluded, today: reopened.day).contains {
                $0.title == "A little reminder" && $0.recipientIDs.contains(family.hanna.id)
            })
        }
        XCTAssertFalse(FamilyActivityRules.activity(snapshot: reopened.snapshot,
            today: reopened.day.adding(days: 1, calendar: reopened.calendar)).contains { $0.title == "A little reminder" })
        try reopened.setCompletion(choreID: chore, occurrenceID: staleRow.occurrenceID,
            memberID: family.hanna.id, date: family.clock.now, state: .done)
        XCTAssertFalse(reopened.activity.contains { $0.title == "A little reminder" })
    }

    func testExtrasSyncOfflineAcrossExactInvitedProfilesAndRelaunch() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let chore = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "hanna-account")
        let repository = try HouseholdRepository(inMemory: true)
        let hanna = try HouseholdStore(repository: repository, transport: transport,
            clock: { family.clock.now }, automaticSync: false)
        try await hanna.redeemInvitation(invitation.qrPayload)
        let second = try await family.store.createChildInvitation(memberID: family.alek.id)
        let alek = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
            transport: TestTransport(server: server, account: "alek-account"), clock: { family.clock.now }, automaticSync: false)
        try await alek.redeemInvitation(second.qrPayload)
        try family.store.nudge(choreID: chore)
        try await family.store.synchronize()
        try await hanna.synchronize()
        XCTAssertTrue(hanna.activity.contains { $0.title == "A little reminder" })
        transport.fetchError = CKError(.networkUnavailable)
        try hanna.requestSwap(choreID: chore, recipientID: family.alek.id)
        let requestID = try XCTUnwrap(hanna.swaps.first?.id)
        do { try await hanna.synchronize(); XCTFail("Expected offline transport") } catch {}
        XCTAssertGreaterThan(hanna.pendingCount, 0)
        transport.fetchError = nil
        try await hanna.synchronize()
        try await alek.synchronize()
        try alek.decideSwap(requestFactID: requestID, kind: .accepted)
        try alek.setCompletion(choreID: chore, memberID: family.alek.id, date: family.clock.now, state: .done)
        try await alek.synchronize()
        try await family.store.synchronize()
        try family.store.awardBonus(memberID: family.alek.id, text: "3.50", currencyCode: "USD", note: "Teamwork", awardID: UUID())
        try await family.store.synchronize()
        try await hanna.synchronize()
        try await alek.synchronize()
        XCTAssertEqual(hanna.snapshot, alek.snapshot)
        XCTAssertEqual(family.store.snapshot, alek.snapshot)
        XCTAssertEqual(alek.bonusHistory(for: family.alek.id).first?.award.amount.minorUnits, 350)
        XCTAssertEqual(alek.allowanceWeek(for: family.alek.id).amount?.minorUnits, 350)
        XCTAssertEqual(hanna.allowanceWeek(for: family.alek.id).amount, alek.allowanceWeek(for: family.alek.id).amount)
        XCTAssertFalse(hanna.activity.contains { $0.title == "A little reminder" })
        let fish = try family.store.saveChore(weekday: .monday, title: "Feed fish", mode: .particular,
            memberIDs: [family.hanna.id], schedulingMode: .asNeeded)
        try family.store.activateAsNeededChore(choreID: fish)
        let occurrence = try XCTUnwrap(family.store.dailyList().first { $0.choreID == fish }?.occurrenceID)
        try family.store.nudge(choreID: fish, occurrenceID: occurrence)
        try await family.store.synchronize()
        try await hanna.synchronize()
        XCTAssertTrue(hanna.activity.contains { $0.title == "A little reminder" && $0.detail.contains("Feed fish") })
        XCTAssertThrowsError(try hanna.selectProfile(family.alek.id))
        let reopened = try HouseholdStore(repository: repository, transport: transport,
            clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.swaps.first?.status, .accepted)
        family.move(to: "2026-09-14T16:00:00Z")
        reopened.refreshDate()
        XCTAssertNil(reopened.allowanceWeek(for: family.alek.id).amount)
        XCTAssertEqual(reopened.dailyList().first { $0.choreID == chore }?.turnOwnerID, family.hanna.id)
        try reopened.setCompletion(choreID: chore, memberID: family.hanna.id, date: family.clock.now, state: .done)
        try await reopened.synchronize()
        try await alek.synchronize()
        XCTAssertEqual(alek.swaps.first?.status, .completed)
        XCTAssertEqual(reopened.snapshot, alek.snapshot)
        let data = try JSONEncoder().encode(reopened.snapshot.orderedFacts)
        XCTAssertEqual(try JSONDecoder().decode([HouseholdFact].self, from: data), reopened.snapshot.orderedFacts)
    }
}

@MainActor
private final class PolishAlerts: ActivityAlerting {
    var current: ActivityAlertPermission = .allowed
    var deliveries = 0
    var badgeCount = 0
    func permission() async -> ActivityAlertPermission { current }
    func badgePermission() async -> ActivityAlertPermission { current }
    func requestPermission() async throws -> ActivityAlertPermission { current }
    func deliver(identifier: String) async throws { deliveries += 1 }
    func setBadgeCount(_ count: Int) async throws { badgeCount = count }
    func clear() async { badgeCount = 0 }
}

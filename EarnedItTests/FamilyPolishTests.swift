import CloudKit
import XCTest
@testable import EarnedIt

@MainActor
final class FamilyPolishTests: XCTestCase {
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
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id), before)
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
    func permission() async -> ActivityAlertPermission { current }
    func requestPermission() async throws -> ActivityAlertPermission { current }
    func deliver(identifier: String) async throws { deliveries += 1 }
    func clear() async {}
}

import XCTest
import CloudKit
@testable import EarnedIt

@MainActor
final class ProductionCleanupTests: XCTestCase {
    func testAsNeededAlternatingNextOwnerCompletionSkipAndEligibility() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Empty Dishwasher", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id, nora.id], schedulingMode: .asNeeded
        )
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        let order = revision.memberIDs

        XCTAssertTrue(family.store.dailyList().allSatisfy { $0.id != chore })
        XCTAssertEqual(family.store.nextAlternatingOwner(choreID: chore)?.id, order[0])
        try family.store.skipNextAlternatingChild(choreID: chore)
        XCTAssertEqual(family.store.nextAlternatingOwner(choreID: chore)?.id, order[1])
        try family.store.activateAsNeededChore(choreID: chore)

        let active = try XCTUnwrap(family.store.dailyList().first { $0.id == chore })
        XCTAssertEqual(active.turnOwnerID, order[1])
        XCTAssertEqual(active.eligibleMembers.map(\.id), [order[1]])
        XCTAssertEqual(active.requiredMembers.map(\.id), [order[1]])
        XCTAssertEqual(active.turnLabel(for: family.parent), "\(active.turnOwner!.displayName)’s turn")
        XCTAssertEqual(active.turnLabel(for: active.turnOwner!), "Your turn")
        for child in [family.hanna, family.alek, nora] {
            let visible = ChoreRules.visibleList([active], to: child)
            XCTAssertEqual(visible.isEmpty, child.id != order[1])
        }

        try family.store.setCompletion(choreID: chore, memberID: order[1],
                                       date: family.clock.now, state: .done)
        family.move(to: "2026-09-08T16:00:00Z")
        XCTAssertEqual(family.store.nextAlternatingOwner(choreID: chore)?.id, order[2])

        try family.store.skipNextAlternatingChild(choreID: chore)
        XCTAssertEqual(family.store.nextAlternatingOwner(choreID: chore)?.id, order[0])
        try family.store.skipNextAlternatingChild(choreID: chore)
        XCTAssertEqual(family.store.nextAlternatingOwner(choreID: chore)?.id, order[1])
    }

    func testScheduledToAsNeededEditPreservesNextAlternatingChild() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Empty Dishwasher", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id, nora.id]
        )
        let original = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        let order = original.memberIDs
        XCTAssertEqual(family.store.dailyList().first { $0.id == chore }?.turnOwnerID, order[0])

        try family.store.saveChore(
            choreID: chore, weekday: .monday, title: original.title,
            mode: .alternating, memberIDs: order, schedulingMode: .asNeeded
        )
        XCTAssertEqual(family.store.dailyList().first { $0.id == chore }?.turnOwnerID, order[0])

        family.move(to: "2026-09-08T16:00:00Z")
        XCTAssertEqual(family.store.nextAlternatingOwner(choreID: chore)?.id, order[1])
        try family.store.activateAsNeededChore(choreID: chore)
        XCTAssertEqual(family.store.dailyList().first { $0.id == chore }?.turnOwnerID, order[1])
    }

    func testAsNeededToScheduledEditPreservesNextAlternatingChild() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Empty Dishwasher", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id, nora.id], schedulingMode: .asNeeded
        )
        let original = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        let order = original.memberIDs
        try family.store.activateAsNeededChore(choreID: chore)
        try family.store.setCompletion(choreID: chore, memberID: order[0],
                                       date: family.clock.now, state: .done)

        try family.store.saveChore(
            choreID: chore, weekday: .tuesday, title: original.title,
            mode: .alternating, memberIDs: order, schedulingMode: .scheduled
        )
        XCTAssertEqual(family.store.dailyList().first { $0.id == chore }?.turnOwnerID, order[0])

        family.move(to: "2026-09-08T16:00:00Z")
        XCTAssertEqual(family.store.dailyList().first { $0.id == chore }?.turnOwnerID, order[1])
    }

    func testIncompleteActivationDoesNotConsumeTurnAfterMergedOfflineActivation() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Empty Dishwasher", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id, nora.id], schedulingMode: .asNeeded
        )
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        try family.store.activateAsNeededChore(choreID: chore)
        let firstOwner = try XCTUnwrap(family.store.dailyList().first { $0.id == chore }?.turnOwnerID)
        let facts = try family.repository.facts(householdID: revision.householdID)
        let secondDay = CivilDay(rawValue: "2026-09-08")!
        let mergedActivation = HouseholdFact(
            id: UUID(), householdID: revision.householdID,
            sequence: try XCTUnwrap(facts.map(\.sequence).max()) + 1,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .occurrence(ChoreOccurrenceDisposition(
                choreID: chore, revisionID: revision.id, day: secondDay,
                state: .available, alternatingSkipBehavior: nil,
                recordedByMemberID: family.parent.id, assignedMemberID: firstOwner
            ))
        )
        try family.repository.commit(facts: [mergedActivation], uploaded: true)
        let merged = try HouseholdStore(repository: family.repository,
                                        clock: { family.clock.now }, automaticSync: false)
        let secondDate = ISO8601DateFormatter().date(from: "2026-09-08T16:00:00Z")!
        let secondOwner = try XCTUnwrap(merged.dailyList(on: secondDate).first { $0.id == chore }?.turnOwnerID)

        XCTAssertEqual(secondOwner, firstOwner)
        XCTAssertEqual(firstOwner, revision.memberIDs[0])
        let thirdDay = CivilDay(rawValue: "2026-09-09")!
        XCTAssertEqual(ChoreRules.nextAlternatingOwner(choreID: chore, on: thirdDay,
                                                       snapshot: merged.snapshot)?.id, firstOwner)
    }

    func testSkipConvergesAndExcludesArchivedChildInSavedOrder() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Empty Dishwasher", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id, nora.id], schedulingMode: .asNeeded
        )
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        try family.store.skipNextAlternatingChild(choreID: chore)
        try family.store.archiveMember(revision.memberIDs[1])
        family.move(to: "2026-09-08T16:00:00Z")

        let expected = revision.memberIDs[2]
        XCTAssertEqual(family.store.nextAlternatingOwner(choreID: chore)?.id, expected)
        let facts = try family.repository.facts(householdID: revision.householdID)
        let first = HouseholdSnapshot(facts: facts)
        let second = HouseholdSnapshot(facts: facts.reversed())
        XCTAssertEqual(ChoreRules.nextAlternatingOwner(choreID: chore, on: family.store.day, snapshot: first)?.id,
                       expected)
        XCTAssertEqual(ChoreRules.nextAlternatingOwner(choreID: chore, on: family.store.day, snapshot: second)?.id,
                       expected)
    }

    func testConcurrentDuplicateSkipConsumesOnlyExpectedChildOnce() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Empty Dishwasher", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id, nora.id], schedulingMode: .asNeeded
        )
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        let base = try family.repository.facts(householdID: revision.householdID)
        let sequence = try XCTUnwrap(base.map(\.sequence).max()) + 1
        let duplicateFacts = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        ].map { id in
            HouseholdFact(
                id: id, householdID: revision.householdID, sequence: sequence,
                authorDeviceID: UUID(), authorMemberID: family.parent.id,
                body: .alternatingTurnAdvance(AlternatingTurnAdvance(
                    choreID: chore, revisionID: revision.id,
                    expectedMemberID: revision.memberIDs[0], day: family.store.day,
                    recordedByMemberID: family.parent.id
                ))
            )
        }
        let snapshot = HouseholdSnapshot(facts: base + duplicateFacts.reversed())

        XCTAssertEqual(ChoreRules.nextAlternatingOwner(choreID: chore, on: family.store.day,
                                                       snapshot: snapshot)?.id,
                       revision.memberIDs[1])
    }

    func testLateOfflineSkipCannotChangeActiveAssignmentOrCompletion() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Empty Dishwasher", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id, nora.id], schedulingMode: .asNeeded
        )
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        let firstOwner = try XCTUnwrap(family.store.nextAlternatingOwner(choreID: chore))
        try family.store.activateAsNeededChore(choreID: chore)
        XCTAssertEqual(family.store.snapshot.occurrence(choreID: chore, on: family.store.day)?.assignedMemberID,
                       firstOwner.id)

        let facts = try family.repository.facts(householdID: revision.householdID)
        let staleSkip = HouseholdFact(
            id: UUID(), householdID: revision.householdID,
            sequence: try XCTUnwrap(facts.map(\.sequence).max()) + 1,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .alternatingTurnAdvance(AlternatingTurnAdvance(
                choreID: chore, revisionID: revision.id, expectedMemberID: firstOwner.id,
                day: family.store.day, recordedByMemberID: family.parent.id
            ))
        )
        try family.repository.commit(facts: [staleSkip], uploaded: true)
        let merged = try HouseholdStore(repository: family.repository,
                                        clock: { family.clock.now }, automaticSync: false)

        XCTAssertEqual(merged.dailyList().first { $0.id == chore }?.turnOwnerID, firstOwner.id)
        try merged.setCompletion(choreID: chore, memberID: firstOwner.id,
                                 date: family.clock.now, state: .done)
        let tomorrow = ISO8601DateFormatter().date(from: "2026-09-08T16:00:00Z")!
        XCTAssertEqual(ChoreRules.nextAlternatingOwner(choreID: chore, on: CivilDay(tomorrow, calendar: merged.calendar),
                                                        snapshot: merged.snapshot)?.id, revision.memberIDs[1])
    }

    func testStaleDisplacedCompletionCannotRollBackAsNeededTurn() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Empty Dishwasher", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id, nora.id], schedulingMode: .asNeeded
        )
        let winning = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        try family.store.activateAsNeededChore(choreID: chore)
        let owner = try XCTUnwrap(family.store.dailyList().first { $0.id == chore }?.turnOwnerID)
        try family.store.setCompletion(choreID: chore, memberID: owner, date: family.clock.now, state: .done)

        let displaced = ChoreRevision(
            id: UUID(), householdID: winning.householdID, choreID: chore, weekday: winning.weekday,
            effectiveDay: CivilDay(rawValue: "2026-09-06")!, title: winning.title,
            notes: winning.notes, category: winning.category, mode: winning.mode,
            memberIDs: winning.memberIDs, isArchived: false, schedulingMode: .asNeeded
        )
        let facts = try family.repository.facts(householdID: winning.householdID)
        let sequence = try XCTUnwrap(facts.map(\.sequence).max())
        let staleFacts = [
            HouseholdFact(
                id: UUID(), householdID: winning.householdID, sequence: sequence + 1,
                authorDeviceID: UUID(), authorMemberID: family.parent.id, body: .chore(displaced)
            ),
            HouseholdFact(
                id: UUID(), householdID: winning.householdID, sequence: sequence + 2,
                authorDeviceID: UUID(), authorMemberID: family.parent.id,
                body: .completion(DatedCompletion(
                    choreID: chore, revisionID: displaced.id, memberID: owner, day: family.store.day,
                    state: .unmarked, eligibleMemberIDs: winning.memberIDs, mode: .alternating,
                    recordedByMemberID: family.parent.id
                ))
            )
        ]
        try family.repository.commit(facts: staleFacts, uploaded: true)
        family.move(to: "2026-09-08T16:00:00Z")
        let merged = try HouseholdStore(repository: family.repository,
                                        clock: { family.clock.now }, automaticSync: false)

        XCTAssertEqual(merged.nextAlternatingOwner(choreID: chore)?.id, winning.memberIDs[1])
    }

    func testParentChosenFirstAlternatingChildPersistsFullEligibleOrder() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let archived = try family.store.saveMember(name: "Archived", role: .child, avatar: .cat)
        try family.store.archiveMember(archived.id)
        let selected = [family.hanna.id, family.alek.id, nora.id]
        let baseOrder = family.store.orderedEligibleChildren(
            choreID: UUID(), selectedMemberIDs: Set(selected)
        ).map(\.id)
        let first = baseOrder[1]

        let scheduled = try family.store.saveChore(
            weekday: .monday, title: "Set Table", mode: .alternating,
            memberIDs: selected, firstAlternatingMemberID: first
        )
        let asNeeded = try family.store.saveChore(
            weekday: .monday, title: "Empty Dishwasher", mode: .alternating,
            memberIDs: selected, schedulingMode: .asNeeded, firstAlternatingMemberID: first
        )
        let expected = [baseOrder[1], baseOrder[2], baseOrder[0]]
        let scheduledRevision = try XCTUnwrap(family.store.snapshot.configuration(
            choreID: scheduled, on: family.store.day
        ))
        let asNeededRevision = try XCTUnwrap(family.store.snapshot.configuration(
            choreID: asNeeded, on: family.store.day
        ))

        XCTAssertEqual(scheduledRevision.memberIDs, expected)
        XCTAssertEqual(asNeededRevision.memberIDs, expected)
        XCTAssertEqual(family.store.dailyList().first { $0.id == scheduled }?.turnOwnerID, first)
        XCTAssertEqual(family.store.nextAlternatingOwner(choreID: asNeeded)?.id, first)
        XCTAssertFalse(scheduledRevision.memberIDs.contains(archived.id))
        XCTAssertThrowsError(try family.store.saveChore(
            weekday: .monday, title: "Invalid Start", mode: .alternating,
            memberIDs: selected, firstAlternatingMemberID: archived.id
        ))
    }

    func testIncompleteLegacyActivationsAdvanceByHistoricalActivationOrder() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Empty Dishwasher", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id, nora.id], schedulingMode: .asNeeded
        )
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        let base = try family.repository.facts(householdID: revision.householdID)
        let initialSequence = try XCTUnwrap(base.map(\.sequence).max())
        let legacyDays = [CivilDay(rawValue: "2026-09-07")!, CivilDay(rawValue: "2026-09-08")!]
        let legacy = legacyDays.enumerated().map { offset, day in
            HouseholdFact(
                id: UUID(), householdID: revision.householdID,
                sequence: initialSequence + Int64(offset + 1),
                authorDeviceID: UUID(), authorMemberID: family.parent.id,
                body: .occurrence(ChoreOccurrenceDisposition(
                    choreID: chore, revisionID: revision.id, day: day,
                    state: .available, alternatingSkipBehavior: nil,
                    recordedByMemberID: family.parent.id
                ))
            )
        }
        try family.repository.commit(facts: legacy, uploaded: true)
        family.move(to: "2026-09-09T16:00:00Z")
        let upgraded = try HouseholdStore(repository: family.repository,
                                          clock: { family.clock.now }, automaticSync: false)

        for (offset, day) in legacyDays.enumerated() {
            let date = day.date(in: upgraded.calendar)
            XCTAssertEqual(upgraded.dailyList(on: date).first { $0.id == chore }?.turnOwnerID,
                           revision.memberIDs[offset])
        }
        XCTAssertEqual(upgraded.nextAlternatingOwner(choreID: chore)?.id, revision.memberIDs[2])
        try upgraded.setCompletion(choreID: chore, memberID: revision.memberIDs[0],
                                   date: legacyDays[0].date(in: upgraded.calendar), state: .done)
        try upgraded.setCompletion(choreID: chore, memberID: revision.memberIDs[1],
                                   date: legacyDays[1].date(in: upgraded.calendar), state: .done)
        try upgraded.activateAsNeededChore(choreID: chore)
        XCTAssertEqual(upgraded.dailyList().first { $0.id == chore }?.turnOwnerID, revision.memberIDs[2])
    }

    func testLegacyActivationDecodesWithoutRecordedOwner() throws {
        let oldActivation = ChoreOccurrenceDisposition(
            choreID: UUID(), revisionID: UUID(), day: CivilDay(rawValue: "2026-09-07")!,
            state: .available, alternatingSkipBehavior: nil, recordedByMemberID: UUID()
        )
        let encoded = try JSONEncoder().encode(oldActivation)
        var legacyRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyRecord.removeValue(forKey: "assignedMemberID")
        let oldPayload = try JSONSerialization.data(withJSONObject: legacyRecord)

        let decoded = try JSONDecoder().decode(ChoreOccurrenceDisposition.self, from: oldPayload)
        XCTAssertEqual(decoded, oldActivation)
        XCTAssertNil(decoded.assignedMemberID)
    }

    func testDeleteChoreRemovesCurrentVariantsAndPreservesCompletedCredit() throws {
        let family = try TestFamily()
        let scheduledIncomplete = try family.store.saveChore(
            weekday: .monday, title: "Scheduled Incomplete", mode: .particular,
            memberIDs: [family.hanna.id]
        )
        let scheduledDone = try family.store.saveChore(
            weekday: .monday, title: "Scheduled Done", mode: .particular,
            memberIDs: [family.hanna.id]
        )
        let inactiveAsNeeded = try family.store.saveChore(
            weekday: .monday, title: "Inactive As Needed", mode: .particular,
            memberIDs: [family.hanna.id], schedulingMode: .asNeeded
        )
        let activeAsNeeded = try family.store.saveChore(
            weekday: .monday, title: "Active As Needed", mode: .particular,
            memberIDs: [family.hanna.id], schedulingMode: .asNeeded
        )
        let completedAsNeeded = try family.store.saveChore(
            weekday: .monday, title: "Completed As Needed", mode: .particular,
            memberIDs: [family.hanna.id], schedulingMode: .asNeeded
        )
        let scheduledAlternating = try family.store.saveChore(
            weekday: .monday, title: "Scheduled Alternating", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id]
        )
        let activeAlternating = try family.store.saveChore(
            weekday: .monday, title: "Active Alternating", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id], schedulingMode: .asNeeded
        )
        try family.store.activateAsNeededChore(choreID: activeAsNeeded)
        try family.store.activateAsNeededChore(choreID: completedAsNeeded)
        try family.store.activateAsNeededChore(choreID: activeAlternating)
        try family.store.selectProfile(family.hanna.id)
        try family.store.setCompletion(choreID: scheduledDone, memberID: family.hanna.id,
                                       date: family.clock.now, state: .done)
        try family.store.setCompletion(choreID: completedAsNeeded, memberID: family.hanna.id,
                                       date: family.clock.now, state: .done)
        try family.store.selectProfile(family.parent.id)

        let deleted = [scheduledIncomplete, scheduledDone, inactiveAsNeeded, activeAsNeeded, completedAsNeeded,
                       scheduledAlternating, activeAlternating]
        for chore in deleted { try family.store.deleteChore(chore) }

        let current = family.store.dailyList()
        XCTAssertTrue(ChoreRules.visibleList(current, to: family.parent).allSatisfy { !deleted.contains($0.id) })
        XCTAssertTrue(ChoreRules.visibleList(current, to: family.hanna).allSatisfy { !deleted.contains($0.id) })
        XCTAssertNil(current.first { $0.id == scheduledIncomplete })
        XCTAssertNil(current.first { $0.id == activeAsNeeded })
        XCTAssertNil(current.first { $0.id == scheduledAlternating })
        XCTAssertNil(current.first { $0.id == activeAlternating })
        let retained = try XCTUnwrap(current.first { $0.id == scheduledDone })
        XCTAssertTrue(retained.isDeleted)
        XCTAssertEqual(retained.state(for: family.hanna.id), .done)
        XCTAssertFalse(PermissionService.canSetState(actor: family.hanna, target: family.hanna.id,
                                                     chore: retained, state: .unmarked))
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id).items
            .first { $0.choreID == scheduledDone }?.state, .done)
        XCTAssertTrue(try XCTUnwrap(current.first { $0.id == completedAsNeeded }).isDeleted)
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id).items
            .first { $0.choreID == completedAsNeeded }?.state, .done)
        XCTAssertTrue(deleted.allSatisfy {
            family.store.snapshot.configuration(choreID: $0, on: family.store.day)?.isArchived == true
        })
    }

    func testDeleteChorePreservesExplicitMissedHistoryAndAllowance() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Missed Chore", mode: .particular,
            memberIDs: [family.hanna.id]
        )
        let monday = family.clock.now
        try family.store.setCompletion(choreID: chore, memberID: family.hanna.id,
                                       date: monday, state: .missed)
        let allowanceBefore = family.store.allowanceWeek(for: family.hanna.id)

        try family.store.deleteChore(chore)

        let historical = try XCTUnwrap(family.store.dailyList().first { $0.id == chore })
        XCTAssertTrue(historical.isDeleted)
        XCTAssertEqual(historical.state(for: family.hanna.id), .missed)
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id), allowanceBefore)

        family.move(to: "2026-09-08T16:00:00Z")
        let allowanceAfter = family.store.allowanceWeek(for: family.hanna.id, containing: monday)
        XCTAssertEqual(allowanceAfter.items.first { $0.choreID == chore }?.state, .missed)
        XCTAssertEqual(allowanceAfter.missing.map(\.choreID), [chore])
        XCTAssertFalse(allowanceAfter.earned)
    }

    func testDeleteChoreKeepsPriorWeekHistoryAllowanceAndStreak() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Water Plants", mode: .particular,
            memberIDs: [family.hanna.id]
        )
        try family.complete(chore, as: family.hanna)
        family.move(to: "2026-09-14T16:00:00Z")
        try family.store.selectProfile(family.parent.id)
        try family.store.deleteChore(chore)

        let priorDate = ISO8601DateFormatter().date(from: "2026-09-07T16:00:00Z")!
        let prior = family.store.allowanceWeek(for: family.hanna.id, containing: priorDate)
        XCTAssertEqual(prior.items.first { $0.choreID == chore }?.state, .done)
        XCTAssertEqual(MetricsService.streak(childID: family.hanna.id,
                                             snapshot: family.store.snapshot,
                                             today: family.clock.now), 1)
        XCTAssertTrue(ChoreRules.visibleList(family.store.dailyList(), to: family.parent).isEmpty)
    }

    func testDeleteChorePreservesOptionalAnyOneAllowanceSemantics() throws {
        let family = try TestFamily()
        let chore = try family.chore(.anyOne, ids: [family.hanna.id, family.alek.id])
        try family.complete(chore, as: family.hanna)
        let streakBeforeDeletion = MetricsService.streak(
            childID: family.hanna.id, snapshot: family.store.snapshot, today: family.clock.now
        )
        XCTAssertNil(family.store.allowanceWeek(for: family.hanna.id).items.first { $0.choreID == chore })
        try family.store.selectProfile(family.parent.id)

        try family.store.deleteChore(chore)

        let hidden = try XCTUnwrap(family.store.dailyList().first { $0.id == chore })
        XCTAssertTrue(hidden.isDeleted)
        XCTAssertTrue(hidden.requiredMemberIDs.isEmpty)
        XCTAssertEqual(Set(hidden.eligibleMembers.map(\.id)), [family.hanna.id, family.alek.id])
        XCTAssertNil(family.store.allowanceWeek(for: family.hanna.id).items.first { $0.choreID == chore })
        XCTAssertEqual(MetricsService.streak(childID: family.hanna.id,
                                             snapshot: family.store.snapshot,
                                             today: family.clock.now), streakBeforeDeletion)
    }

    func testDeleteChoreDropsIncompleteSiblingObligations() throws {
        let family = try TestFamily()
        let chore = try family.chore(.multiple, ids: [family.hanna.id, family.alek.id])
        let monday = family.clock.now
        try family.complete(chore, as: family.hanna)
        try family.store.selectProfile(family.parent.id)

        try family.store.deleteChore(chore)
        family.move(to: "2026-09-08T16:00:00Z")

        let hidden = try XCTUnwrap(family.store.dailyList(on: monday).first { $0.id == chore })
        XCTAssertEqual(Set(hidden.eligibleMembers.map(\.id)), [family.hanna.id, family.alek.id])
        XCTAssertEqual(hidden.requiredMemberIDs, [family.hanna.id])
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id, containing: monday).items
            .first { $0.choreID == chore }?.state, .done)
        XCTAssertNil(family.store.allowanceWeek(for: family.alek.id, containing: monday).items
            .first { $0.choreID == chore })
        let alekMonday = MetricsService.weekFacts(
            childID: family.alek.id, containing: monday,
            snapshot: family.store.snapshot, today: family.clock.now
        ).first
        XCTAssertEqual(alekMonday?.requiredStates, [])
    }

    func testDeleteChoreKeepsDisplacedRevisionOutOfRequirements() throws {
        let family = try TestFamily()
        let children = [family.hanna, family.alek].sorted { $0.id.uuidString < $1.id.uuidString }
        let displacedMember = children[0]
        let winningMember = children[1]
        let chore = try family.chore(.particular, ids: [displacedMember.id])
        try family.complete(chore, as: displacedMember)
        let original = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        let winningRevision = ChoreRevision(
            id: UUID(), householdID: original.householdID, choreID: chore,
            weekday: original.weekday, effectiveDay: family.store.day,
            title: original.title, notes: original.notes, category: original.category,
            mode: .particular, memberIDs: [winningMember.id], isArchived: false
        )
        let facts = try family.repository.facts(householdID: original.householdID)
        let winningFact = HouseholdFact(
            id: UUID(), householdID: original.householdID,
            sequence: try XCTUnwrap(facts.map(\.sequence).max()) + 1,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .chore(winningRevision)
        )
        try family.repository.commit(facts: [winningFact], uploaded: true)
        let merged = try HouseholdStore(repository: family.repository,
                                        clock: { family.clock.now }, automaticSync: false)
        try merged.selectProfile(winningMember.id)
        try merged.setCompletion(choreID: chore, memberID: winningMember.id,
                                 date: family.clock.now, state: .done)
        try merged.selectProfile(family.parent.id)

        try merged.deleteChore(chore)

        let hidden = try XCTUnwrap(merged.dailyList().first { $0.id == chore })
        XCTAssertEqual(hidden.configuration.id, winningRevision.id)
        XCTAssertEqual(hidden.eligibleMembers.map(\.id), [winningMember.id])
        XCTAssertEqual(hidden.requiredMemberIDs, [winningMember.id])
        XCTAssertEqual(hidden.contributions.map(\.memberID), [winningMember.id])
        XCTAssertNil(merged.allowanceWeek(for: displacedMember.id).items.first { $0.choreID == chore })
        XCTAssertEqual(merged.allowanceWeek(for: winningMember.id).items
            .first { $0.choreID == chore }?.state, .done)
    }

    func testDeletedChoreKeepsWinningCompletionAfterStaleRevisionFact() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Water Plants", mode: .particular,
            memberIDs: [family.hanna.id]
        )
        let winning = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        try family.store.setCompletion(choreID: chore, memberID: family.hanna.id,
                                       date: family.clock.now, state: .done)
        let beforeAllowance = family.store.allowanceWeek(for: family.hanna.id)
        let beforeFacts = family.store.weekFacts(for: family.hanna.id)
        let beforeStreak = MetricsService.streak(childID: family.hanna.id,
                                                 snapshot: family.store.snapshot,
                                                 today: family.clock.now)
        try family.store.deleteChore(chore)

        let displaced = ChoreRevision(
            id: UUID(), householdID: winning.householdID, choreID: chore, weekday: winning.weekday,
            effectiveDay: CivilDay(rawValue: "2026-09-06")!, title: "Stale Name",
            notes: winning.notes, category: winning.category, mode: winning.mode,
            memberIDs: winning.memberIDs, isArchived: false, schedulingMode: winning.schedulingMode
        )
        let facts = try family.repository.facts(householdID: winning.householdID)
        let sequence = try XCTUnwrap(facts.map(\.sequence).max())
        let stale = [
            HouseholdFact(
                id: UUID(), householdID: winning.householdID, sequence: sequence + 1,
                authorDeviceID: UUID(), authorMemberID: family.parent.id, body: .chore(displaced)
            ),
            HouseholdFact(
                id: UUID(), householdID: winning.householdID, sequence: sequence + 2,
                authorDeviceID: UUID(), authorMemberID: family.parent.id,
                body: .completion(DatedCompletion(
                    choreID: chore, revisionID: displaced.id, memberID: family.hanna.id,
                    day: family.store.day, state: .unmarked, eligibleMemberIDs: [family.hanna.id],
                    mode: .particular, recordedByMemberID: family.parent.id
                ))
            )
        ]
        try family.repository.commit(facts: stale, uploaded: true)
        let merged = try HouseholdStore(repository: family.repository,
                                        clock: { family.clock.now }, automaticSync: false)
        let hidden = try XCTUnwrap(merged.dailyList().first { $0.id == chore })

        XCTAssertEqual(hidden.configuration.title, "Water Plants")
        XCTAssertEqual(hidden.configuration.id, winning.id)
        XCTAssertEqual(hidden.state(for: family.hanna.id), .done)
        XCTAssertEqual(merged.allowanceWeek(for: family.hanna.id), beforeAllowance)
        XCTAssertEqual(merged.weekFacts(for: family.hanna.id), beforeFacts)
        XCTAssertEqual(MetricsService.streak(childID: family.hanna.id,
                                             snapshot: merged.snapshot,
                                             today: family.clock.now), beforeStreak)
    }

    func testDeletedChoreSnapshotRejectsLaterSameRevisionUnmarkedFact() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Water Plants", mode: .particular,
            memberIDs: [family.hanna.id]
        )
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        try family.store.setCompletion(choreID: chore, memberID: family.hanna.id,
                                       date: family.clock.now, state: .done)
        let allowanceBefore = family.store.allowanceWeek(for: family.hanna.id)
        let factsBefore = family.store.weekFacts(for: family.hanna.id)
        let streakBefore = MetricsService.streak(childID: family.hanna.id,
                                                 snapshot: family.store.snapshot,
                                                 today: family.clock.now)
        try family.store.deleteChore(chore)

        let facts = try family.repository.facts(householdID: revision.householdID)
        let staleUnmarked = HouseholdFact(
            id: UUID(), householdID: revision.householdID,
            sequence: try XCTUnwrap(facts.map(\.sequence).max()) + 1,
            authorDeviceID: UUID(), authorMemberID: family.hanna.id,
            body: .completion(DatedCompletion(
                choreID: chore, revisionID: revision.id, memberID: family.hanna.id,
                day: family.store.day, state: .unmarked, eligibleMemberIDs: [family.hanna.id],
                mode: .particular, recordedByMemberID: family.hanna.id
            ))
        )
        try family.repository.commit(facts: [staleUnmarked], uploaded: true)
        let merged = try HouseholdStore(repository: family.repository,
                                        clock: { family.clock.now }, automaticSync: false)
        let hidden = try XCTUnwrap(merged.dailyList().first { $0.id == chore })

        XCTAssertEqual(hidden.state(for: family.hanna.id), .done)
        XCTAssertEqual(merged.allowanceWeek(for: family.hanna.id), allowanceBefore)
        XCTAssertEqual(merged.weekFacts(for: family.hanna.id), factsBefore)
        XCTAssertEqual(MetricsService.streak(childID: family.hanna.id,
                                             snapshot: merged.snapshot,
                                             today: family.clock.now), streakBefore)
    }

    func testOfflineSameRevisionUnmarkedCannotRewriteSynchronizedDeletionHistory() async throws {
        let fixture = try await connectedParentInstallation()
        let chore = try fixture.family.store.saveChore(
            weekday: .monday, title: "Water Plants", mode: .particular,
            memberIDs: [fixture.family.hanna.id]
        )
        try await fixture.family.store.synchronize()
        try await fixture.guest.synchronize()
        try fixture.guest.selectProfile(fixture.family.hanna.id)

        try fixture.family.store.setCompletion(choreID: chore, memberID: fixture.family.hanna.id,
                                               date: fixture.family.clock.now, state: .done)
        let allowanceBefore = fixture.family.store.allowanceWeek(for: fixture.family.hanna.id)
        let streakBefore = MetricsService.streak(childID: fixture.family.hanna.id,
                                                 snapshot: fixture.family.store.snapshot,
                                                 today: fixture.family.clock.now)
        try fixture.family.store.deleteChore(chore)
        try await fixture.family.store.synchronize()

        try fixture.guest.setCompletion(choreID: chore, memberID: fixture.family.hanna.id,
                                        date: fixture.family.clock.now, state: .unmarked)
        try await fixture.guest.synchronize()
        try await fixture.family.store.synchronize()

        let parentHistory = try XCTUnwrap(fixture.family.store.dailyList().first { $0.id == chore })
        let guestHistory = try XCTUnwrap(fixture.guest.dailyList().first { $0.id == chore })
        XCTAssertEqual(parentHistory.state(for: fixture.family.hanna.id), .done)
        XCTAssertEqual(guestHistory.state(for: fixture.family.hanna.id), .done)
        XCTAssertEqual(fixture.family.store.allowanceWeek(for: fixture.family.hanna.id), allowanceBefore)
        XCTAssertEqual(MetricsService.streak(childID: fixture.family.hanna.id,
                                             snapshot: fixture.family.store.snapshot,
                                             today: fixture.family.clock.now), streakBefore)
        XCTAssertTrue(ChoreRules.visibleList(fixture.guest.dailyList(), to: fixture.family.hanna)
            .allSatisfy { $0.id != chore })
    }

    func testDeletingChoresPreservesPriorResolvedOutcomesAndScoring() throws {
        let family = try TestFamily()
        let done = try family.store.saveChore(
            weekday: .monday, title: "Done Chore", mode: .particular, memberIDs: [family.hanna.id]
        )
        let missed = try family.store.saveChore(
            weekday: .monday, title: "Missed Chore", mode: .particular, memberIDs: [family.hanna.id]
        )
        let notNeeded = try family.store.saveChore(
            weekday: .monday, title: "Not Needed Chore", mode: .particular, memberIDs: [family.hanna.id]
        )
        let excused = try family.store.saveChore(
            weekday: .monday, title: "Excused Chore", mode: .particular, memberIDs: [family.alek.id]
        )
        let monday = family.clock.now
        try family.store.setCompletion(choreID: done, memberID: family.hanna.id, date: monday, state: .done)
        try family.store.markOccurrenceNotNeeded(choreID: notNeeded, date: monday)
        try family.store.setExcused(memberID: family.alek.id, date: monday, excused: true)
        family.move(to: "2026-09-08T16:00:00Z")
        let beforeHannaAllowance = family.store.allowanceWeek(for: family.hanna.id, containing: monday)
        let beforeAlekAllowance = family.store.allowanceWeek(for: family.alek.id, containing: monday)
        let beforeHannaFacts = family.store.weekFacts(for: family.hanna.id, containing: monday)
        let beforeAlekFacts = family.store.weekFacts(for: family.alek.id, containing: monday)
        let beforeHannaStreak = MetricsService.streak(childID: family.hanna.id,
                                                      snapshot: family.store.snapshot,
                                                      today: family.clock.now)

        for chore in [done, missed, notNeeded, excused] { try family.store.deleteChore(chore) }

        let historical = Dictionary(uniqueKeysWithValues: family.store.dailyList(on: monday).map { ($0.id, $0) })
        XCTAssertEqual(historical[done]?.configuration.title, "Done Chore")
        XCTAssertEqual(historical[done]?.state(for: family.hanna.id), .done)
        XCTAssertEqual(historical[missed]?.state(for: family.hanna.id), .missed)
        XCTAssertEqual(historical[notNeeded]?.isNotNeeded, true)
        XCTAssertEqual(historical[excused]?.configuration.title, "Excused Chore")
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id, containing: monday), beforeHannaAllowance)
        XCTAssertEqual(family.store.allowanceWeek(for: family.alek.id, containing: monday), beforeAlekAllowance)
        XCTAssertEqual(family.store.weekFacts(for: family.hanna.id, containing: monday), beforeHannaFacts)
        XCTAssertEqual(family.store.weekFacts(for: family.alek.id, containing: monday), beforeAlekFacts)
        XCTAssertEqual(MetricsService.streak(childID: family.hanna.id,
                                             snapshot: family.store.snapshot,
                                             today: family.clock.now), beforeHannaStreak)
    }

    func testChoreDeletionConvergesAcrossParentAndChildInstallations() async throws {
        let fixture = try await connectedParentInstallation()
        let chore = try fixture.family.store.saveChore(
            weekday: .monday, title: "Empty Dishwasher", mode: .particular,
            memberIDs: [fixture.family.hanna.id]
        )
        try await fixture.family.store.synchronize()
        try await fixture.guest.synchronize()
        try fixture.guest.selectProfile(fixture.family.hanna.id)
        XCTAssertTrue(ChoreRules.visibleList(fixture.guest.dailyList(), to: fixture.family.hanna)
            .contains { $0.id == chore })

        try fixture.family.store.deleteChore(chore)
        try await fixture.family.store.synchronize()
        try await fixture.guest.synchronize()

        XCTAssertTrue(ChoreRules.visibleList(fixture.family.store.dailyList(), to: fixture.family.parent)
            .allSatisfy { $0.id != chore })
        XCTAssertTrue(ChoreRules.visibleList(fixture.guest.dailyList(), to: fixture.family.hanna)
            .allSatisfy { $0.id != chore })
        XCTAssertThrowsError(try fixture.guest.setCompletion(
            choreID: chore, memberID: fixture.family.hanna.id,
            date: fixture.family.clock.now, state: .done
        ))
    }

    func testAlternatingCurrentAndNextTurnSynchronizeAcrossInstallations() async throws {
        let fixture = try await connectedParentInstallation()
        let nora = try fixture.family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try fixture.family.store.saveChore(
            weekday: .monday, title: "Empty Dishwasher", mode: .alternating,
            memberIDs: [fixture.family.hanna.id, fixture.family.alek.id, nora.id],
            schedulingMode: .asNeeded, firstAlternatingMemberID: nora.id
        )
        try await fixture.family.store.synchronize()
        try await fixture.guest.synchronize()
        let first = try XCTUnwrap(fixture.family.store.nextAlternatingOwner(choreID: chore))
        XCTAssertEqual(first.id, nora.id)
        XCTAssertEqual(fixture.guest.nextAlternatingOwner(choreID: chore)?.id, first.id)

        try fixture.family.store.skipNextAlternatingChild(choreID: chore)
        try await fixture.family.store.synchronize()
        try await fixture.guest.synchronize()
        let next = try XCTUnwrap(fixture.family.store.nextAlternatingOwner(choreID: chore))
        XCTAssertNotEqual(next.id, first.id)
        XCTAssertEqual(fixture.guest.nextAlternatingOwner(choreID: chore)?.id, next.id)

        try fixture.family.store.activateAsNeededChore(choreID: chore)
        try await fixture.family.store.synchronize()
        try await fixture.guest.synchronize()
        XCTAssertEqual(fixture.family.store.dailyList().first { $0.id == chore }?.turnOwnerID, next.id)
        XCTAssertEqual(fixture.guest.dailyList().first { $0.id == chore }?.turnOwnerID, next.id)
    }

    func testSchedulingModeEditsPreserveAlternatingTurnsAcrossInstallations() async throws {
        let fixture = try await connectedParentInstallation()
        let nora = try fixture.family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let participants = [fixture.family.hanna.id, fixture.family.alek.id, nora.id]
        let scheduledToAsNeeded = try fixture.family.store.saveChore(
            weekday: .monday, title: "Scheduled Switch", mode: .alternating,
            memberIDs: participants
        )
        let asNeededToScheduled = try fixture.family.store.saveChore(
            weekday: .monday, title: "As Needed Switch", mode: .alternating,
            memberIDs: participants, schedulingMode: .asNeeded
        )
        let scheduledOrder = try XCTUnwrap(fixture.family.store.snapshot.configuration(
            choreID: scheduledToAsNeeded, on: fixture.family.store.day
        )).memberIDs
        let asNeededOrder = try XCTUnwrap(fixture.family.store.snapshot.configuration(
            choreID: asNeededToScheduled, on: fixture.family.store.day
        )).memberIDs
        try fixture.family.store.activateAsNeededChore(choreID: asNeededToScheduled)
        try fixture.family.store.setCompletion(choreID: asNeededToScheduled, memberID: asNeededOrder[0],
                                               date: fixture.family.clock.now, state: .done)
        try await fixture.family.store.synchronize()
        try await fixture.guest.synchronize()

        try fixture.family.store.saveChore(
            choreID: scheduledToAsNeeded, weekday: .monday, title: "Scheduled Switch",
            mode: .alternating, memberIDs: scheduledOrder, schedulingMode: .asNeeded
        )
        try fixture.family.store.saveChore(
            choreID: asNeededToScheduled, weekday: .tuesday, title: "As Needed Switch",
            mode: .alternating, memberIDs: asNeededOrder, schedulingMode: .scheduled
        )
        try await fixture.family.store.synchronize()
        try await fixture.guest.synchronize()

        fixture.family.move(to: "2026-09-08T16:00:00Z")
        fixture.guest.refreshDate()
        XCTAssertEqual(fixture.family.store.nextAlternatingOwner(choreID: scheduledToAsNeeded)?.id,
                       scheduledOrder[1])
        XCTAssertEqual(fixture.guest.nextAlternatingOwner(choreID: scheduledToAsNeeded)?.id,
                       scheduledOrder[1])
        XCTAssertEqual(fixture.family.store.dailyList().first { $0.id == asNeededToScheduled }?.turnOwnerID,
                       asNeededOrder[1])
        XCTAssertEqual(fixture.guest.dailyList().first { $0.id == asNeededToScheduled }?.turnOwnerID,
                       asNeededOrder[1])
    }

    func testDeleteChoreAlsoDefeatsPendingTomorrowEdit() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Original", mode: .particular,
            memberIDs: [family.hanna.id]
        )
        try family.store.saveChore(choreID: chore, weekday: .tuesday, title: "Edited",
                                   mode: .particular, memberIDs: [family.alek.id])
        try family.store.deleteChore(chore)
        family.move(to: "2026-09-08T16:00:00Z")

        XCTAssertTrue(family.store.snapshot.configuration(choreID: chore, on: family.store.day)?.isArchived == true)
        XCTAssertTrue(ChoreRules.visibleList(family.store.dailyList(), to: family.parent)
            .allSatisfy { $0.id != chore })
    }

    func testLateOfflineEditCannotResurrectDeletedChoreOnAnyDevice() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Water Plants", mode: .particular,
            memberIDs: [family.hanna.id]
        )
        try family.store.setCompletion(choreID: chore, memberID: family.hanna.id,
                                       date: family.clock.now, state: .done)
        let oldRevision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        try family.store.deleteChore(chore)
        let facts = try family.repository.facts(householdID: oldRevision.householdID)
        let lateRevision = ChoreRevision(
            id: UUID(), householdID: oldRevision.householdID, choreID: chore,
            weekday: .tuesday, effectiveDay: family.store.day,
            title: "Stale Offline Edit", notes: oldRevision.notes,
            category: oldRevision.category, mode: oldRevision.mode,
            memberIDs: oldRevision.memberIDs, isArchived: false,
            schedulingMode: oldRevision.schedulingMode
        )
        let lateEdit = HouseholdFact(
            id: UUID(), householdID: oldRevision.householdID,
            sequence: try XCTUnwrap(facts.map(\.sequence).max()) + 1,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .chore(lateRevision)
        )
        try family.repository.commit(facts: [lateEdit], uploaded: true)
        let merged = try HouseholdStore(repository: family.repository,
                                        clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(merged.snapshot.configuration(choreID: chore, on: merged.day)?.id, lateRevision.id)
        XCTAssertTrue(ChoreRules.visibleList(merged.dailyList(), to: family.parent).allSatisfy { $0.id != chore })
        XCTAssertTrue(ChoreRules.visibleList(merged.dailyList(), to: family.hanna).allSatisfy { $0.id != chore })
        XCTAssertEqual(merged.allowanceWeek(for: family.hanna.id).items.first { $0.choreID == chore }?.state, .done)
        XCTAssertThrowsError(try merged.setCompletion(choreID: chore, memberID: family.hanna.id,
                                                       date: family.clock.now, state: .unmarked))
        XCTAssertThrowsError(try merged.saveChore(choreID: chore, weekday: .monday, title: "Restore",
                                                  mode: .particular, memberIDs: [family.hanna.id]))

        family.move(to: "2026-09-08T16:00:00Z")
        let onNextDay = try HouseholdStore(repository: family.repository,
                                           clock: { family.clock.now }, automaticSync: false)
        XCTAssertTrue(ChoreRules.visibleList(onNextDay.dailyList(), to: family.parent)
            .allSatisfy { $0.id != chore })
        XCTAssertTrue(onNextDay.snapshot.isChoreDeleted(chore, on: onNextDay.day))
    }

    func testCreatorOwnerDeletionIsPermanentAndAllowsNewFamily() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: transport)
        try await family.store.connect()
        let location = try XCTUnwrap(family.store.session.location)
        XCTAssertTrue(family.store.canDeleteFamily)

        try await family.store.deleteFamily()

        XCTAssertNil(server.zones[location.zoneName])
        XCTAssertEqual(server.accountMembershipLocks["owner"]?.state, .released)
        XCTAssertNil(family.store.household)
        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                              transport: transport,
                                              clock: { family.clock.now }, automaticSync: false)
        try await replacement.reconcileAccountMembershipLock()
        XCTAssertNil(replacement.household)
        try replacement.createFamily(name: "New Family", parentName: "New Parent")
        XCTAssertEqual(replacement.household?.name, "New Family")
    }

    func testDeleteFamilyRequiresCreatorAndCloudOwner() async throws {
        let fixture = try await connectedParentInstallation()
        let secondParent = try fixture.family.store.saveMember(name: "Second Parent", role: .parent, avatar: .sun)
        fixture.family.move(to: "2026-09-08T16:00:00Z")
        try fixture.family.store.selectProfile(secondParent.id)
        XCTAssertFalse(fixture.family.store.canDeleteFamily)
        do { try await fixture.family.store.deleteFamily(); XCTFail("Another parent must not delete the family") }
        catch { XCTAssertEqual(error as? HouseholdError, .permission) }

        XCTAssertFalse(fixture.guest.canDeleteFamily)
        do { try await fixture.guest.deleteFamily(); XCTFail("A shared participant must not delete the family") }
        catch { XCTAssertEqual(error as? HouseholdError, .permission) }
        XCTAssertNotNil(fixture.server.zones[fixture.family.store.session.location!.zoneName])
    }

    func testDeleteFamilyRetriesCloudAndMembershipFailuresWithoutFalseSuccess() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: transport)
        try await family.store.connect()
        let location = try XCTUnwrap(family.store.session.location)
        transport.deleteFamilyFailures = 1

        do { try await family.store.deleteFamily(); XCTFail("Network failure must be reported") }
        catch { XCTAssertEqual((error as? CKError)?.code, .networkFailure) }
        XCTAssertNotNil(family.store.household)
        XCTAssertNotNil(server.zones[location.zoneName])
        XCTAssertEqual(server.accountMembershipLocks["owner"]?.state, .active)

        transport.accountLockReleaseFailures = 1
        do { try await family.store.deleteFamily(); XCTFail("Membership cleanup failure must be reported") }
        catch { XCTAssertEqual((error as? CKError)?.code, .networkFailure) }
        XCTAssertNotNil(family.store.household)
        XCTAssertNil(server.zones[location.zoneName])
        XCTAssertEqual(server.accountMembershipLocks["owner"]?.state, .active)

        let relaunched = try HouseholdStore(repository: family.repository, transport: transport,
                                             clock: { family.clock.now }, automaticSync: false)
        XCTAssertTrue(relaunched.canDeleteFamily)
        try await relaunched.deleteFamily()
        XCTAssertNil(relaunched.household)
        XCTAssertEqual(server.accountMembershipLocks["owner"]?.state, .released)
        XCTAssertEqual(transport.deleteFamilyAttempts, 3)
    }

    func testCompletedCloudDeletionOffersSuccessfulLocalCleanup() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: transport)
        try await family.store.connect()
        let location = try XCTUnwrap(family.store.session.location)
        transport.accountLockReleaseFailures = 2

        do { try await family.store.deleteFamily(); XCTFail("Membership cleanup must fail") }
        catch { XCTAssertEqual((error as? CKError)?.code, .networkFailure) }
        XCTAssertNil(server.zones[location.zoneName])
        XCTAssertEqual(family.store.session.pendingFamilyDeletion, true)
        let relaunched = try HouseholdStore(repository: family.repository, transport: transport,
                                             clock: { family.clock.now }, automaticSync: false)

        do { try await relaunched.synchronize(); XCTFail("Deleted family must not synchronize") }
        catch { XCTAssertEqual((error as? CKError)?.code, .zoneNotFound) }
        XCTAssertTrue(relaunched.canFinishDeletingFamily)
        XCTAssertFalse(relaunched.canRemoveUnavailableFamilyFromDevice)
        XCTAssertEqual(server.accountMembershipLocks["owner"]?.state, .active)

        do { try await relaunched.synchronize(); XCTFail("Deleted family must not synchronize") }
        catch { XCTAssertEqual((error as? CKError)?.code, .zoneNotFound) }
        XCTAssertFalse(relaunched.canFinishDeletingFamily)
        XCTAssertTrue(relaunched.canRemoveUnavailableFamilyFromDevice)
        XCTAssertEqual(server.accountMembershipLocks["owner"]?.state, .released)

        try relaunched.removeUnavailableFamilyFromDevice()
        XCTAssertNil(relaunched.household)
    }

    func testPermissionFailureDoesNotExposeUnconfirmedFamilyDeletionRetry() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: transport)
        try await family.store.connect()
        let location = try XCTUnwrap(family.store.session.location)
        transport.fetchError = CKError(.permissionFailure)

        do { try await family.store.synchronize(); XCTFail("Permission failure must be reported") }
        catch { XCTAssertEqual((error as? CKError)?.code, .permissionFailure) }

        XCTAssertTrue(family.store.familyAccessLost)
        XCTAssertNil(family.store.session.pendingFamilyDeletion)
        XCTAssertFalse(family.store.canFinishDeletingFamily)
        XCTAssertNotNil(server.zones[location.zoneName])
        XCTAssertEqual(server.accountMembershipLocks["owner"]?.state, .active)
    }

    func testInvitedDeviceDetectsDeletedFamilyAndCannotResurrectIt() async throws {
        let fixture = try await connectedParentInstallation()
        let location = try XCTUnwrap(fixture.family.store.session.location)
        try await fixture.family.store.deleteFamily()

        do { try await fixture.guest.synchronize(); XCTFail("Deleted family must not synchronize") }
        catch { XCTAssertEqual((error as? CKError)?.code, .zoneNotFound) }
        XCTAssertTrue(fixture.guest.familyAccessLost)
        XCTAssertTrue(fixture.guest.cloudIsReadOnly)
        XCTAssertNil(fixture.server.zones[location.zoneName])
        XCTAssertEqual(fixture.server.accountMembershipLocks["guest"]?.state, .released)
        XCTAssertTrue(fixture.guest.canRemoveUnavailableFamilyFromDevice)
        try fixture.guest.removeUnavailableFamilyFromDevice()
        XCTAssertNil(fixture.guest.household)
        try fixture.guest.createFamily(name: "Guest New Family", parentName: "Guest Parent")
        XCTAssertEqual(fixture.guest.household?.name, "Guest New Family")
        XCTAssertNil(fixture.server.zones[location.zoneName])
    }

    func testReinstalledChildCannotRecoverDeletedFamilyAndCanJoinNewInvitation() async throws {
        let server = TestCloudServer()
        let oldFamily = try TestFamily(transport: TestTransport(server: server, account: "old-owner"))
        let oldInvitation = try await oldFamily.store.createChildInvitation(memberID: oldFamily.hanna.id)
        let childAccount = "reinstalled-child"
        var installedChild: HouseholdStore? = try HouseholdStore(
            repository: HouseholdRepository(inMemory: true),
            transport: TestTransport(server: server, account: childAccount),
            clock: { oldFamily.clock.now }, automaticSync: false
        )
        try await installedChild?.redeemInvitation(oldInvitation.qrPayload)
        let oldHouseholdID = try XCTUnwrap(oldFamily.store.household?.id)
        let oldLocation = try XCTUnwrap(oldFamily.store.session.location)
        XCTAssertEqual(installedChild?.household?.id, oldHouseholdID)
        XCTAssertEqual(server.accountMembershipLocks[childAccount]?.state, .active)

        try await oldFamily.store.deleteFamily()
        installedChild = nil

        let reinstalledChild = try HouseholdStore(
            repository: HouseholdRepository(inMemory: true),
            transport: TestTransport(server: server, account: childAccount),
            clock: { oldFamily.clock.now }, automaticSync: false
        )
        do {
            try await reinstalledChild.reconcileAccountMembershipLock()
            XCTFail("A deleted family must not recover after reinstall")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .invitationUnavailable)
        }

        XCTAssertNil(server.zones[oldLocation.zoneName])
        XCTAssertEqual(server.accountMembershipLocks[childAccount]?.householdID, oldHouseholdID)
        XCTAssertEqual(server.accountMembershipLocks[childAccount]?.state, .active)
        XCTAssertTrue(reinstalledChild.requiresMembershipRecovery)
        XCTAssertNil(reinstalledChild.household)
        let recoveredFamilies = try await reinstalledChild.discoverFamilies()
        XCTAssertTrue(recoveredFamilies.isEmpty)
        do {
            try await reinstalledChild.redeemInvitation(oldInvitation.qrPayload)
            XCTFail("A deleted family's invitation must not be redeemable after reinstall")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .invitation)
        }
        XCTAssertNil(reinstalledChild.household)
        XCTAssertNil(reinstalledChild.session.pendingInvitationPackage)

        let newFamily = try TestFamily(transport: TestTransport(server: server, account: "new-owner"))
        let newInvitation = try await newFamily.store.createChildInvitation(memberID: newFamily.hanna.id)
        try await reinstalledChild.redeemInvitation(newInvitation.qrPayload)

        XCTAssertEqual(reinstalledChild.household?.id, newFamily.store.household?.id)
        XCTAssertEqual(reinstalledChild.selectedMember?.id, newFamily.hanna.id)
        XCTAssertEqual(server.accountMembershipLocks[childAccount]?.householdID, newFamily.store.household?.id)
        XCTAssertEqual(server.accountMembershipLocks[childAccount]?.state, .active)
        XCTAssertNotEqual(reinstalledChild.household?.id, oldHouseholdID)
    }

    private typealias ConnectedInstallation = (
        family: TestFamily, server: TestCloudServer, guest: HouseholdStore
    )

    private func connectedParentInstallation() async throws -> ConnectedInstallation {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        try await family.store.connect()
        let guestTransport = TestTransport(server: server, account: "guest")
        let guest = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                       transport: guestTransport,
                                       clock: { family.clock.now }, automaticSync: false)
        let location = try XCTUnwrap(family.store.session.location)
        try await guest.join(url: URL(string: "https://test.invalid/\(location.zoneName)")!)
        try guest.requestProfiles([family.parent.id, family.hanna.id], deviceName: "Family iPad")
        try await guest.synchronize()
        try await family.store.synchronize()
        try family.store.approve(try XCTUnwrap(family.store.pendingRequests.first),
                                 memberIDs: [family.parent.id, family.hanna.id])
        try await family.store.synchronize()
        try await guest.synchronize()
        try guest.selectProfile(family.parent.id)
        return (family, server, guest)
    }
}

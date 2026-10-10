import CloudKit
import XCTest
@testable import EarnedIt

@MainActor
final class ParentChoreControlsTests: XCTestCase {
    func testWithdrawAndTwoSameDayOccurrencesRemainDistinctAcrossRelaunchAllowanceAndStreak() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "EarnedItOccurrences-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let family = try TestFamily(url: directory.appending(path: "journal.store"))
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Unload dishwasher", mode: .particular,
            memberIDs: [family.hanna.id], schedulingMode: .asNeeded
        )

        try family.store.activateAsNeededChore(choreID: chore)
        let withdrawnID = try XCTUnwrap(family.store.dailyList().first { $0.choreID == chore }?.occurrenceID)
        try family.store.withdrawAsNeededOccurrence(choreID: chore, occurrenceID: withdrawnID)
        XCTAssertTrue(family.store.dailyList().allSatisfy { $0.choreID != chore })

        for _ in 0..<2 {
            try family.store.activateAsNeededChore(choreID: chore)
            let row = try XCTUnwrap(family.store.dailyList().first {
                $0.choreID == chore && $0.isActionableOccurrence
            })
            try family.store.setCompletion(choreID: chore, occurrenceID: row.occurrenceID,
                                           memberID: family.hanna.id, date: family.clock.now,
                                           state: .done)
        }

        let completed = family.store.dailyList().filter { $0.choreID == chore }
        XCTAssertEqual(completed.count, 2)
        XCTAssertEqual(Set(completed.compactMap(\.occurrenceID)).count, 2)
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id).items.filter {
            $0.choreID == chore
        }.count, 2)
        XCTAssertEqual(MetricsService.streak(childID: family.hanna.id,
                                             snapshot: family.store.snapshot,
                                             today: family.clock.now), 1)

        let reopened = try HouseholdStore(repository: family.repository,
                                           clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.dailyList().filter { $0.choreID == chore }.count, 2)
        XCTAssertEqual(reopened.allowanceWeek(for: family.hanna.id).items.filter {
            $0.choreID == chore
        }.count, 2)
    }

    func testThreeChildCompletionWithdrawalAndSkipAdvanceExactlyOnce() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Empty dishwasher", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id, nora.id], schedulingMode: .asNeeded
        )
        let order = try XCTUnwrap(family.store.snapshot.configuration(
            choreID: chore, on: family.store.day
        )).memberIDs

        try family.store.activateAsNeededChore(choreID: chore)
        var row = try XCTUnwrap(family.store.dailyList().first { $0.choreID == chore && $0.isActionableOccurrence })
        XCTAssertEqual(row.turnOwnerID, order[0])
        try family.store.setCompletion(choreID: chore, occurrenceID: row.occurrenceID,
                                       memberID: order[0], date: family.clock.now, state: .done)

        try family.store.activateAsNeededChore(choreID: chore)
        row = try XCTUnwrap(family.store.dailyList().first { $0.choreID == chore && $0.isActionableOccurrence })
        XCTAssertEqual(row.turnOwnerID, order[1])
        try family.store.withdrawAsNeededOccurrence(choreID: chore, occurrenceID: try XCTUnwrap(row.occurrenceID))
        XCTAssertEqual(family.store.nextAlternatingOwner(choreID: chore)?.id, order[1])

        try family.store.activateAsNeededChore(choreID: chore)
        row = try XCTUnwrap(family.store.dailyList().first { $0.choreID == chore && $0.isActionableOccurrence })
        XCTAssertEqual(row.turnOwnerID, order[1])
        try family.store.setCompletion(choreID: chore, occurrenceID: row.occurrenceID,
                                       memberID: order[1], date: family.clock.now, state: .done)
        XCTAssertEqual(family.store.nextAlternatingOwner(choreID: chore)?.id, order[2])

        try family.store.skipNextAlternatingChild(choreID: chore)
        XCTAssertEqual(family.store.nextAlternatingOwner(choreID: chore)?.id, order[0])
        XCTAssertEqual(family.store.allowanceWeek(for: order[2]).items.filter {
            $0.choreID == chore
        }.count, 0)
    }

    func testEarlierCorrectionRemovesCreditWithoutReassigningLaterTurns() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Take bins out", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id, nora.id], schedulingMode: .asNeeded
        )
        let order = try XCTUnwrap(family.store.snapshot.configuration(
            choreID: chore, on: family.store.day
        )).memberIDs
        var completedOccurrenceIDs: [UUID] = []
        for owner in order.prefix(2) {
            try family.store.activateAsNeededChore(choreID: chore)
            let row = try XCTUnwrap(family.store.dailyList().first {
                $0.choreID == chore && $0.isActionableOccurrence
            })
            completedOccurrenceIDs.append(try XCTUnwrap(row.occurrenceID))
            try family.store.setCompletion(choreID: chore, occurrenceID: row.occurrenceID,
                                           memberID: owner, date: family.clock.now, state: .done)
        }

        try family.store.setCompletion(choreID: chore, occurrenceID: completedOccurrenceIDs[0],
                                       memberID: order[0], date: family.clock.now, state: .unmarked)
        let corrected = try XCTUnwrap(family.store.dailyList().first {
            $0.occurrenceID == completedOccurrenceIDs[0]
        })
        XCTAssertEqual(corrected.state(for: order[0]), .missed)
        XCTAssertEqual(family.store.nextAlternatingOwner(choreID: chore)?.id, order[2])
        XCTAssertFalse(family.store.allowanceWeek(for: order[0]).items.contains {
            $0.occurrenceID == completedOccurrenceIDs[0] && $0.state == .done
        })

        try family.store.setCompletion(choreID: chore, occurrenceID: completedOccurrenceIDs[1],
                                       memberID: order[1], date: family.clock.now, state: .unmarked)
        XCTAssertEqual(family.store.dailyList().first {
            $0.occurrenceID == completedOccurrenceIDs[1]
        }?.asNeededStatus, .open)
        XCTAssertEqual(family.store.nextAlternatingOwner(choreID: chore)?.id, order[1])
    }

    func testPastCompletionCorrectionRemovesCreditWithoutReopeningOrReturningTurn() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Take recycling out", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id], schedulingMode: .asNeeded
        )
        let order = try XCTUnwrap(family.store.snapshot.configuration(
            choreID: chore, on: family.store.day
        )).memberIDs
        let completionDate = family.clock.now
        try family.store.activateAsNeededChore(choreID: chore)
        let occurrenceID = try XCTUnwrap(family.store.dailyList().first {
            $0.choreID == chore
        }?.occurrenceID)
        try family.store.setCompletion(choreID: chore, occurrenceID: occurrenceID,
                                       memberID: order[0], date: completionDate, state: .done)

        family.move(to: "2026-09-08T16:00:00Z")
        try family.store.setCompletion(choreID: chore, occurrenceID: occurrenceID,
                                       memberID: order[0], date: completionDate, state: .unmarked)

        let corrected = try XCTUnwrap(family.store.dailyList(on: completionDate).first {
            $0.occurrenceID == occurrenceID
        })
        XCTAssertEqual(corrected.state(for: order[0]), .missed)
        XCTAssertEqual(corrected.asNeededStatus, .completed)
        XCTAssertEqual(family.store.nextAlternatingOwner(choreID: chore)?.id, order[1])
        XCTAssertFalse(family.store.allowanceWeek(for: order[0]).items.contains {
            $0.occurrenceID == occurrenceID && $0.state == .done
        })
    }

    func testPartialAllChildOccurrenceMustBeCorrectedBeforeWithdrawal() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Clear yard", mode: .all,
            memberIDs: [], schedulingMode: .asNeeded
        )
        try family.store.activateAsNeededChore(choreID: chore)
        let occurrenceID = try XCTUnwrap(family.store.dailyList().first {
            $0.choreID == chore
        }?.occurrenceID)
        try family.store.setCompletion(choreID: chore, occurrenceID: occurrenceID,
                                       memberID: family.hanna.id, date: family.clock.now, state: .done)
        XCTAssertThrowsError(try family.store.withdrawAsNeededOccurrence(
            choreID: chore, occurrenceID: occurrenceID
        ))
        try family.store.setCompletion(choreID: chore, occurrenceID: occurrenceID,
                                       memberID: family.hanna.id, date: family.clock.now, state: .unmarked)
        try family.store.withdrawAsNeededOccurrence(choreID: chore, occurrenceID: occurrenceID)
        XCTAssertTrue(family.store.dailyList().allSatisfy { $0.choreID != chore })
    }

    func testPastOpenOccurrenceCanBeWithdrawnBeforeReopeningToday() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Put away games", mode: .particular,
            memberIDs: [family.hanna.id], schedulingMode: .asNeeded
        )
        try family.store.activateAsNeededChore(choreID: chore)
        let priorOccurrenceID = try XCTUnwrap(family.store.dailyList().first {
            $0.choreID == chore
        }?.occurrenceID)

        family.move(to: "2026-09-08T16:00:00Z")
        try family.store.withdrawAsNeededOccurrence(choreID: chore, occurrenceID: priorOccurrenceID)
        XCTAssertTrue(family.store.allowanceWeek(for: family.hanna.id).items.allSatisfy {
            $0.occurrenceID != priorOccurrenceID
        })
        try family.store.activateAsNeededChore(choreID: chore)
        let reopened = try XCTUnwrap(family.store.dailyList().first { $0.choreID == chore })
        XCTAssertNotEqual(reopened.occurrenceID, priorOccurrenceID)
        XCTAssertEqual(reopened.day, family.store.day)
    }

    func testConcurrentOpenAndCompletionWithdrawalRaceConvergeForEveryDeliveryOrder() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Bring in packages", mode: .particular,
            memberIDs: [family.hanna.id], schedulingMode: .asNeeded
        )
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        let base = try family.repository.facts(householdID: revision.householdID)
        let sequence = try XCTUnwrap(base.map(\.sequence).max())
        let capability = HouseholdFact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            householdID: revision.householdID, sequence: sequence + 1,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .journalCapability(JournalCapability(
                minimumVersion: JournalCapability.occurrenceAwareChores,
                recordedByMemberID: family.parent.id
            ))
        )
        let acceptedOccurrenceID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let rejectedOccurrenceID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFF0")!
        func openFact(id: UUID, occurrenceID: UUID) -> HouseholdFact {
            HouseholdFact(
                id: id, householdID: revision.householdID, sequence: sequence + 2,
                authorDeviceID: UUID(), authorMemberID: family.parent.id,
                body: .asNeededOccurrence(AsNeededOccurrence(
                    id: occurrenceID, choreID: chore, revisionID: revision.id,
                    day: family.store.day, eligibleMemberIDs: [family.hanna.id],
                    requiredMemberIDs: [family.hanna.id], assignedMemberID: nil,
                    expectedControlHeadID: nil, recordedByMemberID: family.parent.id
                ))
            )
        }
        let acceptedOpen = openFact(id: acceptedOccurrenceID, occurrenceID: acceptedOccurrenceID)
        let rejectedOpen = openFact(id: rejectedOccurrenceID, occurrenceID: rejectedOccurrenceID)
        let withdrawal = HouseholdFact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
            householdID: revision.householdID, sequence: sequence + 3,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .asNeededOccurrenceResolution(AsNeededOccurrenceResolution(
                occurrenceID: acceptedOccurrenceID, choreID: chore, revisionID: revision.id,
                day: family.store.day, state: .withdrawn,
                expectedControlHeadID: acceptedOpen.id, recordedByMemberID: family.parent.id
            ))
        )
        let completion = HouseholdFact(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFF1")!,
            householdID: revision.householdID, sequence: sequence + 3,
            authorDeviceID: UUID(), authorMemberID: family.hanna.id,
            body: .asNeededOccurrenceCompletion(AsNeededOccurrenceCompletion(
                occurrenceID: acceptedOccurrenceID, choreID: chore, revisionID: revision.id,
                memberID: family.hanna.id, day: family.store.day, state: .done,
                eligibleMemberIDs: [family.hanna.id], mode: .particular,
                recordedByMemberID: family.hanna.id
            ))
        )
        let concurrent = [capability, acceptedOpen, rejectedOpen, withdrawal, completion]
        let permutations = [concurrent, Array(concurrent.reversed()),
                            [completion, rejectedOpen, withdrawal, acceptedOpen, capability]]

        for delivery in permutations {
            let snapshot = HouseholdSnapshot(facts: base + delivery)
            let projection = snapshot.asNeededProjection(choreID: chore, through: family.store.day)
            XCTAssertEqual(projection.occurrences.count, 1)
            XCTAssertEqual(projection.occurrences.first?.id, acceptedOccurrenceID)
            XCTAssertEqual(projection.occurrences.first?.status, .completed)
        }
    }

    func testStaleExpectedOwnerFactsRemainAuditOnlyWithoutConsumingControlHead() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Move laundry", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id], schedulingMode: .asNeeded
        )
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        let order = revision.memberIDs
        let eligible = ChoreRules.eligibleMembers(
            for: revision, on: family.store.day, snapshot: family.store.snapshot
        ).map(\.id)
        let base = try family.repository.facts(householdID: revision.householdID)
        let sequence = try XCTUnwrap(base.map(\.sequence).max())
        let capability = HouseholdFact(
            id: UUID(), householdID: revision.householdID, sequence: sequence + 1,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .journalCapability(JournalCapability(
                minimumVersion: JournalCapability.occurrenceAwareChores,
                recordedByMemberID: family.parent.id
            ))
        )
        let staleSkip = HouseholdFact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            householdID: revision.householdID, sequence: sequence + 2,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .asNeededTurnAdvance(AsNeededTurnAdvance(
                choreID: chore, revisionID: revision.id, expectedMemberID: order[1],
                day: family.store.day, expectedControlHeadID: nil,
                recordedByMemberID: family.parent.id
            ))
        )
        let acceptedSkip = HouseholdFact(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFF0")!,
            householdID: revision.householdID, sequence: sequence + 2,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .asNeededTurnAdvance(AsNeededTurnAdvance(
                choreID: chore, revisionID: revision.id, expectedMemberID: order[0],
                day: family.store.day, expectedControlHeadID: nil,
                recordedByMemberID: family.parent.id
            ))
        )
        let staleOccurrenceID = UUID()
        let staleOpen = HouseholdFact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
            householdID: revision.householdID, sequence: sequence + 3,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .asNeededOccurrence(AsNeededOccurrence(
                id: staleOccurrenceID, choreID: chore, revisionID: revision.id,
                day: family.store.day, eligibleMemberIDs: eligible, requiredMemberIDs: [order[0]],
                assignedMemberID: order[0], expectedControlHeadID: acceptedSkip.id,
                recordedByMemberID: family.parent.id
            ))
        )
        let acceptedOccurrenceID = UUID()
        let acceptedOpen = HouseholdFact(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFF1")!,
            householdID: revision.householdID, sequence: sequence + 3,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .asNeededOccurrence(AsNeededOccurrence(
                id: acceptedOccurrenceID, choreID: chore, revisionID: revision.id,
                day: family.store.day, eligibleMemberIDs: eligible, requiredMemberIDs: [order[1]],
                assignedMemberID: order[1], expectedControlHeadID: acceptedSkip.id,
                recordedByMemberID: family.parent.id
            ))
        )

        let facts = base + [acceptedOpen, staleOpen, staleSkip, capability, acceptedSkip]
        let snapshot = HouseholdSnapshot(facts: facts)
        let projection = snapshot.asNeededProjection(choreID: chore, through: family.store.day)
        XCTAssertEqual(projection.turnAdvances.map(\.factID), [acceptedSkip.id])
        XCTAssertEqual(projection.occurrences.map(\.id), [acceptedOccurrenceID])
        XCTAssertEqual(projection.openOccurrence?.assignedMemberID, order[1])
        XCTAssertEqual(projection.controlHeadID, acceptedOpen.id)
    }

    func testScheduledDoneDominatesNotNeededAndCurrentDayRequirementCanBeRestored() throws {
        let family = try TestFamily()
        let doneChore = try family.store.saveChore(
            weekday: .monday, title: "Feed cat", mode: .particular,
            memberIDs: [family.hanna.id]
        )
        try family.complete(doneChore, as: family.hanna)
        try family.store.selectProfile(family.parent.id)
        XCTAssertThrowsError(try family.store.markOccurrenceNotNeeded(
            choreID: doneChore, date: family.clock.now
        ))

        let restoredChore = try family.store.saveChore(
            weekday: .monday, title: "Sweep", mode: .particular,
            memberIDs: [family.hanna.id]
        )
        try family.store.markOccurrenceNotNeeded(choreID: restoredChore, date: family.clock.now)
        XCTAssertTrue(family.store.dailyList().first { $0.choreID == restoredChore }?.isNotNeeded == true)
        try family.store.restoreScheduledRequirement(choreID: restoredChore, date: family.clock.now)
        let restored = try XCTUnwrap(family.store.dailyList().first { $0.choreID == restoredChore })
        XCTAssertFalse(restored.isNotNeeded)
        XCTAssertTrue(restored.isActionableOccurrence)
    }

    func testFutureCapabilityRequiresUpdateAndPreventsWrites() throws {
        let family = try TestFamily()
        let scheduled = try family.store.saveChore(
            weekday: .monday, title: "Feed fish", mode: .particular,
            memberIDs: [family.hanna.id]
        )
        let householdID = try XCTUnwrap(family.store.household?.id)
        let existing = try family.repository.facts(householdID: householdID)
        let future = HouseholdFact(
            id: UUID(), householdID: householdID,
            sequence: try XCTUnwrap(existing.map(\.sequence).max()) + 1,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .journalCapability(JournalCapability(
                minimumVersion: HouseholdStore.supportedJournalCapability + 1,
                recordedByMemberID: family.parent.id
            ))
        )
        try family.repository.commit(facts: [future], uploaded: true)
        let reopened = try HouseholdStore(repository: family.repository,
                                           clock: { family.clock.now }, automaticSync: false)
        XCTAssertTrue(reopened.requiresAppUpdate)
        XCTAssertThrowsError(try reopened.saveMember(name: "Blocked", role: .child, avatar: .star)) {
            XCTAssertEqual($0 as? HouseholdError, .updateRequired)
        }
        XCTAssertThrowsError(try reopened.markOccurrenceNotNeeded(
            choreID: scheduled, date: family.clock.now
        )) {
            XCTAssertEqual($0 as? HouseholdError, .updateRequired)
        }
    }

    func testRemoteFutureCapabilityImportsBeforePendingLegacyWriteCanUpload() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        try await family.store.connect()
        _ = try family.store.saveChore(
            weekday: .monday, title: "Pending legacy chore", mode: .particular,
            memberIDs: [family.hanna.id]
        )
        let householdID = try XCTUnwrap(family.store.household?.id)
        let location = try XCTUnwrap(family.store.session.location)
        let pendingIDs = Set(try family.repository.pending(householdID: householdID).map(\.id))
        XCTAssertFalse(pendingIDs.isEmpty)
        let remoteFacts = try XCTUnwrap(server.zones[location.zoneName]).facts.values
        let future = HouseholdFact(
            id: UUID(), householdID: householdID,
            sequence: try XCTUnwrap(remoteFacts.map(\.sequence).max()) + 1,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .journalCapability(JournalCapability(
                minimumVersion: HouseholdStore.supportedJournalCapability + 1,
                recordedByMemberID: family.parent.id
            ))
        )
        server.zones[location.zoneName]?.facts[future.id] = future

        do {
            try await family.store.synchronize()
            XCTFail("Expected the imported capability to require an update")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .updateRequired)
        }
        XCTAssertTrue(family.store.requiresAppUpdate)
        let uploadedIDs = Set(try XCTUnwrap(server.zones[location.zoneName]).facts.keys)
        XCTAssertTrue(pendingIDs.isDisjoint(with: uploadedIDs))
    }

    func testFutureCloudEnvelopeRequiresUpdateAndBlocksWrites() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: transport)
        try await family.store.connect()
        transport.fetchError = HouseholdError.updateRequired

        do {
            try await family.store.synchronize()
            XCTFail("Expected the newer cloud envelope to require an update")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .updateRequired)
        }

        XCTAssertTrue(family.store.requiresAppUpdate)
        XCTAssertThrowsError(try family.store.saveMember(
            name: "Blocked", role: .child, avatar: .star
        )) {
            XCTAssertEqual($0 as? HouseholdError, .updateRequired)
        }
    }

    func testCloudEnvelopeVersionMakesOccurrenceFactsFailClosedForLegacyClients() async throws {
        let householdID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let choreID = UUID()
        let revisionID = UUID()
        let location = CloudLocation(
            householdID: householdID, zoneName: "EarnedIt-\(householdID.uuidString)",
            ownerName: "owner", isOwner: true
        )
        let legacy = HouseholdFact(
            id: UUID(), householdID: householdID, sequence: 1,
            authorDeviceID: UUID(), authorMemberID: childID,
            body: .completion(DatedCompletion(
                choreID: choreID, revisionID: revisionID, memberID: childID,
                day: CivilDay(rawValue: "2026-09-07")!, state: .done,
                eligibleMemberIDs: [childID], mode: .particular,
                recordedByMemberID: childID
            ))
        )
        let capability = HouseholdFact(
            id: UUID(), householdID: householdID, sequence: 2,
            authorDeviceID: UUID(), authorMemberID: parentID,
            body: .journalCapability(JournalCapability(
                minimumVersion: JournalCapability.occurrenceAwareChores,
                recordedByMemberID: parentID
            ))
        )
        let occurrence = HouseholdFact(
            id: UUID(), householdID: householdID, sequence: 3,
            authorDeviceID: UUID(), authorMemberID: parentID,
            body: .asNeededOccurrence(AsNeededOccurrence(
                id: UUID(), choreID: choreID, revisionID: revisionID,
                day: CivilDay(rawValue: "2026-09-07")!, eligibleMemberIDs: [childID],
                requiredMemberIDs: [childID], assignedMemberID: nil,
                expectedControlHeadID: nil, recordedByMemberID: parentID
            ))
        )
        var versions: [UUID: Int] = [:]
        try await CloudKitHouseholdTransport.uploadConfirmed(
            [occurrence, legacy, capability], to: location
        ) { record in
            versions[try XCTUnwrap(UUID(uuidString: record.recordID.recordName))] = try XCTUnwrap(
                record["formatVersion"] as? Int
            )
            return record
        }

        XCTAssertEqual(versions[legacy.id], 1)
        XCTAssertEqual(versions[capability.id], 2)
        XCTAssertEqual(versions[occurrence.id], 2)
    }

    func testCodableAndMixedLegacyJournalRequireCapabilityWithoutLosingHistory() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Collect laundry", mode: .particular,
            memberIDs: [family.hanna.id], schedulingMode: .asNeeded
        )
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        let base = try family.repository.facts(householdID: revision.householdID)
        let sequence = try XCTUnwrap(base.map(\.sequence).max())
        let legacyOpen = HouseholdFact(
            id: UUID(), householdID: revision.householdID, sequence: sequence + 1,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .occurrence(ChoreOccurrenceDisposition(
                choreID: chore, revisionID: revision.id, day: family.store.day,
                state: .available, alternatingSkipBehavior: nil,
                recordedByMemberID: family.parent.id
            ))
        )
        let legacyCompletion = HouseholdFact(
            id: UUID(), householdID: revision.householdID, sequence: sequence + 2,
            authorDeviceID: UUID(), authorMemberID: family.hanna.id,
            body: .completion(DatedCompletion(
                choreID: chore, revisionID: revision.id, memberID: family.hanna.id,
                day: family.store.day, state: .done, eligibleMemberIDs: [family.hanna.id],
                mode: .particular, recordedByMemberID: family.hanna.id
            ))
        )
        let capability = HouseholdFact(
            id: UUID(), householdID: revision.householdID, sequence: sequence + 3,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .journalCapability(JournalCapability(
                minimumVersion: JournalCapability.occurrenceAwareChores,
                recordedByMemberID: family.parent.id
            ))
        )
        let occurrenceID = UUID()
        let occurrence = HouseholdFact(
            id: UUID(), householdID: revision.householdID, sequence: sequence + 4,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .asNeededOccurrence(AsNeededOccurrence(
                id: occurrenceID, choreID: chore, revisionID: revision.id,
                day: family.store.day, eligibleMemberIDs: [family.hanna.id],
                requiredMemberIDs: [family.hanna.id], assignedMemberID: nil,
                expectedControlHeadID: legacyCompletion.id, recordedByMemberID: family.parent.id
            ))
        )
        let completion = HouseholdFact(
            id: UUID(), householdID: revision.householdID, sequence: sequence + 5,
            authorDeviceID: UUID(), authorMemberID: family.hanna.id,
            body: .asNeededOccurrenceCompletion(AsNeededOccurrenceCompletion(
                occurrenceID: occurrenceID, choreID: chore, revisionID: revision.id,
                memberID: family.hanna.id, day: family.store.day, state: .done,
                eligibleMemberIDs: [family.hanna.id], mode: .particular,
                recordedByMemberID: family.hanna.id
            ))
        )
        let mixed = base + [legacyOpen, legacyCompletion, capability, occurrence, completion]
        let encoded = try JSONEncoder().encode(completion)
        XCTAssertEqual(try JSONDecoder().decode(HouseholdFact.self, from: encoded), completion)
        XCTAssertThrowsError(try JSONDecoder().decode(LegacyHouseholdFact.self, from: encoded))

        let snapshot = HouseholdSnapshot(facts: mixed)
        let rows = ChoreRules.dailyList(snapshot: snapshot, day: family.store.day, today: family.store.day)
            .filter { $0.choreID == chore }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.state(for: family.hanna.id) == .done })
    }

    func testChildCompletesLegacyOccurrenceWithoutEnablingNewJournalCapability() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Legacy open chore", mode: .particular,
            memberIDs: [family.hanna.id], schedulingMode: .asNeeded
        )
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        let base = try family.repository.facts(householdID: revision.householdID)
        let legacyOpen = HouseholdFact(
            id: UUID(), householdID: revision.householdID,
            sequence: try XCTUnwrap(base.map(\.sequence).max()) + 1,
            authorDeviceID: UUID(), authorMemberID: family.parent.id,
            body: .occurrence(ChoreOccurrenceDisposition(
                choreID: chore, revisionID: revision.id, day: family.store.day,
                state: .available, alternatingSkipBehavior: nil,
                recordedByMemberID: family.parent.id
            ))
        )
        try family.repository.commit(facts: [legacyOpen], uploaded: true)
        let upgraded = try HouseholdStore(
            repository: family.repository, clock: { family.clock.now }, automaticSync: false
        )
        try upgraded.selectProfile(family.hanna.id)
        try upgraded.setCompletion(choreID: chore, memberID: family.hanna.id,
                                   date: family.clock.now, state: .done)

        let facts = try family.repository.facts(householdID: revision.householdID)
        XCTAssertFalse(facts.contains {
            if case .journalCapability = $0.body { return true }
            return false
        })
        XCTAssertFalse(facts.contains {
            if case .asNeededOccurrenceCompletion = $0.body { return true }
            return false
        })
        XCTAssertEqual(upgraded.dailyList().first { $0.choreID == chore }?
            .state(for: family.hanna.id), .done)
    }

    func testDeletingMultipleOccurrencesRetainsResolvedRowsAndDropsOpenWork() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Tidy entry", mode: .particular,
            memberIDs: [family.hanna.id], schedulingMode: .asNeeded
        )
        for _ in 0..<2 {
            try family.store.activateAsNeededChore(choreID: chore)
            let row = try XCTUnwrap(family.store.dailyList().first {
                $0.choreID == chore && $0.isActionableOccurrence
            })
            try family.store.setCompletion(choreID: chore, occurrenceID: row.occurrenceID,
                                           memberID: family.hanna.id, date: family.clock.now,
                                           state: .done)
        }
        try family.store.activateAsNeededChore(choreID: chore)
        try family.store.deleteChore(chore)

        let retained = family.store.dailyList().filter { $0.choreID == chore }
        XCTAssertEqual(retained.count, 2)
        XCTAssertTrue(retained.allSatisfy { $0.isDeleted && $0.state(for: family.hanna.id) == .done })
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id).items.filter {
            $0.choreID == chore
        }.count, 2)
        XCTAssertThrowsError(try family.store.activateAsNeededChore(choreID: chore))
    }
}

private struct LegacyHouseholdFact: Codable {
    let id: UUID
    let householdID: UUID
    let sequence: Int64
    let authorDeviceID: UUID
    let authorMemberID: UUID?
    let body: LegacyHouseholdFactBody
}

private enum LegacyHouseholdFactBody: Codable {
    case household(Household)
    case member(FamilyMember)
    case chore(ChoreRevision)
    case completion(DatedCompletion)
    case occurrence(ChoreOccurrenceDisposition)
    case alternatingTurnAdvance(AlternatingTurnAdvance)
    case choreDeletion(ChoreDeletion)
    case allowance(AllowanceRevision)
    case excuse(Excuse)
    case request(ProfileRequest)
    case grant(ProfileGrant)
    case invitation(FamilyInvitation)
    case invitationClaim(InvitationClaim)
    case invitationRevocation(InvitationRevocation)
}

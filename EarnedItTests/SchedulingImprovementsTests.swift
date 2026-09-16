import XCTest
import SwiftData
@testable import EarnedIt

@MainActor
final class SchedulingImprovementsTests: XCTestCase {
    func testAsNeededActivationCompletionReactivationPersistenceAndAllowanceCredit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "EarnedItAsNeeded-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let family = try TestFamily(url: directory.appending(path: "journal.store"))
        let scheduled = try family.store.saveChore(
            weekday: .monday, title: "Set table", mode: .particular, memberIDs: [family.alek.id]
        )
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Unload dishwasher", mode: .particular,
            memberIDs: [family.hanna.id], schedulingMode: .asNeeded
        )

        XCTAssertFalse(family.store.dailyList().contains { $0.id == chore })
        try family.store.activateAsNeededChore(choreID: chore)
        XCTAssertThrowsError(try family.store.activateAsNeededChore(choreID: chore)) {
            XCTAssertEqual($0 as? HouseholdError, .unavailableDay)
        }
        try family.store.markOccurrenceNotNeeded(choreID: scheduled, date: family.clock.now)
        XCTAssertEqual(family.store.dailyList().first { $0.id == chore }?.requiredMembers.map(\.id), [family.hanna.id])
        try family.complete(chore, as: family.hanna)
        XCTAssertEqual(family.store.allowanceWeek(for: family.hanna.id).accountedCount, 1)

        let reopened = try HouseholdStore(repository: family.repository,
                                           clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.dailyList().first { $0.id == chore }?.state(for: family.hanna.id), .done)
        XCTAssertTrue(reopened.dailyList().first { $0.id == scheduled }?.isNotNeeded == true)
        XCTAssertFalse(reopened.allowanceWeek(for: family.alek.id).items.contains { $0.choreID == scheduled })

        family.clock.set("2026-09-14T16:00:00Z")
        reopened.refreshDate()
        try reopened.selectProfile(family.parent.id)
        XCTAssertFalse(reopened.dailyList().contains { $0.id == chore })
        try reopened.activateAsNeededChore(choreID: chore)
        XCTAssertEqual(reopened.dailyList().first { $0.id == chore }?.state(for: family.hanna.id), .unmarked)
        try reopened.selectProfile(family.hanna.id)
        try reopened.setCompletion(choreID: chore, memberID: family.hanna.id,
                                   date: family.clock.now, state: .done)
        XCTAssertEqual(reopened.allowanceWeek(for: family.hanna.id).accountedCount, 1)
    }

    func testOccurrenceNotNeededIsNeutralAndFutureRecurrenceRemains() throws {
        let family = try TestFamily()
        let completed = try family.store.saveChore(weekday: .monday, title: "Completed",
                                                   mode: .particular, memberIDs: [family.hanna.id])
        let skipped = try family.store.saveChore(weekday: .monday, title: "Skipped",
                                                 mode: .particular, memberIDs: [family.hanna.id])
        try family.complete(completed, as: family.hanna)
        try family.store.selectProfile(family.parent.id)
        try family.store.markOccurrenceNotNeeded(choreID: skipped, date: family.clock.now)
        XCTAssertThrowsError(try family.store.setCompletion(choreID: skipped, memberID: family.hanna.id,
                                                             date: family.clock.now, state: .done))
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: skipped, on: family.store.day))
        let facts = try family.repository.facts(householdID: family.store.household!.id)
        let staleCompletion = HouseholdFact(
            id: UUID(), householdID: family.store.household!.id,
            sequence: try XCTUnwrap(facts.map(\.sequence).max()) + 1,
            authorDeviceID: UUID(), authorMemberID: family.hanna.id,
            body: .completion(DatedCompletion(
                choreID: skipped, revisionID: revision.id, memberID: family.hanna.id,
                day: family.store.day, state: .done, eligibleMemberIDs: [family.hanna.id],
                mode: .particular, recordedByMemberID: family.hanna.id
            ))
        )
        let reconciled = HouseholdSnapshot(facts: facts + [staleCompletion])
        XCTAssertTrue(ChoreRules.dailyList(snapshot: reconciled, day: family.store.day,
                                           today: family.store.day).first { $0.id == skipped }?.isNotNeeded == true)
        XCTAssertFalse(AllowanceService.week(childID: family.hanna.id, containing: family.clock.now,
                                              snapshot: reconciled, today: family.clock.now)
            .items.contains { $0.choreID == skipped })

        let week = family.store.allowanceWeek(for: family.hanna.id)
        XCTAssertEqual(week.items.map(\.choreID), [completed])
        XCTAssertEqual(week.accountedCount, 1)
        XCTAssertEqual(week.dueCount, 1)
        let mondayFacts = family.store.weekFacts(for: family.hanna.id).first
        XCTAssertEqual(mondayFacts?.states, [.done])

        family.move(to: "2026-09-08T16:00:00Z")
        XCTAssertEqual(MetricsService.streak(childID: family.hanna.id, snapshot: family.store.snapshot,
                                             today: family.clock.now), 1)
        let nextMonday = ISO8601DateFormatter().date(from: "2026-09-14T16:00:00Z")!
        let future = try XCTUnwrap(family.store.dailyList(on: nextMonday).first { $0.id == skipped })
        XCTAssertFalse(future.isNotNeeded)
        XCTAssertEqual(future.state(for: family.hanna.id), .unmarked)
    }

    func testEditingScheduledChoreToAsNeededStartsTomorrow() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(weekday: .monday, title: "Dishes",
                                               mode: .particular, memberIDs: [family.hanna.id])
        try family.store.saveChore(choreID: chore, weekday: .monday, title: "Dishes",
                                   mode: .particular, memberIDs: [family.hanna.id],
                                   schedulingMode: .asNeeded)

        XCTAssertEqual(family.store.snapshot.configuration(choreID: chore, on: family.store.day)?.schedulingMode,
                       .scheduled)
        XCTAssertEqual(family.store.snapshot.configuration(choreID: chore, on: family.store.tomorrow)?.schedulingMode,
                       .asNeeded)
        XCTAssertTrue(family.store.dailyList().contains { $0.id == chore })
        family.move(to: "2026-09-08T16:00:00Z")
        XCTAssertFalse(family.store.dailyList().contains { $0.id == chore })
        try family.store.activateAsNeededChore(choreID: chore)
        XCTAssertTrue(family.store.dailyList().contains { $0.id == chore })
    }

    func testAsNeededCannotActivateAgainUntilOpenOccurrenceIsComplete() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Dishes", mode: .particular,
            memberIDs: [family.hanna.id], schedulingMode: .asNeeded
        )
        let firstDay = family.clock.now
        try family.store.activateAsNeededChore(choreID: chore)
        family.move(to: "2026-09-08T16:00:00Z")
        XCTAssertThrowsError(try family.store.activateAsNeededChore(choreID: chore)) {
            XCTAssertEqual($0 as? HouseholdError, .unavailableDay)
        }
        try family.store.setCompletion(choreID: chore, memberID: family.hanna.id,
                                       date: firstDay, state: .done)
        try family.store.activateAsNeededChore(choreID: chore)
        XCTAssertEqual(family.store.dailyList().first { $0.id == chore }?.state(for: family.hanna.id), .unmarked)
    }

    func testNotNeededOnlyDayNeitherExtendsNorBreaksStreak() throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(weekday: .monday, title: "Set table",
                                               mode: .particular, memberIDs: [family.hanna.id])
        try family.complete(chore, as: family.hanna)
        family.move(to: "2026-09-14T16:00:00Z")
        try family.store.selectProfile(family.parent.id)
        try family.store.markOccurrenceNotNeeded(choreID: chore, date: family.clock.now)

        XCTAssertTrue(family.store.weekFacts(for: family.hanna.id).allSatisfy(\.states.isEmpty))
        XCTAssertEqual(MetricsService.streak(childID: family.hanna.id, snapshot: family.store.snapshot,
                                             today: family.clock.now), 1)
    }

    func testAlternatingNotNeededKeepAndAdvanceWithThreeChildren() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Set table", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id, nora.id]
        )
        let order = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day)).memberIDs
        XCTAssertEqual(family.store.dailyList().first { $0.id == chore }?.turnOwnerID, order[0])

        try family.store.markOccurrenceNotNeeded(choreID: chore, date: family.clock.now,
                                                 alternatingSkipBehavior: .keepTurn)
        family.move(to: "2026-09-14T16:00:00Z")
        XCTAssertEqual(family.store.dailyList().first { $0.id == chore }?.turnOwnerID, order[0])

        try family.store.markOccurrenceNotNeeded(choreID: chore, date: family.clock.now,
                                                 alternatingSkipBehavior: .advanceRotation)
        family.move(to: "2026-09-21T16:00:00Z")
        XCTAssertEqual(family.store.dailyList().first { $0.id == chore }?.turnOwnerID, order[1])
    }

    func testAsNeededAlternatingActivationAdvancesAcrossThreeChildren() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Unload dishwasher", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id, nora.id], schedulingMode: .asNeeded
        )
        let order = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day)).memberIDs
        try family.store.activateAsNeededChore(choreID: chore)
        XCTAssertEqual(family.store.dailyList().first { $0.id == chore }?.turnOwnerID, order[0])
        try family.store.setCompletion(choreID: chore, memberID: order[0], date: family.clock.now, state: .done)

        family.move(to: "2026-09-08T16:00:00Z")
        try family.store.activateAsNeededChore(choreID: chore)
        XCTAssertEqual(family.store.dailyList().first { $0.id == chore }?.turnOwnerID, order[1])
        try family.store.setCompletion(choreID: chore, memberID: order[1], date: family.clock.now, state: .done)
        family.move(to: "2026-09-09T16:00:00Z")
        try family.store.activateAsNeededChore(choreID: chore)
        XCTAssertEqual(family.store.dailyList().first { $0.id == chore }?.turnOwnerID, order[2])
    }

    func testChildCannotMarkOccurrenceNotNeeded() throws {
        let family = try TestFamily()
        let chore = try family.chore(.particular, ids: [family.hanna.id])
        try family.store.selectProfile(family.hanna.id)
        XCTAssertThrowsError(try family.store.markOccurrenceNotNeeded(choreID: chore, date: family.clock.now)) {
            XCTAssertEqual($0 as? HouseholdError, .permission)
        }
    }

    func testConflictingAlternatingChoicesConvergeInEitherDeliveryOrder() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.store.saveChore(
            weekday: .monday, title: "Set table", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id, nora.id]
        )
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        let base = try family.repository.facts(householdID: family.store.household!.id)
        let sequence = try XCTUnwrap(base.map(\.sequence).max()) + 1
        let keep = HouseholdFact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            householdID: family.store.household!.id, sequence: sequence, authorDeviceID: UUID(),
            authorMemberID: family.parent.id,
            body: .occurrence(ChoreOccurrenceDisposition(
                choreID: chore, revisionID: revision.id, day: family.store.day, state: .notNeeded,
                alternatingSkipBehavior: .keepTurn, recordedByMemberID: family.parent.id
            ))
        )
        let advance = HouseholdFact(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            householdID: family.store.household!.id, sequence: sequence, authorDeviceID: UUID(),
            authorMemberID: family.parent.id,
            body: .occurrence(ChoreOccurrenceDisposition(
                choreID: chore, revisionID: revision.id, day: family.store.day, state: .notNeeded,
                alternatingSkipBehavior: .advanceRotation, recordedByMemberID: family.parent.id
            ))
        )
        let first = HouseholdSnapshot(facts: base + [keep, advance])
        let second = HouseholdSnapshot(facts: base + [advance, keep])
        let nextDay = CivilDay(rawValue: "2026-09-14")!
        let firstRow = ChoreRules.dailyList(snapshot: first, day: nextDay, today: nextDay).first { $0.id == chore }
        let secondRow = ChoreRules.dailyList(snapshot: second, day: nextDay, today: nextDay).first { $0.id == chore }

        XCTAssertEqual(first.occurrence(choreID: chore, on: family.store.day)?.alternatingSkipBehavior,
                       .advanceRotation)
        XCTAssertEqual(second.occurrenceDispositions, first.occurrenceDispositions)
        XCTAssertEqual(firstRow?.turnOwnerID, revision.memberIDs[1])
        XCTAssertEqual(secondRow?.turnOwnerID, firstRow?.turnOwnerID)
    }

    func testLegacyChoreRevisionWithoutSchedulingModeDefaultsToScheduled() throws {
        let family = try TestFamily()
        let chore = try family.chore(.particular, ids: [family.hanna.id])
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
        let encoded = try JSONEncoder().encode(revision)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "schedulingMode")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ChoreRevision.self, from: legacy)
        XCTAssertEqual(decoded.schedulingMode, .scheduled)
        XCTAssertEqual(decoded.choreID, revision.choreID)
    }

    func testLegacyStoredFactWithoutSchedulingModeReopensAsScheduled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "EarnedItLegacyScheduling-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "journal.store")
        let family = try TestFamily(url: url)
        let chore = try family.chore(.particular, ids: [family.hanna.id])
        let context = family.repository.container.mainContext
        let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<StoredFact>()).first { stored in
            guard let fact = try? stored.fact(), case .chore(let revision) = fact.body else { return false }
            return revision.choreID == chore
        })
        var factObject = try XCTUnwrap(JSONSerialization.jsonObject(with: stored.payload) as? [String: Any])
        var body = try XCTUnwrap(factObject["body"] as? [String: Any])
        var choreCase = try XCTUnwrap(body["chore"] as? [String: Any])
        var revision = try XCTUnwrap(choreCase["_0"] as? [String: Any])
        revision.removeValue(forKey: "schedulingMode")
        choreCase["_0"] = revision
        body["chore"] = choreCase
        factObject["body"] = body
        stored.payload = try JSONSerialization.data(withJSONObject: factObject)
        try context.save()

        let reopenedRepository = try HouseholdRepository(url: url)
        let reopened = try HouseholdStore(repository: reopenedRepository,
                                           clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.snapshot.configuration(choreID: chore, on: reopened.day)?.schedulingMode, .scheduled)
        XCTAssertTrue(reopened.dailyList().contains { $0.id == chore })
    }

    func testOccurrenceFactsSynchronizeAcrossStores() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let asNeeded = try family.store.saveChore(
            weekday: .monday, title: "Unload dishwasher", mode: .particular,
            memberIDs: [family.hanna.id], schedulingMode: .asNeeded
        )
        let scheduled = try family.store.saveChore(
            weekday: .monday, title: "Set table", mode: .particular,
            memberIDs: [family.hanna.id]
        )
        try await family.store.connect()

        let peer = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                      transport: TestTransport(server: server, account: "owner"),
                                      clock: { family.clock.now }, automaticSync: false)
        try await peer.joinExisting(family.store.session.location!)
        try peer.requestProfiles([family.parent.id], deviceName: "Other parent device")
        try await peer.synchronize()
        try await family.store.synchronize()
        try family.store.approve(XCTUnwrap(family.store.pendingRequests.first), memberIDs: [family.parent.id])
        try await family.store.synchronize()
        try await peer.synchronize()
        try peer.selectProfile(family.parent.id)

        try family.store.activateAsNeededChore(choreID: asNeeded)
        try family.store.setCompletion(choreID: asNeeded, memberID: family.hanna.id,
                                       date: family.clock.now, state: .done)
        try family.store.markOccurrenceNotNeeded(choreID: scheduled, date: family.clock.now)
        try await family.store.synchronize()
        try await peer.synchronize()

        XCTAssertEqual(peer.dailyList().first { $0.id == asNeeded }?.state(for: family.hanna.id), .done)
        XCTAssertTrue(peer.dailyList().first { $0.id == scheduled }?.isNotNeeded == true)
        XCTAssertEqual(peer.snapshot.occurrenceDispositions, family.store.snapshot.occurrenceDispositions)

        let alternating = try family.store.saveChore(
            weekday: .monday, title: "Clear table", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id]
        )
        try await family.store.synchronize()
        try await peer.synchronize()
        try family.store.markOccurrenceNotNeeded(choreID: alternating, date: family.clock.now,
                                                 alternatingSkipBehavior: .keepTurn)
        try peer.markOccurrenceNotNeeded(choreID: alternating, date: family.clock.now,
                                         alternatingSkipBehavior: .advanceRotation)
        try await family.store.synchronize()
        try await peer.synchronize()
        try await family.store.synchronize()

        XCTAssertEqual(peer.snapshot.occurrence(choreID: alternating, on: peer.day),
                       family.store.snapshot.occurrence(choreID: alternating, on: family.store.day))
        let nextMonday = ISO8601DateFormatter().date(from: "2026-09-14T16:00:00Z")!
        XCTAssertEqual(peer.dailyList(on: nextMonday).first { $0.id == alternating }?.turnOwnerID,
                       family.store.dailyList(on: nextMonday).first { $0.id == alternating }?.turnOwnerID)
    }
}

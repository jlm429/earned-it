import XCTest
@testable import EarnedIt

@MainActor
final class BusinessRulesTests: XCTestCase {
    func testNewChildImmediatelyJoinsExistingAllChoreWithoutChangingHistoryOrParticularAssignment() throws {
        let family = try TestFamily()
        let all = try family.chore()
        let particular = try family.chore(.particular, ids: [family.hanna.id])
        let previousMonday = family.clock.now
        try family.complete(all, as: family.hanna)
        family.move(to: "2026-09-14T16:00:00Z")
        try family.complete(all, as: family.alek)
        try family.store.selectProfile(family.parent.id)
        let completions = family.store.snapshot.completions
        let revisions = family.store.snapshot.revisions
        let child = try family.store.saveMember(name: "New Child", role: .child, avatar: .star)

        XCTAssertEqual(child.joinedDay, family.store.day)
        let row = try XCTUnwrap(family.store.dailyList().first { $0.id == all })
        XCTAssertEqual(Set(row.requiredMembers.map(\.id)), [family.hanna.id, family.alek.id, child.id])
        XCTAssertEqual(row.state(for: family.alek.id), .done)
        XCTAssertEqual(row.state(for: child.id), .unmarked)
        XCTAssertEqual(family.store.snapshot.completions, completions)
        XCTAssertEqual(family.store.snapshot.revisions, revisions)
        XCTAssertEqual(ChoreRules.visibleList(family.store.dailyList(), to: child).map(\.id), [all])
        XCTAssertEqual(family.store.dailyList().first { $0.id == particular }?.eligibleMembers.map(\.id), [family.hanna.id])
        XCTAssertFalse(family.store.dailyList(on: previousMonday).contains { $0.eligibleMembers.contains { $0.id == child.id } })
        XCTAssertEqual(family.store.dailyList(on: previousMonday).first { $0.id == all }?.state(for: family.hanna.id), .done)
        try family.store.selectProfile(child.id)
        try family.store.setCompletion(choreID: all, memberID: child.id, date: family.clock.now, state: .done)
        try family.store.setCompletion(choreID: all, memberID: child.id, date: family.clock.now, state: .unmarked)
        XCTAssertThrowsError(try family.store.setCompletion(choreID: all, memberID: family.alek.id, date: family.clock.now, state: .unmarked))
        XCTAssertThrowsError(try family.store.setCompletion(choreID: all, memberID: child.id, date: previousMonday, state: .done))
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.dailyList(), family.store.dailyList())
        XCTAssertEqual(reopened.dailyList().first { $0.id == all }?.state(for: family.alek.id), .done)
    }

    func testNewChildMembershipRespectsFutureStartsRecurrenceAndInactiveMembers() throws {
        let family = try TestFamily()
        let all = try family.chore()
        let tuesday = try family.chore(weekday: .tuesday)
        try family.store.archiveMember(family.alek.id)
        family.move(to: "2026-09-14T16:00:00Z")
        let child = try family.store.saveMember(name: "New Child", role: .child, avatar: .star)
        let future = ChoreRevision(id: UUID(), householdID: family.store.household!.id, choreID: UUID(),
                                   weekday: .monday, effectiveDay: CivilDay(rawValue: "2026-09-21")!,
                                   title: "Future chore", notes: "", category: .home, mode: .all, memberIDs: [], isArchived: false)
        let futureChild = FamilyMember(id: UUID(), householdID: family.store.household!.id, displayName: "Future Child",
                                       role: .child, avatar: .star, joinedDay: CivilDay(rawValue: "2026-09-21")!)
        let sequence = try family.repository.facts(householdID: family.store.household!.id).map(\.sequence).max()!
        let imported = [HouseholdFactBody.chore(future), .member(futureChild)].enumerated().map { index, body in
            HouseholdFact(id: UUID(), householdID: family.store.household!.id, sequence: sequence + Int64(index) + 1,
                          authorDeviceID: family.store.session.deviceID, authorMemberID: family.parent.id, body: body)
        }
        try family.repository.commit(facts: imported, uploaded: true)
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.dailyList().map(\.id), [all])
        XCTAssertEqual(Set(reopened.dailyList()[0].requiredMembers.map(\.id)), [family.hanna.id, child.id])
        XCTAssertFalse(reopened.profiles.contains { $0.id == futureChild.id || $0.id == family.alek.id })
        XCTAssertFalse(reopened.eligibleChildren(choreID: UUID()).contains { $0.id == futureChild.id || $0.id == family.alek.id })
        XCTAssertThrowsError(try reopened.setCompletion(choreID: future.choreID, memberID: child.id, date: family.clock.now, state: .done))
        family.clock.set("2026-09-15T16:00:00Z")
        reopened.refreshDate()
        XCTAssertEqual(reopened.dailyList().map(\.id), [tuesday])
        XCTAssertEqual(Set(reopened.dailyList()[0].requiredMembers.map(\.id)), [family.hanna.id, child.id])
        family.clock.set("2026-09-21T16:00:00Z")
        reopened.refreshDate()
        XCTAssertEqual(Set(reopened.dailyList().map(\.id)), [all, future.choreID])
        XCTAssertTrue(reopened.dailyList().allSatisfy { $0.requiredMembers.contains { $0.id == futureChild.id } })
    }

    func testChoreAssignmentChoicesAndSaveShareCreationAndEditDates() throws {
        let family = try TestFamily()
        XCTAssertEqual(RequirementMode.assignmentChoices, [.all, .particular, .alternating])
        let existing = try family.chore()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        try family.store.archiveMember(family.alek.id)
        let newID = UUID()
        XCTAssertEqual(family.store.choreAssignmentDay(choreID: newID), family.store.day)
        XCTAssertEqual(Set(family.store.eligibleChildren(choreID: newID).map(\.id)), [family.hanna.id, family.alek.id, nora.id])
        try family.store.saveChore(weekday: .monday, title: "Immediate assignment",
                                   mode: .particular, memberIDs: [nora.id])
        try family.store.saveChore(choreID: newID, weekday: .monday, title: "New chore",
                                   mode: .particular, memberIDs: [family.alek.id])
        let created = try XCTUnwrap(family.store.snapshot.configuration(choreID: newID, on: family.store.day))
        XCTAssertEqual(created.effectiveDay, family.store.day)
        XCTAssertEqual(created.memberIDs, [family.alek.id])

        XCTAssertEqual(family.store.choreAssignmentDay(choreID: existing), family.store.tomorrow)
        XCTAssertEqual(Set(family.store.eligibleChildren(choreID: existing).map(\.id)), [family.hanna.id, nora.id])
        XCTAssertThrowsError(try family.store.saveChore(choreID: existing, weekday: .monday, title: "Changed",
                                                      mode: .particular, memberIDs: [family.alek.id]))
        try family.store.saveChore(choreID: existing, weekday: .monday, title: "Changed",
                                   mode: .particular, memberIDs: [nora.id])
        let edited = try XCTUnwrap(family.store.snapshot.configuration(choreID: existing, on: family.store.tomorrow))
        XCTAssertEqual(edited.effectiveDay, family.store.tomorrow)
        XCTAssertEqual(edited.memberIDs, [nora.id])
        XCTAssertEqual(family.store.snapshot.configuration(choreID: existing, on: family.store.day)?.mode, .all)

        family.move(to: "2026-09-08T16:00:00Z")
        let nextNewID = UUID()
        XCTAssertEqual(Set(family.store.eligibleChildren(choreID: nextNewID).map(\.id)), [family.hanna.id, nora.id])
        try family.store.saveChore(choreID: nextNewID, weekday: .tuesday, title: "Today now includes Nora",
                                   mode: .particular, memberIDs: [nora.id])
        XCTAssertEqual(family.store.dailyList().first?.eligibleMembers.map(\.id), [nora.id])
    }

    func testSyncedTurnOrderMatchesDisplayedAndSavedOrder() throws {
        let family = try TestFamily()
        let id = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        let original = try XCTUnwrap(family.store.snapshot.configuration(choreID: id, on: family.store.day))
        let effectiveDay = family.store.tomorrow
        let syncedOrder = Array(original.memberIDs.reversed())
        let syncedRevision = ChoreRevision(id: UUID(), householdID: original.householdID, choreID: id,
                                           weekday: original.weekday, effectiveDay: effectiveDay,
                                           title: original.title, notes: original.notes,
                                           category: original.category, mode: .alternating,
                                           memberIDs: syncedOrder, isArchived: false)
        let sequence = try XCTUnwrap(family.repository.facts(householdID: original.householdID).map(\.sequence).max())
        let syncedFact = HouseholdFact(id: UUID(), householdID: original.householdID, sequence: sequence + 1,
                                       authorDeviceID: UUID(), authorMemberID: family.parent.id,
                                       body: .chore(syncedRevision))
        try family.repository.commit(facts: [syncedFact], uploaded: true)
        let syncedStore = try HouseholdStore(repository: family.repository,
                                              clock: { family.clock.now }, automaticSync: false)
        let selectedIDs = Set(original.memberIDs)
        let displayedOrder = syncedStore.orderedEligibleChildren(choreID: id,
                                                                 selectedMemberIDs: selectedIDs).map(\.id)

        XCTAssertEqual(displayedOrder, syncedOrder)
        try syncedStore.saveChore(choreID: id, weekday: original.weekday, title: "Synced turn order",
                                  mode: .alternating, memberIDs: Array(selectedIDs))
        let saved = try XCTUnwrap(syncedStore.snapshot.configuration(choreID: id, on: effectiveDay))
        XCTAssertEqual(saved.memberIDs, displayedOrder)
    }

    func testAlternatingOwnerAdvancesWrapsAndDoesNotFollowCompletion() throws {
        let family = try TestFamily()
        let id = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: id, on: family.store.day))
        let turnOrder = revision.memberIDs

        let first = try XCTUnwrap(family.store.dailyList().first)
        let firstOwner = try XCTUnwrap(first.turnOwner)
        XCTAssertEqual(first.turnOwner?.id, turnOrder[0])
        XCTAssertEqual(first.requiredMembers.map(\.id), [turnOrder[0]])
        XCTAssertEqual(first.turnLabel(for: family.parent), "\(firstOwner.displayName)’s turn")
        let otherChild = firstOwner.id == family.hanna.id ? family.alek : family.hanna
        XCTAssertEqual(first.turnLabel(for: firstOwner), "Your turn")
        XCTAssertEqual(ChoreRules.visibleList([first], to: firstOwner).map(\.id), [id])
        XCTAssertTrue(ChoreRules.visibleList([first], to: otherChild).isEmpty)

        try family.complete(id, as: firstOwner)
        let nextMonday = ISO8601DateFormatter().date(from: "2026-09-14T16:00:00Z")!
        let thirdMonday = ISO8601DateFormatter().date(from: "2026-09-21T16:00:00Z")!
        let second = try XCTUnwrap(family.store.dailyList(on: nextMonday).first)
        let third = try XCTUnwrap(family.store.dailyList(on: thirdMonday).first)
        XCTAssertEqual(second.turnOwner?.id, turnOrder[1])
        XCTAssertEqual(second.state(for: turnOrder[1]), .unmarked)
        XCTAssertEqual(third.turnOwner?.id, turnOrder[0])
        XCTAssertEqual(family.store.snapshot.completions.count, 1)
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.dailyList(on: nextMonday).first?.turnOwner?.id, turnOrder[1])
        XCTAssertEqual(reopened.dailyList(on: thirdMonday).first?.turnOwner?.id, turnOrder[0])
    }

    func testAlternatingRotationSurvivesUnrelatedRevisionEdits() throws {
        let family = try TestFamily()
        let id = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        let original = try XCTUnwrap(family.store.snapshot.configuration(choreID: id, on: family.store.day))

        try family.store.saveChore(choreID: id, weekday: .monday, title: "Water the plants", notes: "Use the blue cup",
                                   category: .personal, mode: .alternating, memberIDs: original.memberIDs)

        let nextMonday = ISO8601DateFormatter().date(from: "2026-09-14T16:00:00Z")!
        let next = try XCTUnwrap(family.store.dailyList(on: nextMonday).first)
        XCTAssertEqual(next.configuration.title, "Water the plants")
        XCTAssertEqual(next.configuration.memberIDs, original.memberIDs)
        XCTAssertEqual(next.turnOwner?.id, original.memberIDs[1])
    }

    func testWinningAlternatingRevisionKeepsDisplacedContributionAsHistoryOnly() throws {
        let family = try TestFamily()
        let id = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id], weekday: .tuesday)
        let original = try XCTUnwrap(family.store.snapshot.configuration(choreID: id, on: family.store.day))
        let occurrenceDay = CivilDay(rawValue: "2026-09-08")!
        let firstRevision = ChoreRevision(id: UUID(), householdID: original.householdID, choreID: id,
                                          weekday: .tuesday, effectiveDay: occurrenceDay, title: original.title,
                                          notes: original.notes, category: original.category, mode: .alternating,
                                          memberIDs: [family.hanna.id, family.alek.id], isArchived: false)
        let winningRevision = ChoreRevision(id: UUID(), householdID: original.householdID, choreID: id,
                                            weekday: .tuesday, effectiveDay: occurrenceDay, title: original.title,
                                            notes: original.notes, category: original.category, mode: .alternating,
                                            memberIDs: [family.alek.id, family.hanna.id], isArchived: false)
        let displacedContribution = DatedCompletion(choreID: id, revisionID: firstRevision.id,
                                                     memberID: family.hanna.id, day: occurrenceDay, state: .done,
                                                     eligibleMemberIDs: [family.hanna.id], mode: .alternating,
                                                     recordedByMemberID: family.hanna.id)
        let sequence = try XCTUnwrap(family.repository.facts(householdID: original.householdID).map(\.sequence).max())
        let bodies: [HouseholdFactBody] = [.chore(firstRevision), .completion(displacedContribution),
                                           .chore(winningRevision)]
        let imported = bodies.enumerated().map { index, body in
            HouseholdFact(id: UUID(), householdID: original.householdID, sequence: sequence + Int64(index) + 1,
                          authorDeviceID: UUID(), authorMemberID: family.parent.id, body: body)
        }
        try family.repository.commit(facts: imported, uploaded: true)
        family.clock.set("2026-09-08T16:00:00Z")
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)

        let chore = try XCTUnwrap(reopened.dailyList().first { $0.id == id })
        XCTAssertEqual(chore.configuration.id, winningRevision.id)
        XCTAssertEqual(chore.turnOwner?.id, family.alek.id)
        XCTAssertEqual(chore.eligibleMembers.map(\.id), [family.alek.id])
        XCTAssertEqual(chore.requiredMembers.map(\.id), [family.alek.id])
        XCTAssertTrue(chore.contributions.isEmpty)
        XCTAssertEqual(chore.historicalContributions,
                       [HistoricalContribution(member: family.hanna, state: .done)])
        XCTAssertEqual(chore.state(for: family.hanna.id), .unmarked)
        XCTAssertTrue(ChoreRules.visibleList([chore], to: family.hanna).isEmpty)
        try reopened.selectProfile(family.hanna.id)
        XCTAssertThrowsError(try reopened.setCompletion(choreID: id, memberID: family.hanna.id,
                                                        date: family.clock.now, state: .notNeeded))

        let rescheduledRevision = ChoreRevision(id: UUID(), householdID: original.householdID, choreID: id,
                                                weekday: .wednesday, effectiveDay: occurrenceDay,
                                                title: original.title, notes: original.notes,
                                                category: original.category, mode: .alternating,
                                                memberIDs: [family.alek.id, family.hanna.id], isArchived: false)
        let rescheduledFact = HouseholdFact(id: UUID(), householdID: original.householdID,
                                            sequence: sequence + Int64(bodies.count) + 1,
                                            authorDeviceID: UUID(), authorMemberID: family.parent.id,
                                            body: .chore(rescheduledRevision))
        try family.repository.commit(facts: [rescheduledFact], uploaded: true)
        let rescheduledStore = try HouseholdStore(repository: family.repository,
                                                   clock: { family.clock.now }, automaticSync: false)
        let historicalOnly = try XCTUnwrap(rescheduledStore.dailyList().first { $0.id == id })
        XCTAssertEqual(historicalOnly.configuration.id, rescheduledRevision.id)
        XCTAssertNil(historicalOnly.turnOwner)
        XCTAssertTrue(historicalOnly.eligibleMembers.isEmpty)
        XCTAssertTrue(historicalOnly.requiredMembers.isEmpty)
        XCTAssertEqual(historicalOnly.historicalContributions,
                       [HistoricalContribution(member: family.hanna, state: .done)])
        XCTAssertTrue(ChoreRules.visibleList([historicalOnly], to: family.hanna).isEmpty)
        try rescheduledStore.selectProfile(family.hanna.id)
        XCTAssertThrowsError(try rescheduledStore.setCompletion(choreID: id, memberID: family.hanna.id,
                                                                date: family.clock.now, state: .notNeeded))

        let allRevision = ChoreRevision(id: UUID(), householdID: original.householdID, choreID: id,
                                        weekday: .tuesday, effectiveDay: occurrenceDay,
                                        title: original.title, notes: original.notes,
                                        category: original.category, mode: .all,
                                        memberIDs: [], isArchived: false)
        let allFact = HouseholdFact(id: UUID(), householdID: original.householdID,
                                    sequence: sequence + Int64(bodies.count) + 2,
                                    authorDeviceID: UUID(), authorMemberID: family.parent.id,
                                    body: .chore(allRevision))
        try family.repository.commit(facts: [allFact], uploaded: true)
        let allStore = try HouseholdStore(repository: family.repository,
                                          clock: { family.clock.now }, automaticSync: false)
        let allChore = try XCTUnwrap(allStore.dailyList().first { $0.id == id })
        XCTAssertEqual(allChore.configuration.id, allRevision.id)
        XCTAssertEqual(Set(allChore.eligibleMembers.map(\.id)), [family.hanna.id, family.alek.id])
        XCTAssertEqual(Set(allChore.requiredMembers.map(\.id)), [family.hanna.id, family.alek.id])
        XCTAssertTrue(allChore.contributions.isEmpty)
        XCTAssertEqual(allChore.historicalContributions,
                       [HistoricalContribution(member: family.hanna, state: .done)])
        XCTAssertEqual(allChore.state(for: family.hanna.id), .unmarked)
        XCTAssertFalse(allChore.isFullyComplete)
    }

    func testMembershipConvergenceMovesSameRevisionCompletionToHistory() throws {
        let family = try TestFamily()
        _ = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let id = try family.chore(.alternating,
                                  ids: family.store.eligibleChildren(choreID: UUID()).map(\.id),
                                  weekday: .tuesday)
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: id, on: family.store.day))
        let occurrenceDay = CivilDay(rawValue: "2026-09-08")!
        let originalOwner = try XCTUnwrap(family.store.snapshot.member(revision.memberIDs[0]))
        let completion = DatedCompletion(choreID: id, revisionID: revision.id,
                                         memberID: originalOwner.id, day: occurrenceDay, state: .done,
                                         eligibleMemberIDs: [originalOwner.id], mode: .alternating,
                                         recordedByMemberID: originalOwner.id)
        var archivedOwner = originalOwner
        archivedOwner.archivedFrom = occurrenceDay
        let sequence = try XCTUnwrap(family.repository.facts(householdID: revision.householdID).map(\.sequence).max())
        let convergedFacts = [HouseholdFact(id: UUID(), householdID: revision.householdID,
                                           sequence: sequence + 1, authorDeviceID: UUID(),
                                           authorMemberID: originalOwner.id, body: .completion(completion)),
                              HouseholdFact(id: UUID(), householdID: revision.householdID,
                                           sequence: sequence + 2, authorDeviceID: UUID(),
                                           authorMemberID: family.parent.id, body: .member(archivedOwner))]
        try family.repository.commit(facts: convergedFacts, uploaded: true)
        family.clock.set("2026-09-08T16:00:00Z")
        let convergedStore = try HouseholdStore(repository: family.repository,
                                                clock: { family.clock.now }, automaticSync: false)

        let chore = try XCTUnwrap(convergedStore.dailyList().first { $0.id == id })
        XCTAssertNotEqual(chore.turnOwner?.id, originalOwner.id)
        XCTAssertFalse(chore.eligibleMembers.contains { $0.id == originalOwner.id })
        XCTAssertTrue(chore.contributions.isEmpty)
        XCTAssertEqual(chore.historicalContributions,
                       [HistoricalContribution(member: archivedOwner, state: .done)])
        XCTAssertFalse(PermissionService.canSetState(actor: originalOwner, target: originalOwner.id,
                                                     chore: chore, state: .done))
    }

    func testLosingSameMemberFactDoesNotShadowWinningCompletion() throws {
        let family = try TestFamily()
        let id = try family.chore(.alternating, ids: [family.alek.id, family.hanna.id], weekday: .tuesday)
        let original = try XCTUnwrap(family.store.snapshot.configuration(choreID: id, on: family.store.day))
        let occurrenceDay = CivilDay(rawValue: "2026-09-08")!
        let losingRevision = ChoreRevision(id: UUID(), householdID: original.householdID, choreID: id,
                                           weekday: .tuesday, effectiveDay: occurrenceDay,
                                           title: original.title, notes: original.notes,
                                           category: original.category, mode: .alternating,
                                           memberIDs: [family.alek.id, family.hanna.id], isArchived: false)
        let winningRevision = ChoreRevision(id: UUID(), householdID: original.householdID, choreID: id,
                                            weekday: .tuesday, effectiveDay: occurrenceDay,
                                            title: original.title, notes: original.notes,
                                            category: original.category, mode: .alternating,
                                            memberIDs: [family.alek.id, family.hanna.id], isArchived: false)
        let winningCompletion = DatedCompletion(choreID: id, revisionID: winningRevision.id,
                                                memberID: family.alek.id, day: occurrenceDay, state: .done,
                                                eligibleMemberIDs: [family.alek.id], mode: .alternating,
                                                recordedByMemberID: family.alek.id)
        let shadowingCompletion = DatedCompletion(choreID: id, revisionID: losingRevision.id,
                                                  memberID: family.alek.id, day: occurrenceDay,
                                                  state: .notNeeded, eligibleMemberIDs: [family.alek.id],
                                                  mode: .alternating, recordedByMemberID: family.alek.id)
        let sequence = try XCTUnwrap(family.repository.facts(householdID: original.householdID).map(\.sequence).max())
        let bodies: [HouseholdFactBody] = [.chore(losingRevision), .chore(winningRevision),
                                           .completion(winningCompletion), .completion(shadowingCompletion)]
        let facts = bodies.enumerated().map { index, body in
            HouseholdFact(id: UUID(), householdID: original.householdID,
                          sequence: sequence + Int64(index) + 1, authorDeviceID: UUID(),
                          authorMemberID: family.parent.id, body: body)
        }
        try family.repository.commit(facts: facts, uploaded: true)
        family.clock.set("2026-09-08T16:00:00Z")
        let reopened = try HouseholdStore(repository: family.repository,
                                          clock: { family.clock.now }, automaticSync: false)

        XCTAssertEqual(reopened.snapshot.completions, [shadowingCompletion])
        let chore = try XCTUnwrap(reopened.dailyList().first { $0.id == id })
        XCTAssertEqual(chore.configuration.id, winningRevision.id)
        XCTAssertEqual(chore.turnOwner?.id, family.alek.id)
        XCTAssertEqual(chore.contributions, [winningCompletion])
        XCTAssertEqual(chore.state(for: family.alek.id), .done)
        XCTAssertEqual(chore.creditState(for: family.alek.id), .done)
        XCTAssertEqual(chore.historicalContributions,
                       [HistoricalContribution(member: family.alek, state: .notNeeded)])
    }

    func testLosingAlternatingFactDoesNotShadowAllChildCompletion() throws {
        let family = try TestFamily()
        let id = try family.chore(.all, weekday: .tuesday)
        let original = try XCTUnwrap(family.store.snapshot.configuration(choreID: id, on: family.store.day))
        let occurrenceDay = CivilDay(rawValue: "2026-09-08")!
        let losingRevision = ChoreRevision(id: UUID(), householdID: original.householdID, choreID: id,
                                           weekday: .tuesday, effectiveDay: occurrenceDay,
                                           title: original.title, notes: original.notes,
                                           category: original.category, mode: .alternating,
                                           memberIDs: [family.alek.id, family.hanna.id], isArchived: false)
        let winningRevision = ChoreRevision(id: UUID(), householdID: original.householdID, choreID: id,
                                            weekday: .tuesday, effectiveDay: occurrenceDay,
                                            title: original.title, notes: original.notes,
                                            category: original.category, mode: .all,
                                            memberIDs: [], isArchived: false)
        let winningCompletion = DatedCompletion(choreID: id, revisionID: winningRevision.id,
                                                memberID: family.alek.id, day: occurrenceDay, state: .done,
                                                eligibleMemberIDs: [family.alek.id, family.hanna.id], mode: .all,
                                                recordedByMemberID: family.alek.id)
        let shadowingCompletion = DatedCompletion(choreID: id, revisionID: losingRevision.id,
                                                  memberID: family.alek.id, day: occurrenceDay,
                                                  state: .notNeeded, eligibleMemberIDs: [family.alek.id],
                                                  mode: .alternating, recordedByMemberID: family.alek.id)
        let sequence = try XCTUnwrap(family.repository.facts(householdID: original.householdID).map(\.sequence).max())
        let bodies: [HouseholdFactBody] = [.chore(losingRevision), .chore(winningRevision),
                                           .completion(winningCompletion), .completion(shadowingCompletion)]
        let facts = bodies.enumerated().map { index, body in
            HouseholdFact(id: UUID(), householdID: original.householdID,
                          sequence: sequence + Int64(index) + 1, authorDeviceID: UUID(),
                          authorMemberID: family.parent.id, body: body)
        }
        try family.repository.commit(facts: facts, uploaded: true)
        family.clock.set("2026-09-08T16:00:00Z")
        let reopened = try HouseholdStore(repository: family.repository,
                                          clock: { family.clock.now }, automaticSync: false)

        XCTAssertEqual(reopened.snapshot.completions, [shadowingCompletion])
        let chore = try XCTUnwrap(reopened.dailyList().first { $0.id == id })
        XCTAssertEqual(chore.configuration.id, winningRevision.id)
        XCTAssertEqual(chore.contributions, [winningCompletion])
        XCTAssertEqual(chore.state(for: family.alek.id), .done)
        XCTAssertEqual(chore.creditState(for: family.alek.id), .done)
        XCTAssertEqual(chore.historicalContributions,
                       [HistoricalContribution(member: family.alek, state: .notNeeded)])
    }

    func testLosingAllChildFactDoesNotRestoreAssignmentUnderParticularWinner() throws {
        let family = try TestFamily()
        let id = try family.chore(.particular, ids: [family.hanna.id], weekday: .tuesday)
        let original = try XCTUnwrap(family.store.snapshot.configuration(choreID: id, on: family.store.day))
        let occurrenceDay = CivilDay(rawValue: "2026-09-08")!
        let losingRevision = ChoreRevision(id: UUID(), householdID: original.householdID, choreID: id,
                                           weekday: .tuesday, effectiveDay: occurrenceDay,
                                           title: original.title, notes: original.notes,
                                           category: original.category, mode: .all,
                                           memberIDs: [], isArchived: false)
        let winningRevision = ChoreRevision(id: UUID(), householdID: original.householdID, choreID: id,
                                            weekday: .tuesday, effectiveDay: occurrenceDay,
                                            title: original.title, notes: original.notes,
                                            category: original.category, mode: .particular,
                                            memberIDs: [family.hanna.id], isArchived: false)
        let losingCompletion = DatedCompletion(choreID: id, revisionID: losingRevision.id,
                                                memberID: family.alek.id, day: occurrenceDay, state: .done,
                                                eligibleMemberIDs: [family.hanna.id, family.alek.id], mode: .all,
                                                recordedByMemberID: family.alek.id)
        let sequence = try XCTUnwrap(family.repository.facts(householdID: original.householdID).map(\.sequence).max())
        let bodies: [HouseholdFactBody] = [.chore(losingRevision), .completion(losingCompletion),
                                           .chore(winningRevision)]
        let facts = bodies.enumerated().map { index, body in
            HouseholdFact(id: UUID(), householdID: original.householdID,
                          sequence: sequence + Int64(index) + 1, authorDeviceID: UUID(),
                          authorMemberID: family.parent.id, body: body)
        }
        try family.repository.commit(facts: facts, uploaded: true)
        family.clock.set("2026-09-08T16:00:00Z")
        let reopened = try HouseholdStore(repository: family.repository,
                                          clock: { family.clock.now }, automaticSync: false)

        let chore = try XCTUnwrap(reopened.dailyList().first { $0.id == id })
        XCTAssertEqual(chore.configuration.id, winningRevision.id)
        XCTAssertEqual(chore.eligibleMembers.map(\.id), [family.hanna.id])
        XCTAssertEqual(chore.requiredMembers.map(\.id), [family.hanna.id])
        XCTAssertTrue(chore.contributions.isEmpty)
        XCTAssertEqual(chore.historicalContributions,
                       [HistoricalContribution(member: family.alek, state: .done)])
        XCTAssertNil(chore.creditState(for: family.alek.id))
        XCTAssertTrue(ChoreRules.visibleList([chore], to: family.alek).isEmpty)
        XCTAssertFalse(PermissionService.canSetState(actor: family.alek, target: family.alek.id,
                                                     chore: chore, state: .done))
    }

    func testAlternatingWinnerKeepsCrossModeFactsAsHistoryForThreeChildren() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let participants = [family.alek.id, family.hanna.id, nora.id]
        let id = try family.chore(.all, weekday: .tuesday)
        let original = try XCTUnwrap(family.store.snapshot.configuration(choreID: id, on: family.store.day))
        let occurrenceDay = CivilDay(rawValue: "2026-09-08")!
        let losingRevision = ChoreRevision(id: UUID(), householdID: original.householdID, choreID: id,
                                           weekday: .tuesday, effectiveDay: occurrenceDay,
                                           title: original.title, notes: original.notes,
                                           category: original.category, mode: .all,
                                           memberIDs: [], isArchived: false)
        let winningRevision = ChoreRevision(id: UUID(), householdID: original.householdID, choreID: id,
                                            weekday: .tuesday, effectiveDay: occurrenceDay,
                                            title: original.title, notes: original.notes,
                                            category: original.category, mode: .alternating,
                                            memberIDs: participants, isArchived: false)
        let hannaCompletion = DatedCompletion(choreID: id, revisionID: losingRevision.id,
                                              memberID: family.hanna.id, day: occurrenceDay, state: .done,
                                              eligibleMemberIDs: participants, mode: .all,
                                              recordedByMemberID: family.hanna.id)
        let noraCompletion = DatedCompletion(choreID: id, revisionID: losingRevision.id,
                                             memberID: nora.id, day: occurrenceDay, state: .notNeeded,
                                             eligibleMemberIDs: participants, mode: .all,
                                             recordedByMemberID: nora.id)
        let sequence = try XCTUnwrap(family.repository.facts(householdID: original.householdID).map(\.sequence).max())
        let bodies: [HouseholdFactBody] = [.chore(losingRevision), .completion(hannaCompletion),
                                           .completion(noraCompletion), .chore(winningRevision)]
        let facts = bodies.enumerated().map { index, body in
            HouseholdFact(id: UUID(), householdID: original.householdID,
                          sequence: sequence + Int64(index) + 1, authorDeviceID: UUID(),
                          authorMemberID: family.parent.id, body: body)
        }
        try family.repository.commit(facts: facts, uploaded: true)
        family.clock.set("2026-09-08T16:00:00Z")
        let reopened = try HouseholdStore(repository: family.repository,
                                          clock: { family.clock.now }, automaticSync: false)

        let chore = try XCTUnwrap(reopened.dailyList().first { $0.id == id })
        XCTAssertEqual(chore.configuration.id, winningRevision.id)
        XCTAssertEqual(chore.turnOwner?.id, participants[0])
        XCTAssertEqual(chore.eligibleMembers.map(\.id), [participants[0]])
        XCTAssertEqual(chore.requiredMembers.map(\.id), [participants[0]])
        XCTAssertTrue(chore.contributions.isEmpty)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: chore.historicalContributions.map {
            ($0.member.id, $0.state)
        }), [family.hanna.id: .done, nora.id: .notNeeded])
        XCTAssertTrue(ChoreRules.visibleList([chore], to: family.hanna).isEmpty)
        XCTAssertTrue(ChoreRules.visibleList([chore], to: nora).isEmpty)

        let unscheduledRevision = ChoreRevision(id: UUID(), householdID: original.householdID, choreID: id,
                                                weekday: .wednesday, effectiveDay: occurrenceDay,
                                                title: original.title, notes: original.notes,
                                                category: original.category, mode: .alternating,
                                                memberIDs: participants, isArchived: false)
        let unscheduledFact = HouseholdFact(id: UUID(), householdID: original.householdID,
                                            sequence: sequence + Int64(bodies.count) + 1,
                                            authorDeviceID: UUID(), authorMemberID: family.parent.id,
                                            body: .chore(unscheduledRevision))
        try family.repository.commit(facts: [unscheduledFact], uploaded: true)
        let unscheduledStore = try HouseholdStore(repository: family.repository,
                                                   clock: { family.clock.now }, automaticSync: false)

        let historicalOnly = try XCTUnwrap(unscheduledStore.dailyList().first { $0.id == id })
        XCTAssertNil(historicalOnly.turnOwner)
        XCTAssertTrue(historicalOnly.eligibleMembers.isEmpty)
        XCTAssertTrue(historicalOnly.requiredMembers.isEmpty)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: historicalOnly.historicalContributions.map {
            ($0.member.id, $0.state)
        }), [family.hanna.id: .done, nora.id: .notNeeded])
        XCTAssertTrue(ChoreRules.visibleList([historicalOnly], to: family.hanna).isEmpty)
        XCTAssertTrue(ChoreRules.visibleList([historicalOnly], to: nora).isEmpty)
    }

    func testAlternatingFutureTurnsExcludeArchivedAndUnselectedChildren() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let id = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id, nora.id])
        let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: id, on: family.store.day))
        let archivedID = revision.memberIDs[1]
        try family.store.archiveMember(archivedID)
        let zara = try family.store.saveMember(name: "Zara", role: .child, avatar: .fox)

        let nextMonday = ISO8601DateFormatter().date(from: "2026-09-14T16:00:00Z")!
        let thirdMonday = ISO8601DateFormatter().date(from: "2026-09-21T16:00:00Z")!
        let remainingOrder = revision.memberIDs.filter { $0 != archivedID }
        let second = try XCTUnwrap(family.store.dailyList(on: nextMonday).first)
        let third = try XCTUnwrap(family.store.dailyList(on: thirdMonday).first)
        XCTAssertEqual(second.turnOwner?.id, remainingOrder[1])
        XCTAssertEqual(third.turnOwner?.id, remainingOrder[0])
        XCTAssertFalse(second.eligibleMembers.contains { $0.id == archivedID || $0.id == zara.id })
        XCTAssertThrowsError(try family.store.setCompletion(choreID: id, memberID: archivedID,
                                                            date: nextMonday, state: .done))
    }

    func testExistingRequirementModePayloadsRemainDecodable() throws {
        for rawMode in ["all", "particular", "anyOne", "multiple"] {
            let payload = """
            {
              "id":"00000000-0000-0000-0000-000000000001",
              "householdID":"00000000-0000-0000-0000-000000000002",
              "choreID":"00000000-0000-0000-0000-000000000003",
              "weekday":2,
              "effectiveDay":"2026-09-07",
              "title":"Legacy chore",
              "notes":"",
              "category":"Home",
              "mode":"\(rawMode)",
              "memberIDs":[],
              "isArchived":false
            }
            """
            XCTAssertEqual(try JSONDecoder().decode(ChoreRevision.self, from: Data(payload.utf8)).mode.rawValue, rawMode)
        }
    }

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
            let expectedCount = mode == .particular || mode == .alternating ? 1 : 2
            XCTAssertEqual(family.store.dailyList()[0].eligibleMembers.count, expectedCount, mode.rawValue)
            XCTAssertEqual(family.store.dailyList()[0].requiredMembers.count, mode == .anyOne ? 0 : expectedCount)
            XCTAssertEqual(family.store.dailyList()[0].requiredCompletionCount, mode == .anyOne ? 1 : expectedCount)
            let first = try XCTUnwrap(family.store.dailyList()[0].eligibleMembers.first)
            try family.complete(id, as: first)
            XCTAssertEqual(family.store.dailyList()[0].isFullyComplete,
                           mode == .particular || mode == .anyOne || mode == .alternating, mode.rawValue)
            if expectedCount == 2 {
                let second = try XCTUnwrap(family.store.dailyList()[0].eligibleMembers.first { $0.id != first.id })
                try family.complete(id, as: second)
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
        XCTAssertNil(WeeklyScoringService.allowanceEarned(days: family.store.weekFacts(for: family.hanna.id, containing: previous), asOf: family.clock.now, calendar: family.store.calendar))
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
        let child = try family.store.saveMember(name: "New Child", role: .child, avatar: .star)
        XCTAssertEqual(child.joinedDay.rawValue, "2026-11-01")
        XCTAssertTrue(family.store.dailyList()[0].requiredMembers.contains { $0.id == child.id })
        try family.complete(id, as: family.hanna)
        try family.store.selectProfile(family.parent.id)
        try family.store.archiveChore(id)
        XCTAssertEqual(family.store.dailyList().count, 1)
        let persisted = family.store.snapshot.revisions.last!
        XCTAssertEqual(persisted.effectiveDay.rawValue, "2026-11-02")
        family.move(to: "2026-11-02T05:30:00Z")
        XCTAssertEqual(family.store.day.rawValue, "2026-11-02")
        XCTAssertTrue(family.store.dailyList().isEmpty)
        let renamed = try family.store.saveMember(id: child.id, name: "Renamed Child", role: .child, avatar: .fox)
        XCTAssertEqual(renamed.joinedDay, child.joinedDay)
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
        XCTAssertEqual(Set(family.store.dailyList()[0].eligibleMembers.map(\.id)), [family.hanna.id, family.alek.id, extra.id])
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
        family.move(to: "2026-09-09T16:00:00Z")
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
        XCTAssertThrowsError(try family.chore(.alternating, ids: [family.hanna.id]))
        XCTAssertThrowsError(try family.chore(.alternating, ids: [family.hanna.id, family.parent.id]))
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

    func testWeeklyAllRequiredRuleAndFutureExclusion() throws {
        let family = try TestFamily()
        let calendar = family.store.calendar
        let monday = family.clock.now
        let sunday = calendar.date(byAdding: .day, value: 6, to: monday)!
        let nextMonday = calendar.date(byAdding: .day, value: 7, to: monday)!
        XCTAssertEqual(WeeklyScoringService.status(accounted: 95, expected: 100), .yellow)
        XCTAssertEqual(WeeklyScoringService.status(accounted: 94, expected: 100), .yellow)
        XCTAssertEqual(WeeklyScoringService.status(accounted: 85, expected: 100), .yellow)
        XCTAssertEqual(WeeklyScoringService.status(accounted: 84, expected: 100), .yellow)
        XCTAssertEqual(WeeklyScoringService.status(accounted: 0, expected: 0), .neutral)
        let days = [DayFacts(date: monday, states: Array(repeating: .done, count: 85) + Array(repeating: .missed, count: 15), isExcused: false)]
        XCTAssertNil(WeeklyScoringService.allowanceEarned(days: days, asOf: sunday, calendar: calendar))
        XCTAssertEqual(WeeklyScoringService.allowanceEarned(days: days, asOf: nextMonday, calendar: calendar), false)
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
        try family.store.setCompletion(choreID: monday, memberID: family.hanna.id, date: staleDate, state: .done)
        try family.store.setCompletion(choreID: tuesday, memberID: family.hanna.id,
                                       date: family.clock.now, state: .done)
        XCTAssertEqual(Set(family.store.snapshot.completions.map { $0.day.rawValue }), ["2026-09-07", "2026-09-08"])
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

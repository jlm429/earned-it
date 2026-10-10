import CloudKit
import XCTest
@testable import EarnedIt

@MainActor
final class PuntNotificationTests: XCTestCase {
    func testMatchingMemberNamesProjectInStableOrderAcrossRelaunch() throws {
        let family = try TestFamily()
        _ = try family.store.saveMember(name: family.hanna.displayName, role: .parent, avatar: .sun)
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        let matchingIDs = reopened.snapshot.members.filter {
            $0.displayName == family.hanna.displayName
        }.map { $0.id.uuidString }
        XCTAssertEqual(matchingIDs.count, 2)
        XCTAssertEqual(matchingIDs, matchingIDs.sorted())
        XCTAssertEqual(family.store.snapshot, reopened.snapshot)
    }

    func testBuiltAppEnablesBackgroundActivityDelivery() {
        XCTAssertTrue(BackgroundActivityDelivery.isEnabled)
    }

    func testAppleSubscriptionAndNotificationUseExistingFactTypeAndGenericPrivateContent() {
        let subscription = CloudKitHouseholdTransport.activitySubscription()
        XCTAssertEqual(subscription.recordType, "HouseholdFact")
        XCTAssertEqual(subscription.notificationInfo?.shouldSendContentAvailable, true)
        XCTAssertNil(subscription.notificationInfo?.alertBody)
        XCTAssertNil(subscription.notificationInfo?.desiredKeys)
        let notification = AppleActivityAlerts.request(identifier: "opaque-activity-id")
        XCTAssertNil(notification.trigger)
        XCTAssertEqual(notification.content.title, "Earned It")
        XCTAssertEqual(notification.content.body, "New family activity. Open Earned It to review your chores and requests.")
        XCTAssertTrue(notification.content.userInfo.isEmpty)
    }
    private func request(_ family: TestFamily, chore: UUID, recipient: FamilyMember) throws -> UUID {
        let row = try XCTUnwrap(family.store.dailyList().first { $0.choreID == chore && $0.isActionableOccurrence })
        try family.store.selectProfile(try XCTUnwrap(row.turnOwnerID))
        try family.store.requestPunt(choreID: chore, occurrenceID: row.occurrenceID, recipientID: recipient.id)
        return try XCTUnwrap(family.store.puntProjection(for: row)?.pending?.id)
    }

    func testPuntCapabilityRestoresScheduledRequirementAcrossRelaunch() throws {
        let family = try TestFamily()
        let chore = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        _ = try request(family, chore: chore, recipient: family.alek)
        XCTAssertFalse(family.store.snapshot.orderedFacts.contains {
            if case .journalCapability = $0.body { return true }
            return false
        })
        try family.store.selectProfile(family.parent.id)
        for _ in 0..<2 {
            try family.store.markOccurrenceNotNeeded(choreID: chore, date: family.clock.now,
                                                     alternatingSkipBehavior: .keepTurn)
            try family.store.restoreScheduledRequirement(choreID: chore, date: family.clock.now)
            let row = try XCTUnwrap(family.store.dailyList().first)
            XCTAssertFalse(row.isNotNeeded)
            XCTAssertTrue(row.isActionableOccurrence)
            XCTAssertNil(family.store.snapshot.scheduledNotNeededFactID(
                choreID: chore, revisionID: row.configuration.id, on: row.day))
        }
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        XCTAssertFalse(try XCTUnwrap(reopened.dailyList().first).isNotNeeded)
        try reopened.selectProfile(family.hanna.id)
        XCTAssertTrue(reopened.puntRecipients(for: try XCTUnwrap(reopened.dailyList().first)).isEmpty)
        try reopened.setCompletion(choreID: chore, memberID: family.hanna.id, date: family.clock.now, state: .done)
        XCTAssertEqual(reopened.dailyList().first?.state(for: family.hanna.id), .done)
    }

    func testCompletedLegacyOccurrenceDoesNotCloseFreshSameDayPunt() throws {
        for explicitOwner in [true, false] {
            let family = try TestFamily()
            let chore = try family.store.saveChore(weekday: .monday, title: "Bins", mode: .alternating,
                memberIDs: [family.hanna.id, family.alek.id], schedulingMode: .asNeeded)
            let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
            let activation = HouseholdFact(id: UUID(), householdID: family.store.household!.id,
                sequence: family.store.snapshot.orderedFacts.last!.sequence + 1,
                authorDeviceID: family.store.session.deviceID, authorMemberID: family.parent.id,
                body: .occurrence(ChoreOccurrenceDisposition(choreID: chore, revisionID: revision.id,
                    day: family.store.day, state: .available, alternatingSkipBehavior: nil,
                    recordedByMemberID: family.parent.id, assignedMemberID: explicitOwner ? family.hanna.id : nil)))
            let completion = HouseholdFact(id: UUID(), householdID: activation.householdID,
                sequence: activation.sequence + 1, authorDeviceID: activation.authorDeviceID,
                authorMemberID: family.hanna.id, body: .completion(DatedCompletion(
                    choreID: chore, revisionID: revision.id, memberID: family.hanna.id, day: family.store.day,
                    state: .done, eligibleMemberIDs: [family.hanna.id], mode: .alternating,
                    recordedByMemberID: family.hanna.id)))
            try family.repository.commit(facts: [activation, completion])
            let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
            XCTAssertEqual(reopened.dailyList().first?.state(for: family.hanna.id), .done)
            try reopened.selectProfile(family.parent.id)
            XCTAssertEqual(reopened.nextAlternatingOwner(choreID: chore)?.id, family.alek.id)
            try reopened.skipNextAlternatingChild(choreID: chore)
            try reopened.activateAsNeededChore(choreID: chore)
            let fresh = try XCTUnwrap(reopened.dailyList().first { $0.isActionableOccurrence })
            XCTAssertNotEqual(fresh.occurrenceID, activation.id)
            XCTAssertEqual(fresh.turnOwnerID, family.hanna.id)
            try reopened.selectProfile(family.hanna.id)
            XCTAssertEqual(reopened.puntRecipients(for: fresh).map(\.id), [family.alek.id])
            try reopened.requestPunt(choreID: chore, occurrenceID: fresh.occurrenceID, recipientID: family.alek.id)
            let requestID = try XCTUnwrap(reopened.puntProjection(for: fresh)?.pending?.id)
            try reopened.selectProfile(family.alek.id)
            try reopened.decidePunt(requestFactID: requestID, kind: .accepted)
            try reopened.setCompletion(choreID: chore, occurrenceID: fresh.occurrenceID,
                memberID: family.alek.id, date: family.clock.now, state: .done)
            XCTAssertEqual(reopened.dailyList().first { $0.occurrenceID == activation.id }?.state(for: family.hanna.id), .done)
            XCTAssertEqual(reopened.dailyList().first { $0.occurrenceID == fresh.occurrenceID }?.state(for: family.alek.id), .done)
            XCTAssertEqual(reopened.nextAlternatingOwner(choreID: chore)?.id, family.alek.id)
            XCTAssertThrowsError(try reopened.decidePunt(requestFactID: requestID, kind: .accepted))
        }
    }

    func testFormerOwnerOfflineDoneCannotOverrideRecipientNotNeeded() throws {
        let family = try TestFamily()
        let chore = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        let requestID = try request(family, chore: chore, recipient: family.alek)
        try family.store.selectProfile(family.alek.id)
        try family.store.decidePunt(requestFactID: requestID, kind: .accepted)
        let row = try XCTUnwrap(family.store.dailyList().first)
        let stale = HouseholdFact(id: UUID(), householdID: family.store.household!.id,
            sequence: family.store.snapshot.orderedFacts.last!.sequence + 1,
            authorDeviceID: UUID(), authorMemberID: family.hanna.id,
            body: .completion(DatedCompletion(choreID: chore, revisionID: row.configuration.id,
                memberID: family.hanna.id, day: row.day, state: .done,
                eligibleMemberIDs: [family.hanna.id], mode: .alternating, recordedByMemberID: family.hanna.id)))
        try family.repository.commit(facts: [stale])
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        try reopened.selectProfile(family.parent.id)
        try reopened.markOccurrenceNotNeeded(choreID: chore, date: family.clock.now, alternatingSkipBehavior: .keepTurn)
        let disposed = try XCTUnwrap(reopened.dailyList().first)
        XCTAssertEqual(disposed.turnOwnerID, family.alek.id)
        XCTAssertTrue(disposed.isNotNeeded)
        XCTAssertTrue(ChoreRules.visibleList([disposed], to: family.alek).isEmpty)
        try reopened.selectProfile(family.alek.id)
        XCTAssertThrowsError(try reopened.setCompletion(choreID: chore, memberID: family.alek.id,
            date: family.clock.now, state: .done))
        XCTAssertTrue(disposed.completedMembers.isEmpty)
        XCTAssertTrue(disposed.historicalContributions.contains {
            $0.member.id == family.hanna.id && $0.state == .done
        })
        XCTAssertTrue(reopened.snapshot.orderedFacts.contains(stale))
        family.move(to: "2026-09-08T16:00:00Z")
        reopened.refreshDate()
        XCTAssertTrue(try XCTUnwrap(reopened.dailyList(on: row.day.date(in: reopened.calendar)).first).isNotNeeded)
        XCTAssertFalse(reopened.allowanceWeek(for: family.alek.id).items.contains { $0.choreID == chore && $0.state == .missed })
        family.move(to: "2026-09-14T16:00:00Z")
        reopened.refreshDate()
        XCTAssertEqual(reopened.dailyList().first?.turnOwnerID, family.hanna.id)
    }

    func testScheduledApprovalChangesOnlyTodayAndCreditWithoutMovingRotation() throws {
        let family = try TestFamily()
        let chore = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        let requestID = try request(family, chore: chore, recipient: family.alek)
        XCTAssertEqual(family.store.dailyList().first?.turnOwnerID, family.hanna.id)
        XCTAssertThrowsError(try family.store.decidePunt(requestFactID: requestID, kind: .accepted))
        try family.store.selectProfile(family.parent.id)
        XCTAssertThrowsError(try family.store.decidePunt(requestFactID: requestID, kind: .accepted))
        try family.store.selectProfile(family.alek.id)
        try family.store.decidePunt(requestFactID: requestID, kind: .accepted)
        let approved = try XCTUnwrap(family.store.dailyList().first)
        XCTAssertEqual(approved.turnOwnerID, family.alek.id)
        XCTAssertEqual(approved.requiredMemberIDs, [family.alek.id])
        XCTAssertThrowsError(try family.store.decidePunt(requestFactID: requestID, kind: .accepted))
        XCTAssertTrue(family.store.puntRecipients(for: approved).isEmpty)
        try family.complete(chore, as: family.alek)
        XCTAssertTrue(family.store.allowanceWeek(for: family.alek.id).items.contains { $0.choreID == chore && $0.state == .done })
        XCTAssertFalse(family.store.allowanceWeek(for: family.hanna.id).items.contains { $0.choreID == chore })
        let originalDate = family.clock.now
        family.move(to: "2026-09-14T16:00:00Z")
        XCTAssertEqual(family.store.dailyList().first?.turnOwnerID, family.alek.id)
        XCTAssertEqual(family.store.dailyList(on: originalDate).first?.turnOwnerID, family.alek.id)
        XCTAssertEqual(family.store.dailyList(on: originalDate).first?.state(for: family.alek.id), .done)
    }

    func testDeclineCancelAndRetryCannotReviveAnOldRequest() throws {
        let family = try TestFamily()
        let chore = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        let first = try request(family, chore: chore, recipient: family.alek)
        XCTAssertThrowsError(try family.store.requestPunt(choreID: chore, recipientID: family.alek.id))
        try family.store.selectProfile(family.alek.id)
        try family.store.decidePunt(requestFactID: first, kind: .declined)
        XCTAssertEqual(family.store.dailyList().first?.turnOwnerID, family.hanna.id)
        let second = try request(family, chore: chore, recipient: family.alek)
        try family.store.decidePunt(requestFactID: second, kind: .cancelled)
        try family.store.selectProfile(family.alek.id)
        XCTAssertThrowsError(try family.store.decidePunt(requestFactID: first, kind: .accepted))
        XCTAssertThrowsError(try family.store.decidePunt(requestFactID: second, kind: .accepted))
        XCTAssertEqual(family.store.dailyList().first?.turnOwnerID, family.hanna.id)
    }

    func testAsNeededPuntConsumesOriginalSlotAndNeverAnotherSameDayOccurrence() throws {
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.store.saveChore(weekday: .monday, title: "Bins", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id, nora.id], schedulingMode: .asNeeded)
        let order = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day)).memberIDs
        let recipient = try XCTUnwrap(family.store.snapshot.member(order[2]))
        try family.store.activateAsNeededChore(choreID: chore)
        let firstOccurrence = try XCTUnwrap(family.store.dailyList().first?.occurrenceID)
        let requestID = try request(family, chore: chore, recipient: recipient)
        try family.store.selectProfile(recipient.id)
        try family.store.decidePunt(requestFactID: requestID, kind: .accepted)
        try family.store.setCompletion(choreID: chore, occurrenceID: firstOccurrence,
            memberID: recipient.id, date: family.clock.now, state: .done)
        XCTAssertEqual(family.store.nextAlternatingOwner(choreID: chore)?.id, order[1])
        try family.store.selectProfile(family.parent.id)
        try family.store.activateAsNeededChore(choreID: chore)
        let second = try XCTUnwrap(family.store.dailyList().first { $0.isActionableOccurrence })
        XCTAssertNotEqual(second.occurrenceID, firstOccurrence)
        XCTAssertEqual(second.turnOwnerID, order[1])
        try family.store.selectProfile(recipient.id)
        XCTAssertThrowsError(try family.store.decidePunt(requestFactID: requestID, kind: .accepted))
        XCTAssertEqual(family.store.dailyList().first { $0.occurrenceID == firstOccurrence }?.state(for: recipient.id), .done)
    }

    func testLegacyAsNeededActivationCanPuntWithoutChangingLegacyRotation() throws {
        for explicitOwner in [true, false] {
            let family = try TestFamily()
            let chore = try family.store.saveChore(weekday: .monday, title: "Bins", mode: .alternating,
                memberIDs: [family.hanna.id, family.alek.id], schedulingMode: .asNeeded)
            let revision = try XCTUnwrap(family.store.snapshot.configuration(choreID: chore, on: family.store.day))
            let activation = HouseholdFact(id: UUID(), householdID: family.store.household!.id,
                sequence: family.store.snapshot.orderedFacts.last!.sequence + 1,
                authorDeviceID: family.store.session.deviceID, authorMemberID: family.parent.id,
                body: .occurrence(ChoreOccurrenceDisposition(choreID: chore, revisionID: revision.id,
                    day: family.store.day, state: .available,
                    alternatingSkipBehavior: nil, recordedByMemberID: family.parent.id,
                    assignedMemberID: explicitOwner ? family.hanna.id : nil)))
            try family.repository.commit(facts: [activation])
            let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
            try reopened.selectProfile(family.hanna.id)
            try reopened.requestPunt(choreID: chore, occurrenceID: activation.id, recipientID: family.alek.id)
            let requestID = try XCTUnwrap(reopened.activity.first { $0.punt?.status == .pending }?.id)
            try reopened.selectProfile(family.alek.id)
            try reopened.decidePunt(requestFactID: requestID, kind: .accepted)
            try reopened.setCompletion(choreID: chore, occurrenceID: activation.id,
                memberID: family.alek.id, date: family.clock.now, state: .done)
            XCTAssertEqual(reopened.dailyList().first?.state(for: family.alek.id), .done)
            XCTAssertEqual(reopened.nextAlternatingOwner(choreID: chore)?.id, family.alek.id)
        }
    }

    func testRelaunchPreservesPendingAndTodayExpiryPreventsHistoricalApproval() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Punt-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let family = try TestFamily(url: directory.appending(path: "journal.store"))
        let chore = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        let requestID = try request(family, chore: chore, recipient: family.alek)
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        try reopened.selectProfile(family.alek.id)
        XCTAssertEqual(reopened.activity.first { $0.id == requestID }?.punt?.status, .pending)
        family.move(to: "2026-09-08T16:00:00Z")
        reopened.refreshDate()
        XCTAssertEqual(reopened.activity.first { $0.id == requestID }?.punt?.status, .expired)
        XCTAssertThrowsError(try reopened.decidePunt(requestFactID: requestID, kind: .accepted))
    }

    func testCompletionBeforeDelayedApprovalWinsUnderEveryDeliveryOrder() throws {
        let family = try TestFamily()
        let chore = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        let requestID = try request(family, chore: chore, recipient: family.alek)
        try family.complete(chore, as: family.hanna)
        try family.store.selectProfile(family.alek.id)
        XCTAssertThrowsError(try family.store.decidePunt(requestFactID: requestID, kind: .accepted))
        let scope = PuntRules.scope(for: try XCTUnwrap(family.store.dailyList().first))
        let facts = family.store.snapshot.orderedFacts
        let delayed = HouseholdFact(id: UUID(), householdID: family.store.household!.id,
            sequence: facts.last!.sequence + 1, authorDeviceID: UUID(), authorMemberID: family.alek.id,
            body: .puntDecision(PuntDecision(requestFactID: requestID, scope: scope, day: scope.day,
                                             memberID: family.alek.id, kind: .accepted)))
        for delivered in [facts + [delayed], [delayed] + facts.reversed(), (facts + [delayed]).reversed().map { $0 }] {
            let snapshot = HouseholdSnapshot(facts: delivered)
            let row = try XCTUnwrap(ChoreRules.dailyList(snapshot: snapshot, day: scope.day, today: scope.day).first)
            XCTAssertEqual(row.turnOwnerID, family.hanna.id)
            XCTAssertEqual(row.state(for: family.hanna.id), .done)
            XCTAssertEqual(PuntRules.project(scope: scope, originalOwnerID: family.hanna.id, snapshot: snapshot).requests.first?.status, .expired)
        }
    }

    func testStaleApprovalAndRecipientCompletionCannotConsumeKeptScheduledTurn() throws {
        let family = try TestFamily()
        let chore = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        let requestID = try request(family, chore: chore, recipient: family.alek)
        let scope = PuntRules.scope(for: try XCTUnwrap(family.store.dailyList().first))
        try family.store.selectProfile(family.parent.id)
        try family.store.markOccurrenceNotNeeded(choreID: chore, date: family.clock.now, alternatingSkipBehavior: .keepTurn)
        let facts = family.store.snapshot.orderedFacts
        let lateDecision = HouseholdFact(id: UUID(), householdID: family.store.household!.id,
            sequence: facts.last!.sequence + 1, authorDeviceID: UUID(), authorMemberID: family.alek.id,
            body: .puntDecision(PuntDecision(requestFactID: requestID, scope: scope, day: scope.day,
                                             memberID: family.alek.id, kind: .accepted)))
        let lateDone = HouseholdFact(id: UUID(), householdID: lateDecision.householdID,
            sequence: lateDecision.sequence + 1, authorDeviceID: lateDecision.authorDeviceID,
            authorMemberID: family.alek.id, body: .completion(DatedCompletion(
                choreID: chore, revisionID: scope.revisionID, memberID: family.alek.id, day: scope.day,
                state: .done, eligibleMemberIDs: [family.alek.id], mode: .alternating,
                recordedByMemberID: family.alek.id)))
        let snapshot = HouseholdSnapshot(facts: facts + [lateDecision, lateDone])
        let nextDay = scope.day.adding(days: 7, calendar: family.store.calendar)
        XCTAssertEqual(ChoreRules.dailyList(snapshot: snapshot, day: nextDay, today: nextDay).first?.turnOwnerID, family.hanna.id)
        XCTAssertEqual(ChoreRules.dailyList(snapshot: snapshot, day: scope.day, today: nextDay).first?.turnOwnerID, family.hanna.id)
    }

    func testNotNeededWithdrawalDeletionAndWrongRecipientCannotTransfer() throws {
        for action in ["notNeeded", "withdraw", "delete"] {
            let family = try TestFamily()
            let chore = try family.store.saveChore(weekday: .monday, title: "Bins", mode: .alternating,
                memberIDs: [family.hanna.id, family.alek.id], schedulingMode: action == "withdraw" ? .asNeeded : .scheduled)
            if action == "withdraw" { try family.store.activateAsNeededChore(choreID: chore) }
            let requestID = try request(family, chore: chore, recipient: family.alek)
            let occurrenceID = family.store.dailyList().first?.occurrenceID
            try family.store.selectProfile(family.parent.id)
            switch action {
            case "notNeeded": try family.store.markOccurrenceNotNeeded(choreID: chore, date: family.clock.now, alternatingSkipBehavior: .keepTurn)
            case "withdraw": try family.store.withdrawAsNeededOccurrence(choreID: chore, occurrenceID: XCTUnwrap(occurrenceID))
            default: try family.store.deleteChore(chore)
            }
            try family.store.selectProfile(family.alek.id)
            XCTAssertThrowsError(try family.store.decidePunt(requestFactID: requestID, kind: .accepted))
        }
        let family = try TestFamily()
        let nora = try family.store.saveMember(name: "Nora", role: .child, avatar: .star)
        let chore = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        try family.store.selectProfile(family.hanna.id)
        XCTAssertThrowsError(try family.store.requestPunt(choreID: chore, recipientID: nora.id))
    }

    func testOfflineChildRequestRecipientApprovalAndCompletionSyncAcrossExactProfiles() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let chore = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        let hannaInvite = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let hannaTransport = TestTransport(server: server, account: "hanna-account")
        let hanna = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: hannaTransport,
            clock: { family.clock.now }, automaticSync: false)
        try await hanna.redeemInvitation(hannaInvite.qrPayload)
        let alekInvite = try await family.store.createChildInvitation(memberID: family.alek.id)
        let alek = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
            transport: TestTransport(server: server, account: "alek-account"), clock: { family.clock.now }, automaticSync: false)
        try await alek.redeemInvitation(alekInvite.qrPayload)
        hannaTransport.fetchError = CKError(.networkUnavailable)
        try hanna.requestPunt(choreID: chore, recipientID: family.alek.id)
        let requestID = try XCTUnwrap(hanna.activity.first { $0.punt?.status == .pending }?.id)
        XCTAssertThrowsError(try hanna.selectProfile(family.alek.id))
        do { try await hanna.synchronize(); XCTFail("Expected offline transport") } catch {}
        XCTAssertGreaterThan(hanna.pendingCount, 0)
        hannaTransport.fetchError = nil
        try await hanna.synchronize()
        try await alek.synchronize()
        XCTAssertEqual(alek.activity.first { $0.id == requestID }?.punt?.status, .pending)
        try alek.decidePunt(requestFactID: requestID, kind: .accepted)
        try alek.setCompletion(choreID: chore, memberID: family.alek.id, date: family.clock.now, state: .done)
        try await alek.synchronize()
        try await hanna.synchronize()
        try await family.store.synchronize()
        XCTAssertEqual(family.store.dailyList().first?.turnOwnerID, family.alek.id)
        XCTAssertEqual(family.store.dailyList().first?.state(for: family.alek.id), .done)
        let invitationIDs = family.store.snapshot.invitations.map { $0.id.uuidString }
        XCTAssertEqual(invitationIDs, invitationIDs.sorted())
        XCTAssertEqual(hanna.snapshot, alek.snapshot)
        XCTAssertEqual(family.store.snapshot, alek.snapshot)
        XCTAssertEqual(alek.pendingCount, 0)
    }

    func testEveryActivityUpdateBeyondFiftyCanBeDisplayedAndMarkedRead() throws {
        let family = try TestFamily()
        let chore = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        let requestID = try request(family, chore: chore, recipient: family.alek)
        try family.store.selectProfile(family.parent.id)
        for _ in 0..<51 { _ = try family.chore(.all) }
        try family.store.selectProfile(family.alek.id)
        let activity = family.store.activity
        XCTAssertEqual(activity.count, 53)
        XCTAssertEqual(family.store.unreadActivityCount, activity.count)
        let displayed = FamilyActivityView.items(from: activity)
        XCTAssertEqual(displayed.count, activity.count)
        XCTAssertEqual(Set(displayed.map(\.id)), Set(activity.map(\.id)))
        XCTAssertEqual(displayed.first?.id, requestID)
        for item in displayed { try family.store.markActivityRead(item) }
        XCTAssertEqual(family.store.unreadActivityCount, 0)
        XCTAssertEqual(family.store.puntProjection(for: try XCTUnwrap(family.store.dailyList().first {
            $0.choreID == chore
        }))?.pending?.id, requestID)
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.unreadActivityCount, 0)
        XCTAssertEqual(Set(FamilyActivityView.items(from: reopened.activity).map(\.id)), Set(activity.map(\.id)))
        XCTAssertTrue(reopened.activity.allSatisfy { reopened.isActivityRead($0) })
        try reopened.selectProfile(family.hanna.id)
        XCTAssertEqual(reopened.unreadActivityCount, 53)
    }

    func testDeniedAlertsKeepUnreadActivityAndAllowedAlertsDoNotRepeatAcrossRelaunch() async throws {
        let family = try TestFamily()
        let chore = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        let requestID = try request(family, chore: chore, recipient: family.alek)
        let alerts = TestActivityAlerts()
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now },
            automaticSync: false, activityAlerts: alerts)
        try reopened.selectProfile(family.alek.id)
        await reopened.processActivityAlerts()
        XCTAssertEqual(alerts.delivered.count, 0)
        XCTAssertEqual(reopened.activity.first { $0.id == requestID }?.punt?.status, .pending)
        XCTAssertGreaterThan(reopened.unreadActivityCount, 0)
        alerts.currentPermission = .allowed
        await reopened.requestActivityAlertPermission()
        await reopened.processActivityAlerts()
        XCTAssertEqual(alerts.delivered.count, 0, "Permission changes must not replay the old backlog")
        try reopened.decidePunt(requestFactID: requestID, kind: .declined)
        try reopened.selectProfile(family.hanna.id)
        await reopened.processActivityAlerts()
        XCTAssertEqual(alerts.delivered.count, 1)
        let again = try HouseholdStore(repository: family.repository, clock: { family.clock.now },
            automaticSync: false, activityAlerts: alerts)
        await again.processActivityAlerts()
        XCTAssertEqual(alerts.delivered.count, 1)
        let item = try XCTUnwrap(again.activity.first { $0.title == "Punt declined" })
        try again.markActivityRead(item)
        XCTAssertTrue(again.isActivityRead(item))
        XCTAssertEqual(again.activity.first { $0.id == requestID }?.punt?.status, .declined)
    }

    func testAvailabilityAlertsIncludeEveryEligibleChildButNotInactiveDefinition() async throws {
        let family = try TestFamily()
        let chore = try family.store.saveChore(weekday: .monday, title: "Bins", mode: .alternating,
            memberIDs: [family.hanna.id, family.alek.id], schedulingMode: .asNeeded)
        XCTAssertFalse(FamilyActivityRules.activity(snapshot: family.store.snapshot, today: family.store.day)
            .contains { $0.title == "Chore available" })
        try family.store.activateAsNeededChore(choreID: chore)
        let item = try XCTUnwrap(FamilyActivityRules.activity(snapshot: family.store.snapshot, today: family.store.day)
            .first { $0.title == "Chore available" })
        XCTAssertEqual(item.recipientIDs, [family.hanna.id, family.alek.id])
        let alerts = TestActivityAlerts()
        alerts.currentPermission = .allowed
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now },
            automaticSync: false, activityAlerts: alerts)
        try reopened.selectProfile(family.alek.id)
        await reopened.processActivityAlerts()
        await reopened.processActivityAlerts()
        XCTAssertEqual(alerts.delivered.count, 1)
    }

    func testProfileSwitchDuringAlertDeliveryClearsOldAlertAndProcessesNewProfile() async throws {
        let family = try TestFamily()
        _ = try family.chore(.all)
        let alerts = TestActivityAlerts()
        alerts.currentPermission = .allowed
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now },
            automaticSync: false, activityAlerts: alerts)
        try reopened.selectProfile(family.hanna.id)
        let gate = TestSuspensionGate()
        alerts.beforeDelivery = { await gate.wait() }
        let nextProfile = expectation(description: "The new profile's alert is processed")
        alerts.didDeliver = { id in
            if id.contains(family.alek.id.uuidString) { nextProfile.fulfill() }
        }
        let processing = Task { await reopened.processActivityAlerts() }
        while !gate.isWaiting { await Task.yield() }
        try reopened.selectProfile(family.alek.id)
        await reopened.processActivityAlerts()
        gate.resume()
        await processing.value
        await fulfillment(of: [nextProfile], timeout: 3)
        XCTAssertGreaterThan(alerts.clearCount, 0)
        XCTAssertEqual(alerts.delivered.count, 2)
        await reopened.processActivityAlerts()
        XCTAssertEqual(alerts.delivered.count, 2)
    }

    func testParentCorrectionToEarlierDayAndFutureAssignmentStillAlertOnArrival() async throws {
        let family = try TestFamily()
        let chore = try family.chore(.all)
        let originalDate = family.clock.now
        family.move(to: "2026-09-09T16:00:00Z")
        let alerts = TestActivityAlerts()
        alerts.currentPermission = .allowed
        let reopened = try HouseholdStore(repository: family.repository, clock: { family.clock.now },
            automaticSync: false, activityAlerts: alerts)
        try reopened.selectProfile(family.hanna.id)
        await reopened.processActivityAlerts()
        let beforeCorrection = alerts.delivered.count
        try family.store.selectProfile(family.parent.id)
        try family.store.setCompletion(choreID: chore, memberID: family.hanna.id,
                                       date: originalDate, state: .done)
        let corrected = try HouseholdStore(repository: family.repository, clock: { family.clock.now },
            automaticSync: false, activityAlerts: alerts)
        try corrected.selectProfile(family.hanna.id)
        await corrected.processActivityAlerts()
        XCTAssertEqual(alerts.delivered.count, beforeCorrection + 1)
        XCTAssertTrue(corrected.activity.contains { $0.title == "Chore updated" && $0.day == CivilDay(originalDate, calendar: family.store.calendar) })
        try family.store.saveChore(choreID: chore, weekday: .monday, title: "Water garden",
                                    mode: .all, memberIDs: [])
        let revised = try HouseholdStore(repository: family.repository, clock: { family.clock.now },
            automaticSync: false, activityAlerts: alerts)
        await revised.processActivityAlerts()
        XCTAssertEqual(alerts.delivered.count, beforeCorrection + 2)
        XCTAssertTrue(revised.activity.contains { $0.title == "Chore requested" && $0.day == family.store.tomorrow })
    }

    func testFactRoundTripAndDuplicateApprovalAreIdempotent() throws {
        let family = try TestFamily()
        let chore = try family.chore(.alternating, ids: [family.hanna.id, family.alek.id])
        let requestID = try request(family, chore: chore, recipient: family.alek)
        try family.store.selectProfile(family.alek.id)
        try family.store.decidePunt(requestFactID: requestID, kind: .accepted)
        let facts = family.store.snapshot.orderedFacts
        let decision = try XCTUnwrap(facts.last)
        let duplicate = HouseholdFact(id: UUID(), householdID: decision.householdID,
            sequence: decision.sequence + 1, authorDeviceID: decision.authorDeviceID,
            authorMemberID: decision.authorMemberID, body: decision.body)
        let data = try JSONEncoder().encode(facts + [duplicate])
        let decoded = try JSONDecoder().decode([HouseholdFact].self, from: data)
        let snapshot = HouseholdSnapshot(facts: decoded.reversed())
        let row = try XCTUnwrap(ChoreRules.dailyList(snapshot: snapshot, day: family.store.day, today: family.store.day).first)
        let projection = PuntRules.project(scope: PuntRules.scope(for: row), originalOwnerID: family.hanna.id, snapshot: snapshot)
        XCTAssertEqual(projection.requests.count, 1)
        XCTAssertEqual(projection.accepted?.decisionFactID, decision.id)
        XCTAssertEqual(snapshot.requiredJournalCapability, JournalCapability.puntApprovals)
    }
}

@MainActor
private final class TestActivityAlerts: ActivityAlerting {
    var currentPermission: ActivityAlertPermission = .denied
    var delivered: [String] = []
    var clearCount = 0
    var beforeDelivery: (() async -> Void)?
    var didDeliver: ((String) -> Void)?
    func permission() async -> ActivityAlertPermission { currentPermission }
    func requestPermission() async throws -> ActivityAlertPermission { currentPermission }
    func deliver(identifier: String) async throws {
        if let beforeDelivery {
            self.beforeDelivery = nil
            await beforeDelivery()
        }
        delivered.append(identifier)
        didDeliver?(identifier)
    }
    func clear() async { clearCount += 1 }
}

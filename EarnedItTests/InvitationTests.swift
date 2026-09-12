import CloudKit
import XCTest
@testable import EarnedIt

@MainActor
final class InvitationTests: XCTestCase {
    func testInvitationCredentialNormalizesManualCodesAndRejectsMalformedPackages() throws {
        XCTAssertEqual(InvitationCredential(text: " 2345 6789 ab ")?.code, "2345-6789-AB")
        let share = "https%3A%2F%2Ficloud.com%2Fshare"
        XCTAssertEqual(
            InvitationCredential(text: "earnedit-invitation://join?code=23456789AB&share=\(share)")?.shareURL,
            URL(string: "https://icloud.com/share")
        )
        XCTAssertNil(InvitationCredential(text: "earnedit-invitation://other?code=23456789AB&share=\(share)"))
        XCTAssertNil(InvitationCredential(
            text: "earnedit-invitation://join?code=23456789AB&code=23456789AC&share=\(share)"
        ))
    }

    func testParentInvitationJoinsExistingFamilyPersistsAndCanManageSharedData() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "parent-a"))
        let existingChore = try family.chore()
        try family.complete(existingChore, as: family.hanna)
        try family.store.selectProfile(family.parent.id)

        let invitation = try await family.store.createParentInvitation(name: "Parent B", avatar: .fox)
        let parentB = try XCTUnwrap(family.store.snapshot.member(invitation.invitation.memberID))
        XCTAssertEqual(parentB.role, .parent)
        XCTAssertEqual(invitation.invitation.role, .parent)

        let repository = try HouseholdRepository(inMemory: true)
        let transport = TestTransport(server: server, account: "parent-b")
        var joined: HouseholdStore? = try HouseholdStore(repository: repository, transport: transport,
                                                         clock: { family.clock.now }, automaticSync: false)
        try await joined!.redeemInvitation(invitation.qrPayload)
        XCTAssertEqual(joined!.household?.id, family.store.household?.id)
        XCTAssertEqual(joined!.selectedMember?.id, parentB.id)
        XCTAssertEqual(joined!.profiles.map(\.id), [parentB.id])
        XCTAssertEqual(joined!.dailyList().first?.state(for: family.hanna.id), .done)
        XCTAssertEqual(joined!.allowanceHistory(for: family.hanna.id), family.store.allowanceHistory(for: family.hanna.id))

        joined = nil
        joined = try HouseholdStore(repository: repository, transport: transport,
                                    clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(joined!.selectedMember?.id, parentB.id)

        let parentBChore = try joined!.saveChore(weekday: .monday, title: "Parent B chore", mode: .all, memberIDs: [])
        try joined!.saveMember(id: family.alek.id, name: "Alek Updated", role: .child, avatar: .rocket)
        try await joined!.synchronize()
        try await family.store.synchronize()
        XCTAssertEqual(family.store.snapshot.member(family.alek.id)?.displayName, "Alek Updated")
        try family.store.saveChore(choreID: parentBChore, weekday: .monday, title: "Parents edited this",
                                   mode: .all, memberIDs: [])
        try await family.store.synchronize()
        try await joined!.synchronize()
        try joined!.archiveChore(parentBChore)
        try await joined!.synchronize()
        try await family.store.synchronize()
        XCTAssertEqual(joined!.snapshot, family.store.snapshot)

        await XCTAssertThrowsErrorAsync(
            try await joined!.createChildInvitation(memberID: family.hanna.id),
            expected: .invitationOwnerRequired
        )
    }

    func testChildInvitationBindsOneProfileAndCannotBeReusedOrEscalated() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let childTransport = TestTransport(server: server, account: "child")
        let child = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: childTransport,
                                       clock: { family.clock.now }, automaticSync: false)
        try await child.redeemInvitation(invitation.qrPayload)

        XCTAssertEqual(child.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(child.profiles.map(\.id), [family.hanna.id])
        XCTAssertThrowsError(try child.selectProfile(family.alek.id)) {
            XCTAssertEqual($0 as? HouseholdError, .permission)
        }
        XCTAssertThrowsError(try child.selectProfile(family.parent.id)) {
            XCTAssertEqual($0 as? HouseholdError, .permission)
        }
        await XCTAssertThrowsErrorAsync(try await child.createParentInvitation(name: "Not a Parent", avatar: .sun),
                                        expected: .permission)

        let reuse = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                       transport: TestTransport(server: server, account: "other-child"),
                                       clock: { family.clock.now }, automaticSync: false)
        await XCTAssertThrowsErrorAsync(try await reuse.redeemInvitation(invitation.qrPayload),
                                        expected: .invitationConsumed)
        XCTAssertNil(reuse.household)
    }

    func testChildInvitationOverridesApprovedLegacySiblingProfiles() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let repository = try HouseholdRepository(inMemory: true)
        let transport = TestTransport(server: server, account: "child")
        let child = try HouseholdStore(repository: repository, transport: transport,
                                       clock: { family.clock.now }, automaticSync: false)
        let requestID = UUID()
        let sequence = (server.zones[invitation.shareURL.lastPathComponent]?.facts.values
            .map(\.sequence).max() ?? 0) + 1
        let request = ProfileRequest(id: requestID, deviceID: child.session.deviceID,
                                     cloudParticipantID: "child", deviceName: "Older tablet",
                                     memberIDs: [family.hanna.id, family.alek.id])
        let grant = ProfileGrant(requestID: requestID, deviceID: child.session.deviceID,
                                 cloudParticipantID: "child", memberIDs: [family.hanna.id, family.alek.id],
                                 approvedBy: family.parent.id)
        let requestFact = HouseholdFact(id: UUID(), householdID: invitation.invitation.householdID,
                                        sequence: sequence, authorDeviceID: family.store.session.deviceID,
                                        authorMemberID: family.parent.id, body: .request(request))
        let grantFact = HouseholdFact(id: UUID(), householdID: invitation.invitation.householdID,
                                      sequence: sequence + 1, authorDeviceID: family.store.session.deviceID,
                                      authorMemberID: family.parent.id, body: .grant(grant))
        server.zones[invitation.shareURL.lastPathComponent]?.facts[requestFact.id] = requestFact
        server.zones[invitation.shareURL.lastPathComponent]?.facts[grantFact.id] = grantFact

        try await child.redeemInvitation(invitation.qrPayload)

        XCTAssertEqual(child.profiles.map(\.id), [family.hanna.id])
        XCTAssertEqual(child.selectedMember?.id, family.hanna.id)
        XCTAssertThrowsError(try child.selectProfile(family.alek.id)) {
            XCTAssertEqual($0 as? HouseholdError, .permission)
        }
        let reopened = try HouseholdStore(repository: repository, transport: transport,
                                          clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.profiles.map(\.id), [family.hanna.id])
        XCTAssertThrowsError(try reopened.selectProfile(family.alek.id))
    }

    func testInvitationLifecycleRejectsInvalidExpiredRevokedAndCrossFamilyCodes() async throws {
        let server = TestCloudServer()
        let ownerTransport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: ownerTransport)
        let expired = try await family.store.createChildInvitation(memberID: family.hanna.id)
        family.move(to: "2026-09-08T17:00:01Z")
        let expiredJoin = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: TestTransport(server: server, account: "expired"),
                                             clock: { family.clock.now }, automaticSync: false)
        await XCTAssertThrowsErrorAsync(try await expiredJoin.redeemInvitation(expired.qrPayload),
                                        expected: .invitationExpired)
        XCTAssertNil(expiredJoin.household)
        XCTAssertFalse(server.zones[expired.shareURL.lastPathComponent]!.participants.contains("expired"))

        family.move(to: "2026-09-07T16:00:00Z")
        let revoked = try await family.store.createChildInvitation(memberID: family.alek.id)
        try await family.store.revokeInvitation(revoked.invitation)
        let ownerPeer = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                           transport: TestTransport(server: server, account: "owner"),
                                           clock: { family.clock.now }, automaticSync: false)
        await XCTAssertThrowsErrorAsync(try await ownerPeer.redeemInvitation(revoked.code), expected: .invitationRevoked)
        await XCTAssertThrowsErrorAsync(try await ownerPeer.redeemInvitation("2345-6789-AB"), expected: .invitationNotFound)
        XCTAssertNil(ownerPeer.household)

        let other = try TestFamily(transport: TestTransport(server: server, account: "other-owner"))
        let otherInvitation = try await other.store.createChildInvitation(memberID: other.hanna.id)
        let mismatch = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                          transport: TestTransport(server: server, account: "mismatch"),
                                          clock: { family.clock.now }, automaticSync: false)
        await XCTAssertThrowsErrorAsync(
            try await mismatch.join(url: otherInvitation.shareURL, invitationCode: revoked.code),
            expected: .invitationNotFound
        )
        XCTAssertNil(mismatch.household)
        XCTAssertFalse(server.zones[otherInvitation.shareURL.lastPathComponent]!.participants.contains("mismatch"))

        let childInvitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let parentInvitation = try await family.store.createParentInvitation(name: "Different Parent", avatar: .fox)
        let mixedCredential = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                                  transport: TestTransport(server: server, account: "mixed"),
                                                  clock: { family.clock.now }, automaticSync: false)
        await XCTAssertThrowsErrorAsync(
            try await mixedCredential.join(url: childInvitation.shareURL, invitationCode: parentInvitation.code),
            expected: .invitationNotFound
        )
        XCTAssertNil(mixedCredential.household)
        XCTAssertFalse(server.zones[childInvitation.shareURL.lastPathComponent]!.participants.contains("mixed"))

        let unavailable = try await family.store.createChildInvitation(memberID: family.hanna.id)
        try family.store.archiveMember(family.hanna.id)
        try await family.store.synchronize()
        family.move(to: "2026-09-08T15:00:00Z")
        let archivedProfile = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                                  transport: TestTransport(server: server, account: "archived"),
                                                  clock: { family.clock.now }, automaticSync: false)
        await XCTAssertThrowsErrorAsync(try await archivedProfile.redeemInvitation(unavailable.qrPayload),
                                        expected: .invitationUnavailable)
        XCTAssertNil(archivedProfile.household)
        XCTAssertFalse(server.zones[unavailable.shareURL.lastPathComponent]!.participants.contains("archived"))
    }

    func testFailedRedemptionPersistsCleanupUntilCloudLeaveConverges() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let repository = try HouseholdRepository(inMemory: true)
        let transport = TestTransport(server: server, account: "joining-child")
        transport.leaveFailures = 1
        var joining: HouseholdStore? = try HouseholdStore(repository: repository, transport: transport,
                                                           clock: { family.clock.now }, automaticSync: false)

        await XCTAssertThrowsErrorAsync(
            try await joining!.join(url: invitation.shareURL, invitationCode: "2345-6789-AB"),
            expected: .invitationNotFound
        )
        XCTAssertNil(joining!.household)
        XCTAssertNil(joining!.selectedMember)
        XCTAssertEqual(joining!.session.pendingInvitationAcceptance?.phase, .cleanupRequired)
        XCTAssertTrue(try repository.facts(householdID: invitation.invitation.householdID).isEmpty)
        XCTAssertTrue(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains("joining-child"))

        joining = try HouseholdStore(repository: repository, transport: transport,
                                     clock: { family.clock.now }, automaticSync: false)
        transport.account = "different-account"
        await XCTAssertThrowsErrorAsync(try await joining!.retryInvitationCleanup(), expected: .wrongAccount)
        XCTAssertEqual(joining!.session.pendingInvitationAcceptance?.phase, .cleanupRequired)
        XCTAssertEqual(transport.leaveAttempts, 1)
        XCTAssertTrue(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains("joining-child"))

        transport.account = "joining-child"
        try await joining!.retryInvitationCleanup()
        XCTAssertNil(joining!.session.pendingInvitationAcceptance)
        XCTAssertFalse(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains("joining-child"))
        XCTAssertEqual(transport.leaveAttempts, 2)
    }

    func testScheduledCleanupRetriesLeaveAndLockReleaseWithoutRelaunch() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "joining-child")
        transport.leaveFailures = 2
        transport.accountLockReleaseFailures = 1
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)

        await XCTAssertThrowsErrorAsync(
            try await joining.join(url: invitation.shareURL, invitationCode: "2345-6789-AB"),
            expected: .invitationNotFound
        )
        XCTAssertEqual(joining.session.pendingInvitationAcceptance?.phase, .cleanupRequired)
        XCTAssertNotNil(joining.pendingInvitationCleanupID)

        for _ in 0..<2 {
            let cleanupDelay = try await joining.pendingInvitationCleanupDelay()
            let retryDelay = try await joining.retryScheduledInvitationCleanup()
            XCTAssertEqual(cleanupDelay, 30)
            XCTAssertEqual(retryDelay, 30)
            XCTAssertEqual(joining.session.pendingInvitationAcceptance?.phase, .cleanupRequired)
        }
        let finalCleanupDelay = try await joining.pendingInvitationCleanupDelay()
        let finalRetryDelay = try await joining.retryScheduledInvitationCleanup()
        XCTAssertEqual(finalCleanupDelay, 30)
        XCTAssertNil(finalRetryDelay)

        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertNil(joining.pendingInvitationCleanupID)
        XCTAssertEqual(server.accountMembershipLocks["joining-child"]?.state, .released)
        XCTAssertFalse(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains("joining-child"))
    }

    func testAccountChangeResumesCleanupAndRepeatedAttemptsConverge() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "joining-child")
        transport.leaveFailures = 1
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        await XCTAssertThrowsErrorAsync(
            try await joining.join(url: invitation.shareURL, invitationCode: "2345-6789-AB"),
            expected: .invitationNotFound
        )
        XCTAssertEqual(joining.session.pendingInvitationAcceptance?.phase, .cleanupRequired)
        XCTAssertEqual(transport.leaveAttempts, 1)

        transport.account = "different-account"
        await XCTAssertThrowsErrorAsync(try await joining.retryScheduledInvitationCleanup(), expected: .wrongAccount)
        XCTAssertEqual(transport.leaveAttempts, 1)
        XCTAssertNotNil(joining.session.pendingInvitationAcceptance)

        transport.account = "joining-child"
        transport.beforeLeave = { await Task.yield() }
        async let firstRetry = joining.retryScheduledInvitationCleanup()
        async let repeatedRetry = joining.retryScheduledInvitationCleanup()
        let retryResults = try await (firstRetry, repeatedRetry)

        XCTAssertNil(retryResults.0)
        XCTAssertNil(retryResults.1)
        XCTAssertEqual(transport.leaveAttempts, 2)
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertEqual(server.accountMembershipLocks["joining-child"]?.state, .released)

        let settledRetry = try await joining.retryScheduledInvitationCleanup()
        XCTAssertNil(settledRetry)
        XCTAssertEqual(transport.leaveAttempts, 2)
    }

    func testCleanupCancellationDuringValidationRetainsPendingAccess() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "joining-child")
        transport.leaveFailures = 1
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        await XCTAssertThrowsErrorAsync(
            try await joining.join(url: invitation.shareURL, invitationCode: "2345-6789-AB"),
            expected: .invitationNotFound
        )

        transport.beforeFetch = { withUnsafeCurrentTask { $0?.cancel() } }
        let cleanup = Task { try await joining.retryInvitationCleanup() }
        do {
            try await cleanup.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }

        XCTAssertNotNil(joining.session.pendingInvitationAcceptance)
        XCTAssertTrue(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains("joining-child"))
        XCTAssertEqual(server.accountMembershipLocks["joining-child"]?.state, .provisional)
    }

    func testCleanupCancellationDuringLeaveDoesNotMutateAccess() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "joining-child")
        transport.leaveFailures = 1
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        await XCTAssertThrowsErrorAsync(
            try await joining.join(url: invitation.shareURL, invitationCode: "2345-6789-AB"),
            expected: .invitationNotFound
        )

        transport.beforeLeave = { withUnsafeCurrentTask { $0?.cancel() } }
        let cleanup = Task { try await joining.retryInvitationCleanup() }
        do {
            try await cleanup.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }

        XCTAssertNotNil(joining.session.pendingInvitationAcceptance)
        XCTAssertTrue(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains("joining-child"))
        XCTAssertEqual(server.accountMembershipLocks["joining-child"]?.state, .provisional)
    }

    func testCleanupRevalidatesAccountBeforeLeaveAndLockRelease() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "joining-child")
        transport.leaveFailures = 1
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        await XCTAssertThrowsErrorAsync(
            try await joining.join(url: invitation.shareURL, invitationCode: "2345-6789-AB"),
            expected: .invitationNotFound
        )

        transport.beforeLeave = { transport.account = "different-account" }
        await XCTAssertThrowsErrorAsync(try await joining.retryInvitationCleanup(), expected: .wrongAccount)
        XCTAssertTrue(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains("joining-child"))
        XCTAssertNil(server.accountMembershipLocks["different-account"])

        transport.account = "joining-child"
        transport.beforeLeave = nil
        transport.beforeAccountLockRelease = { transport.account = "different-account" }
        await XCTAssertThrowsErrorAsync(try await joining.retryInvitationCleanup(), expected: .wrongAccount)
        XCTAssertFalse(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains("joining-child"))
        XCTAssertEqual(server.accountMembershipLocks["joining-child"]?.state, .provisional)
        XCTAssertNil(server.accountMembershipLocks["different-account"])

        transport.account = "joining-child"
        transport.beforeAccountLockRelease = nil
        try await joining.retryInvitationCleanup()
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertEqual(server.accountMembershipLocks["joining-child"]?.state, .released)
    }

    func testCleanupAbortsWhenAccountChangesAfterValidationBeforeSubmission() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let zoneName = invitation.shareURL.lastPathComponent
        let transport = TestTransport(server: server, account: "joining-child")
        transport.leaveFailures = 1
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        await XCTAssertThrowsErrorAsync(
            try await joining.join(url: invitation.shareURL, invitationCode: "2345-6789-AB"),
            expected: .invitationNotFound
        )
        server.zones[zoneName]?.participants.insert("other-child")
        let leaveEnqueues = transport.leaveMutationEnqueues

        transport.beforeLeaveSubmission = {
            transport.account = "other-child"
            transport.account = "joining-child"
        }
        await XCTAssertThrowsErrorAsync(try await joining.retryInvitationCleanup(), expected: .wrongAccount)

        XCTAssertTrue(server.zones[zoneName]!.participants.contains("joining-child"))
        XCTAssertTrue(server.zones[zoneName]!.participants.contains("other-child"))
        XCTAssertEqual(server.accountMembershipLocks["joining-child"]?.state, .provisional)
        XCTAssertNotNil(joining.session.pendingInvitationAcceptance)
        XCTAssertEqual(transport.leaveMutationEnqueues, leaveEnqueues)

        transport.beforeLeaveSubmission = nil
        let lockEnqueues = transport.accountLockMutationEnqueues
        transport.beforeAccountLockReleaseSubmission = {
            transport.account = "other-child"
            transport.account = "joining-child"
        }
        await XCTAssertThrowsErrorAsync(try await joining.retryInvitationCleanup(), expected: .wrongAccount)
        XCTAssertFalse(server.zones[zoneName]!.participants.contains("joining-child"))
        XCTAssertTrue(server.zones[zoneName]!.participants.contains("other-child"))
        XCTAssertEqual(server.accountMembershipLocks["joining-child"]?.state, .provisional)
        XCTAssertNotNil(joining.session.pendingInvitationAcceptance)
        XCTAssertEqual(transport.accountLockMutationEnqueues, lockEnqueues)
    }

    func testCleanupCancellationBeforeLockReleaseRetainsPendingAttempt() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "joining-child")
        transport.leaveFailures = 1
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        await XCTAssertThrowsErrorAsync(
            try await joining.join(url: invitation.shareURL, invitationCode: "2345-6789-AB"),
            expected: .invitationNotFound
        )

        transport.beforeAccountLockRelease = { withUnsafeCurrentTask { $0?.cancel() } }
        let cleanup = Task { try await joining.retryInvitationCleanup() }
        do {
            try await cleanup.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }

        XCTAssertNotNil(joining.session.pendingInvitationAcceptance)
        XCTAssertFalse(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains("joining-child"))
        XCTAssertEqual(server.accountMembershipLocks["joining-child"]?.state, .provisional)

        transport.beforeAccountLockRelease = nil
        try await joining.retryInvitationCleanup()
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertEqual(server.accountMembershipLocks["joining-child"]?.state, .released)
    }

    func testSameAccountInvitationReuseRecoversExactMembership() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let firstTransport = TestTransport(server: server, account: "shared-account")
        let first = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: firstTransport,
                                       clock: { family.clock.now }, automaticSync: false)
        try await first.redeemInvitation(invitation.qrPayload)

        let secondRepository = try HouseholdRepository(inMemory: true)
        let secondTransport = TestTransport(server: server, account: "shared-account")
        let second = try HouseholdStore(repository: secondRepository, transport: secondTransport,
                                        clock: { family.clock.now }, automaticSync: false)
        try await second.redeemInvitation(invitation.qrPayload)
        XCTAssertEqual(second.household?.id, family.store.household?.id)
        XCTAssertEqual(second.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(second.profiles.map(\.id), [family.hanna.id])
        XCTAssertNil(second.session.pendingInvitationAcceptance)
        XCTAssertEqual(secondTransport.leaveAttempts, 0)
        XCTAssertTrue(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains("shared-account"))
        try await first.synchronize()
        XCTAssertEqual(first.selectedMember?.id, family.hanna.id)
    }

    func testCleanupDefersToConcurrentSameAccountMembershipClaim() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let first = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                       transport: TestTransport(server: server, account: "shared-account"),
                                       clock: { family.clock.now }, automaticSync: false)
        let secondTransport = TestTransport(server: server, account: "shared-account")
        let secondRepository = try HouseholdRepository(inMemory: true)
        let second = try HouseholdStore(repository: secondRepository,
                                        transport: secondTransport, clock: { family.clock.now }, automaticSync: false)
        var firstError: Error?
        var observedProvisionalState = false
        secondTransport.beforeAccept = {
            let pending = try? secondRepository.session().pendingInvitationAcceptance
            observedProvisionalState = pending?.phase == .acceptingAccess
                && pending?.accessExistedBeforeAttempt == false
            do { try await first.redeemInvitation(invitation.qrPayload) }
            catch { firstError = error }
        }
        secondTransport.acceptErrorAfterHook = CKError(.networkFailure)

        do {
            try await second.redeemInvitation(invitation.qrPayload)
            XCTFail("The interrupted acceptance should report its transport error")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }
        XCTAssertEqual(firstError as? HouseholdError, .accountMembershipConflict)
        XCTAssertTrue(observedProvisionalState)
        XCTAssertNil(first.selectedMember)
        XCTAssertNil(second.selectedMember)
        XCTAssertEqual(secondTransport.leaveAttempts, 1)
        XCTAssertFalse(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains("shared-account"))
    }

    func testFailedRedemptionPreservesPreexistingAppleAccess() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let account = "existing-participant"
        server.zones[invitation.shareURL.lastPathComponent]?.participants.insert(account)
        let transport = TestTransport(server: server, account: account)
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)

        await XCTAssertThrowsErrorAsync(
            try await joining.join(url: invitation.shareURL, invitationCode: "2345-6789-AB"),
            expected: .invitationNotFound
        )

        XCTAssertEqual(transport.leaveAttempts, 0)
        XCTAssertTrue(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains(account))
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertEqual(server.accountMembershipLocks[account]?.state, .released)
    }

    func testClaimTransportFailureRetainsAccessAndRetries() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let account = "retrying-child"
        let transport = TestTransport(server: server, account: account)
        transport.claimError = CKError(.networkFailure)
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)

        do {
            try await joining.redeemInvitation(invitation.qrPayload)
            XCTFail("The interrupted claim should remain retryable")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }

        XCTAssertEqual(joining.session.pendingInvitationAcceptance?.phase, .awaitingRedemption)
        XCTAssertEqual(transport.leaveAttempts, 0)
        XCTAssertTrue(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains(account))
        transport.claimError = nil
        try await joining.redeemInvitation(invitation.code)
        XCTAssertEqual(joining.selectedMember?.id, family.hanna.id)
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
    }

    func testRevokedGenerationAllowsRejoinWithoutReactivatingStaleDevice() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let firstInvitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let account = "returning-child"
        let first = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                       transport: TestTransport(server: server, account: account),
                                       clock: { family.clock.now }, automaticSync: false)
        try await first.redeemInvitation(firstInvitation.qrPayload)
        let oldBinding = first.session.accountMembershipClaimBinding
        try await family.store.revokeInvitation(firstInvitation.invitation)

        let secondInvitation = try await family.store.createChildInvitation(memberID: family.alek.id)
        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: TestTransport(server: server, account: account),
                                             clock: { family.clock.now }, automaticSync: false)
        try await replacement.redeemInvitation(secondInvitation.qrPayload)

        XCTAssertEqual(replacement.selectedMember?.id, family.alek.id)
        XCTAssertNotEqual(replacement.session.accountMembershipClaimBinding, oldBinding)
        do { try await first.synchronize(); XCTFail("The revoked generation must stay closed") }
        catch { XCTAssertEqual(error as? HouseholdError, .accountMembershipConflict) }
        XCTAssertEqual(first.selectedMember?.id, family.hanna.id)
        XCTAssertTrue(first.cloudIsReadOnly)
        XCTAssertThrowsError(try first.selectProfile(family.alek.id))
    }

    func testOwnerRecoveryFindsExactUnambiguousMembership() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        try await family.store.connect()
        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: TestTransport(server: server, account: "owner"),
                                             clock: { family.clock.now }, automaticSync: false)

        let families = try await replacement.discoverOwnerRecoveries()
        XCTAssertEqual(families.map(\.location.householdID), [family.store.household!.id])
        try await replacement.recoverOwnerFamily(try XCTUnwrap(families.first).location)

        XCTAssertEqual(replacement.selectedMember?.id, family.parent.id)
        XCTAssertEqual(replacement.profiles.map(\.id), [family.parent.id])
    }

    func testOwnerRecoveryRejectsAmbiguousLegacyParents() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        _ = try family.store.saveMember(name: "Other Parent", role: .parent, avatar: .star)
        try await family.store.connect()
        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: TestTransport(server: server, account: "owner"),
                                             clock: { family.clock.now }, automaticSync: false)
        let recoveries = try await replacement.discoverOwnerRecoveries()
        XCTAssertTrue(recoveries.isEmpty)
    }

    func testUnclaimedInvitedParentDoesNotMakeOwnerRecoveryAmbiguous() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        _ = try await family.store.createParentInvitation(name: "Invited Parent", avatar: .fox)
        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: TestTransport(server: server, account: "owner"),
                                             clock: { family.clock.now }, automaticSync: false)

        let recoveries = try await replacement.discoverOwnerRecoveries()

        XCTAssertEqual(recoveries.map(\.location.householdID), [family.store.household!.id])
        try await replacement.recoverOwnerFamily(try XCTUnwrap(recoveries.first).location)
        XCTAssertEqual(replacement.selectedMember?.id, family.parent.id)
    }

    func testExpiredUnclaimedInvitedParentDoesNotMakeOwnerRecoveryAmbiguous() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createParentInvitation(name: "Expired Parent", avatar: .fox)
        server.authoritativeTime = invitation.invitation.expiresAt.addingTimeInterval(1)
        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: TestTransport(server: server, account: "owner"),
                                             clock: { family.clock.now }, automaticSync: false)

        let recoveries = try await replacement.discoverOwnerRecoveries()

        XCTAssertEqual(recoveries.map(\.location.householdID), [family.store.household!.id])
        try await replacement.recoverOwnerFamily(try XCTUnwrap(recoveries.first).location)
        XCTAssertEqual(replacement.selectedMember?.id, family.parent.id)
    }

    func testOwnerRecoveryDiscoveryLeavesAmbiguousLegacyHouseholdsUnlocked() async throws {
        let server = TestCloudServer()
        let first = try TestFamily(transport: TestTransport(server: server, account: "legacy-owner"))
        try await first.store.connect()
        server.accountMembershipLocks.removeValue(forKey: "legacy-owner")
        let second = try TestFamily(transport: TestTransport(server: server, account: "legacy-owner"))
        try await second.store.connect()
        server.accountMembershipLocks.removeValue(forKey: "legacy-owner")
        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: TestTransport(server: server, account: "legacy-owner"),
                                             clock: { first.clock.now }, automaticSync: false)

        let recoveries = try await replacement.discoverOwnerRecoveries()
        XCTAssertTrue(recoveries.isEmpty)
        XCTAssertNil(server.accountMembershipLocks["legacy-owner"])
    }

    func testActiveOwnerLockDisambiguatesMultipleLegacyHouseholds() async throws {
        let server = TestCloudServer()
        let first = try TestFamily(transport: TestTransport(server: server, account: "legacy-owner"))
        try await first.store.connect()
        let firstLock = try XCTUnwrap(server.accountMembershipLocks["legacy-owner"])
        server.accountMembershipLocks.removeValue(forKey: "legacy-owner")
        let second = try TestFamily(transport: TestTransport(server: server, account: "legacy-owner"))
        try await second.store.connect()
        server.accountMembershipLocks["legacy-owner"] = firstLock
        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: TestTransport(server: server, account: "legacy-owner"),
                                             clock: { first.clock.now }, automaticSync: false)

        let recoveries = try await replacement.discoverOwnerRecoveries()

        XCTAssertEqual(recoveries.map(\.location.householdID), [first.store.household!.id])
        XCTAssertEqual(server.accountMembershipLocks["legacy-owner"], firstLock)
    }

    func testOwnerRecoveryRetriesActivationWithPersistedAttempt() async throws {
        let server = TestCloudServer()
        let ownerTransport = TestTransport(server: server, account: "legacy-owner")
        let family = try TestFamily(transport: ownerTransport)
        try await family.store.connect()
        server.accountMembershipLocks.removeValue(forKey: "legacy-owner")
        let recoveryTransport = TestTransport(server: server, account: "legacy-owner")
        recoveryTransport.accountLockActivationFailures = 1
        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: recoveryTransport,
                                             clock: { family.clock.now }, automaticSync: false)
        let recoveries = try await replacement.discoverOwnerRecoveries()
        let recovery = try XCTUnwrap(recoveries.first)

        do {
            try await replacement.recoverOwnerFamily(recovery.location)
            XCTFail("The first activation must fail")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }
        let attemptID = try XCTUnwrap(replacement.session.accountMembershipLockAttemptID)
        XCTAssertEqual(server.accountMembershipLocks["legacy-owner"]?.attemptID, attemptID)
        XCTAssertEqual(server.accountMembershipLocks["legacy-owner"]?.state, .provisional)

        try await replacement.recoverOwnerFamily(recovery.location)

        XCTAssertEqual(replacement.selectedMember?.id, family.parent.id)
        XCTAssertEqual(replacement.session.accountMembershipLockAttemptID, attemptID)
        XCTAssertEqual(server.accountMembershipLocks["legacy-owner"]?.state, .active)
    }

    func testOwnerRecoverySelectionRevalidatesMembershipLockRace() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        try await family.store.connect()
        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: TestTransport(server: server, account: "owner"),
                                             clock: { family.clock.now }, automaticSync: false)
        let recoveries = try await replacement.discoverOwnerRecoveries()
        let candidate = try XCTUnwrap(recoveries.first)
        let competing = AccountMembershipLock(householdID: family.store.household!.id,
                                              attemptID: UUID(), state: .active,
                                              expiresAt: .distantFuture, claimBinding: "competing-membership")
        server.accountMembershipLocks["owner"] = competing

        await XCTAssertThrowsErrorAsync(try await replacement.recoverOwnerFamily(candidate.location),
                                        expected: .accountMembershipConflict)
        XCTAssertEqual(server.accountMembershipLocks["owner"], competing)
        XCTAssertNil(replacement.household)
    }

    func testInvitationIssuanceUsesServerTimeDespiteOwnerClockSkew() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: transport)
        family.clock.set("2027-09-07T16:00:00Z")
        server.authoritativeTime = ISO8601DateFormatter().date(from: "2026-09-07T16:00:00Z")!

        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)

        XCTAssertEqual(invitation.invitation.createdAt, server.authoritativeTime)
        XCTAssertEqual(invitation.invitation.expiresAt,
                       server.authoritativeTime!.addingTimeInterval(InvitationCode.lifetime))
    }

    func testParentInvitationUsesServerJoinedDayWhenOwnerClockIsAhead() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        family.move(to: "2026-09-09T16:00:00Z")
        server.authoritativeTime = ISO8601DateFormatter().date(from: "2026-09-08T16:00:00Z")!

        let invitation = try await family.store.createParentInvitation(name: "Parent B", avatar: .fox)
        let invitedMember = try XCTUnwrap(family.store.snapshot.member(invitation.invitation.memberID))
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                         transport: TestTransport(server: server, account: "parent-b"),
                                         clock: { server.authoritativeTime! }, automaticSync: false)

        try await joining.redeemInvitation(invitation.qrPayload)

        XCTAssertEqual(invitedMember.joinedDay, CivilDay(server.authoritativeTime!, calendar: family.store.calendar))
        XCTAssertEqual(joining.selectedMember?.id, invitedMember.id)
    }

    func testParentInvitationUsesServerJoinedDayWhenOwnerClockIsBehind() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        server.authoritativeTime = ISO8601DateFormatter().date(from: "2026-09-08T16:00:00Z")!

        let invitation = try await family.store.createParentInvitation(name: "Parent B", avatar: .fox)
        let invitedMember = try XCTUnwrap(family.store.snapshot.member(invitation.invitation.memberID))
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                         transport: TestTransport(server: server, account: "parent-b"),
                                         clock: { server.authoritativeTime! }, automaticSync: false)

        try await joining.redeemInvitation(invitation.qrPayload)

        XCTAssertEqual(invitedMember.joinedDay, CivilDay(server.authoritativeTime!, calendar: family.store.calendar))
        XCTAssertEqual(joining.selectedMember?.id, invitedMember.id)
    }

    func testParentInvitationAttachAndCommittedRecoveryIgnoreJoinerClockSkew() async throws {
        for joinerTime in ["2026-09-07T16:00:00Z", "2026-09-09T16:00:00Z"] {
            let server = TestCloudServer()
            let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
            server.authoritativeTime = ISO8601DateFormatter().date(from: "2026-09-08T16:00:00Z")!
            let invitation = try await family.store.createParentInvitation(name: "Parent B", avatar: .fox)
            let invitedMember = try XCTUnwrap(family.store.snapshot.member(invitation.invitation.memberID))
            let clock = TestClock(joinerTime)
            let transport = TestTransport(server: server, account: "parent-b")
            let joined = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                            clock: { clock.now }, automaticSync: false)

            try await joined.redeemInvitation(invitation.qrPayload)

            XCTAssertEqual(joined.session.selectedMemberID, invitedMember.id)
            XCTAssertNil(joined.session.pendingInvitationAcceptance)
            XCTAssertTrue(server.zones[invitation.shareURL.lastPathComponent]!.facts.values.contains {
                if case .invitationClaim(let claim) = $0.body { return claim.invitationID == invitation.invitation.id }
                return false
            })

            clock.set(joinerTime == "2026-09-07T16:00:00Z"
                      ? "2026-09-09T16:00:00Z" : "2026-09-07T16:00:00Z")
            let recovered = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                               clock: { clock.now }, automaticSync: false)
            try await recovered.redeemInvitation(invitation.qrPayload)
            XCTAssertEqual(recovered.session.selectedMemberID, invitedMember.id)
        }
    }

    func testChildInvitationAttachAndCommittedRecoveryIgnoreJoinerClockSkew() async throws {
        for joinerTime in ["2026-09-06T16:00:00Z", "2026-09-09T16:00:00Z"] {
            let server = TestCloudServer()
            let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
            server.authoritativeTime = ISO8601DateFormatter().date(from: "2026-09-08T16:00:00Z")!
            let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
            let clock = TestClock(joinerTime)
            let transport = TestTransport(server: server, account: "child")
            let joined = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                            clock: { clock.now }, automaticSync: false)

            try await joined.redeemInvitation(invitation.qrPayload)

            XCTAssertEqual(joined.session.selectedMemberID, family.hanna.id)
            XCTAssertNil(joined.session.pendingInvitationAcceptance)
            XCTAssertTrue(server.zones[invitation.shareURL.lastPathComponent]!.facts.values.contains {
                if case .invitationClaim(let claim) = $0.body { return claim.invitationID == invitation.invitation.id }
                return false
            })

            clock.set(joinerTime == "2026-09-06T16:00:00Z"
                      ? "2026-09-09T16:00:00Z" : "2026-09-06T16:00:00Z")
            let recovered = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                               clock: { clock.now }, automaticSync: false)
            try await recovered.redeemInvitation(invitation.qrPayload)
            XCTAssertEqual(recovered.session.selectedMemberID, family.hanna.id)
        }
    }

    func testInvitationPruningDoesNotRevokeValidAccessWhenOwnerClockIsAhead() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        family.clock.set("2027-09-07T16:00:00Z")
        server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(60)

        _ = try await family.store.createChildInvitation(memberID: family.alek.id)

        let zone = try XCTUnwrap(server.zones[family.store.session.location!.zoneName])
        XCTAssertTrue(zone.pendingInvitationParticipants.contains(invitation.invitation.cloudShareParticipantID))
    }

    func testInvitationPruningRevokesExpiredAccessWhenOwnerClockIsBehind() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        family.clock.set("2026-09-07T16:00:00Z")
        server.authoritativeTime = invitation.invitation.expiresAt.addingTimeInterval(1)

        _ = try await family.store.createChildInvitation(memberID: family.alek.id)

        let zone = try XCTUnwrap(server.zones[family.store.session.location!.zoneName])
        XCTAssertFalse(zone.pendingInvitationParticipants.contains(invitation.invitation.cloudShareParticipantID))
    }

    func testRevokedInvitedParentDoesNotMakeOwnerRecoveryAmbiguous() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createParentInvitation(name: "Invited Parent", avatar: .fox)
        let invited = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                         transport: TestTransport(server: server, account: "invited-parent"),
                                         clock: { family.clock.now }, automaticSync: false)
        try await invited.redeemInvitation(invitation.qrPayload)
        try await family.store.synchronize()
        try await family.store.revokeInvitation(invitation.invitation)
        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: TestTransport(server: server, account: "owner"),
                                             clock: { family.clock.now }, automaticSync: false)

        let recoveries = try await replacement.discoverOwnerRecoveries()
        XCTAssertEqual(recoveries.map(\.location.householdID), [family.store.household!.id])
        try await replacement.recoverOwnerFamily(try XCTUnwrap(recoveries.first).location)
        XCTAssertEqual(replacement.selectedMember?.id, family.parent.id)
    }

    func testServerTimePreventsDeviceClockRollbackExtendingInvitation() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        server.authoritativeTime = invitation.invitation.expiresAt.addingTimeInterval(1)
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                         transport: TestTransport(server: server, account: "late-child"),
                                         clock: { invitation.invitation.createdAt.addingTimeInterval(-86_400) },
                                         automaticSync: false)

        await XCTAssertThrowsErrorAsync(try await joining.redeemInvitation(invitation.qrPayload),
                                        expected: .invitationExpired)
        XCTAssertNil(joining.household)
        XCTAssertFalse(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains("late-child"))
    }

    func testDefinitiveClaimFailureCleansUpImmediately() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "removed-child")
        transport.claimError = CKError(.permissionFailure)
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)

        do { try await joining.redeemInvitation(invitation.qrPayload); XCTFail("Permission loss must fail") }
        catch { XCTAssertEqual((error as? CKError)?.code, .permissionFailure) }
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertEqual(transport.leaveAttempts, 1)
        XCTAssertFalse(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains("removed-child"))
    }

    func testAccountMembershipLockAtomicallyExcludesConcurrentCrossHouseholdJoin() async throws {
        let server = TestCloudServer()
        let first = try TestFamily(transport: TestTransport(server: server, account: "first-owner"))
        let firstInvitation = try await first.store.createChildInvitation(memberID: first.hanna.id)
        let second = try TestFamily(transport: TestTransport(server: server, account: "second-owner"))
        let secondInvitation = try await second.store.createChildInvitation(memberID: second.hanna.id)
        let firstTransport = TestTransport(server: server, account: "shared-account")
        let secondTransport = TestTransport(server: server, account: "shared-account")
        let firstJoin = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                           transport: firstTransport, clock: { first.clock.now },
                                           automaticSync: false)
        let secondJoin = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                            transport: secondTransport, clock: { first.clock.now },
                                            automaticSync: false)
        var secondError: Error?
        firstTransport.beforeAccept = {
            do { try await secondJoin.redeemInvitation(secondInvitation.qrPayload) }
            catch { secondError = error }
        }

        try await firstJoin.redeemInvitation(firstInvitation.qrPayload)

        XCTAssertEqual(secondError as? HouseholdError, .accountMembershipConflict)
        XCTAssertEqual(firstJoin.selectedMember?.id, first.hanna.id)
        XCTAssertNil(secondJoin.household)
        XCTAssertFalse(server.zones[secondInvitation.shareURL.lastPathComponent]!.participants.contains("shared-account"))
    }

    func testAccountMembershipLockSupportsContinuationStaleRecoveryAndConditionalRelease() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "shared-account")
        let household = UUID()
        let otherHousehold = UUID()
        let attempt = UUID()
        let member = UUID()
        let invitation = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let provisional = try await transport.acquireAccountMembershipLock(
            householdID: household, attemptID: attempt, leaseDuration: 60, clientTime: now
        )
        XCTAssertEqual(provisional.state, .provisional)
        let active = try await transport.activateAccountMembershipLock(
            householdID: household, attemptID: attempt,
            claimBinding: "binding-\(invitation)-\(member)", now: now
        )
        let continuation = try await transport.acquireAccountMembershipLock(
            householdID: household, attemptID: UUID(), leaseDuration: 60, clientTime: now
        )
        XCTAssertEqual(continuation, active)
        await XCTAssertThrowsErrorAsync(
            try await transport.activateAccountMembershipLock(
                householdID: household, attemptID: continuation.attemptID,
                claimBinding: "different-binding", now: now
            ),
            expected: .accountMembershipConflict
        )
        let mismatchedRelease = try await transport.releaseAccountMembershipLock(
            householdID: household, attemptID: UUID(), expectedParticipantID: "shared-account", now: now
        )
        XCTAssertFalse(mismatchedRelease)
        XCTAssertEqual(server.accountMembershipLocks["shared-account"]?.state, .active)
        let matchingRelease = try await transport.releaseAccountMembershipLock(
            householdID: household, attemptID: attempt, expectedParticipantID: "shared-account", now: now
        )
        XCTAssertTrue(matchingRelease)
        XCTAssertEqual(server.accountMembershipLocks["shared-account"]?.state, .released)

        let staleAttempt = UUID()
        _ = try await transport.acquireAccountMembershipLock(
            householdID: household, attemptID: staleAttempt, leaseDuration: 10, clientTime: now
        )
        let retained = try await transport.acquireAccountMembershipLock(
            householdID: otherHousehold, attemptID: UUID(), leaseDuration: 120,
            clientTime: now.addingTimeInterval(11)
        )
        XCTAssertEqual(retained.householdID, household)
        XCTAssertEqual(retained.attemptID, staleAttempt)

        let otherAccount = TestTransport(server: server, account: "different-account")
        let isolated = try await otherAccount.acquireAccountMembershipLock(
            householdID: household, attemptID: UUID(), leaseDuration: 60, clientTime: now
        )
        XCTAssertEqual(isolated.householdID, household)
    }

    func testOwnerConnectionAcquiresLockAndBlocksSecondHousehold() async throws {
        let server = TestCloudServer()
        let first = try TestFamily(transport: TestTransport(server: server, account: "shared-owner"))
        try await first.store.connect()
        XCTAssertEqual(server.accountMembershipLocks["shared-owner"]?.householdID, first.store.household?.id)
        XCTAssertEqual(server.accountMembershipLocks["shared-owner"]?.state, .active)

        let second = try TestFamily(transport: TestTransport(server: server, account: "shared-owner"))
        await XCTAssertThrowsErrorAsync(try await second.store.connect(), expected: .accountMembershipConflict)
        XCTAssertNil(second.store.session.location)
        XCTAssertEqual(second.store.household?.id, try second.repository.session().householdID)
        XCTAssertEqual(server.createCalls, 1)
    }

    func testLegacyOwnerMigrationBackfillsLockAndPreservesConflictReadOnly() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "legacy-owner")
        let family = try TestFamily(transport: transport)
        try await family.store.connect()
        server.accountMembershipLocks.removeValue(forKey: "legacy-owner")
        var migratedSession = family.store.session
        migratedSession.accountMembershipLockAttemptID = nil
        try family.repository.commit(facts: [], session: migratedSession)
        let reopened = try HouseholdStore(repository: family.repository, transport: transport,
                                          clock: { family.clock.now }, automaticSync: false)
        try await reopened.reconcileAccountMembershipLock()
        XCTAssertEqual(server.accountMembershipLocks["legacy-owner"]?.state, .active)
        XCTAssertEqual(server.accountMembershipLocks["legacy-owner"]?.householdID, family.store.household?.id)

        let otherHousehold = UUID()
        server.accountMembershipLocks["legacy-owner"] = AccountMembershipLock(
            householdID: otherHousehold, attemptID: UUID(), state: .active,
            expiresAt: .distantFuture, claimBinding: "other-membership"
        )
        await XCTAssertThrowsErrorAsync(try await reopened.reconcileAccountMembershipLock(),
                                        expected: .accountMembershipConflict)
        XCTAssertTrue(reopened.cloudIsReadOnly)
        XCTAssertEqual(reopened.household?.id, family.store.household?.id)
        XCTAssertEqual(server.accountMembershipLocks["legacy-owner"]?.householdID, otherHousehold)
    }

    func testExpiredProvisionalLockRequiresDefinitiveAccessAbsenceBeforeTakeover() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let oldHousehold = UUID()
        let oldAttempt = UUID()
        server.accountMembershipLocks["joining"] = AccountMembershipLock(
            householdID: oldHousehold, attemptID: oldAttempt, state: .provisional,
            expiresAt: family.clock.now.addingTimeInterval(-1), claimBinding: nil
        )
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                         transport: TestTransport(server: server, account: "joining"),
                                         clock: { family.clock.now }, automaticSync: false)
        try await joining.redeemInvitation(invitation.qrPayload)
        XCTAssertEqual(joining.selectedMember?.id, family.hanna.id)

        let blockedAccount = "blocked"
        let blockedAttempt = UUID()
        server.accountMembershipLocks[blockedAccount] = AccountMembershipLock(
            householdID: oldHousehold, attemptID: blockedAttempt, state: .provisional,
            expiresAt: family.clock.now.addingTimeInterval(-1), claimBinding: nil
        )
        let oldZone = "EarnedIt-\(oldHousehold.uuidString)"
        server.zones[oldZone] = TestCloudServer.Zone(householdID: oldHousehold, name: "Unreconciled",
                                                     owner: blockedAccount)
        let blocked = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                         transport: TestTransport(server: server, account: blockedAccount),
                                         clock: { family.clock.now }, automaticSync: false)
        await XCTAssertThrowsErrorAsync(try await blocked.redeemInvitation(invitation.qrPayload),
                                        expected: .accountMembershipConflict)
        XCTAssertEqual(server.accountMembershipLocks[blockedAccount]?.attemptID, blockedAttempt)
    }

    func testExpiredProvisionalLockReconcilesCommittedClaimForSameHouseholdRecovery() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let account = "recovering-child"
        let first = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                       transport: TestTransport(server: server, account: account),
                                       clock: { family.clock.now }, automaticSync: false)
        try await first.redeemInvitation(invitation.qrPayload)
        var interrupted = try XCTUnwrap(server.accountMembershipLocks[account])
        interrupted.state = .provisional
        interrupted.expiresAt = family.clock.now.addingTimeInterval(-1)
        interrupted.claimBinding = nil
        server.accountMembershipLocks[account] = interrupted

        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: TestTransport(server: server, account: account),
                                             clock: { family.clock.now }, automaticSync: false)
        try await replacement.redeemInvitation(invitation.qrPayload)

        XCTAssertEqual(replacement.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(server.accountMembershipLocks[account]?.state, .active)
        XCTAssertNotNil(server.accountMembershipLocks[account]?.claimBinding)
    }

    func testRevocationRetainsLockRetryUntilConditionalReleaseSucceeds() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "revoked-child")
        let child = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                       clock: { family.clock.now }, automaticSync: false)
        try await child.redeemInvitation(invitation.qrPayload)
        try await family.store.revokeInvitation(invitation.invitation)
        transport.accountLockReleaseFailures = 1

        do { try await child.synchronize(); XCTFail("Revoked access must fail") } catch {}
        XCTAssertNotNil(child.session.accountMembershipLockAttemptID)
        XCTAssertEqual(server.accountMembershipLocks["revoked-child"]?.state, .active)
        do { try await child.synchronize(); XCTFail("Revoked access must keep failing") } catch {}
        XCTAssertNil(child.session.accountMembershipLockAttemptID)
        XCTAssertEqual(server.accountMembershipLocks["revoked-child"]?.state, .released)
    }

    func testCloudKitLockConflictClassificationDoesNotMaskServiceErrors() {
        let recordID = CKRecord.ID(recordName: "current-membership")
        XCTAssertTrue(CloudKitHouseholdTransport.isAccountMembershipRecordConflict(
            CKError(.serverRecordChanged), recordID: recordID
        ))
        let conflict = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [recordID: CKError(.serverRecordChanged)]
        ])
        XCTAssertTrue(CloudKitHouseholdTransport.isAccountMembershipRecordConflict(conflict, recordID: recordID))
        for code in [CKError.Code.networkFailure, .notAuthenticated, .quotaExceeded, .serviceUnavailable,
                     .batchRequestFailed] {
            XCTAssertFalse(CloudKitHouseholdTransport.isAccountMembershipRecordConflict(
                CKError(code), recordID: recordID
            ))
        }
    }

    func testCloudKitClaimConflictClassificationPreservesTransportErrors() {
        let first = CKRecord.ID(recordName: "first")
        let second = CKRecord.ID(recordName: "second")
        let recordIDs: Set<CKRecord.ID> = [first, second]
        let conflict = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [
                first: CKError(.serverRecordChanged),
                second: CKError(.batchRequestFailed)
            ]
        ])
        XCTAssertTrue(CloudKitHouseholdTransport.isInvitationClaimConflict(conflict, recordIDs: recordIDs))
        for code in [CKError.Code.networkFailure, .notAuthenticated, .quotaExceeded, .serviceUnavailable] {
            let failure = CKError(.partialFailure, userInfo: [
                CKPartialErrorsByItemIDKey: [first: CKError(code), second: CKError(.batchRequestFailed)]
            ])
            XCTAssertFalse(CloudKitHouseholdTransport.isInvitationClaimConflict(failure, recordIDs: recordIDs))
        }
        XCTAssertFalse(CloudKitHouseholdTransport.isInvitationClaimConflict(
            CKError(.batchRequestFailed), recordIDs: recordIDs
        ))
    }

    func testExistingAccountMembershipBlocksAnotherFamilyAndProfile() async throws {
        let server = TestCloudServer()
        let firstFamily = try TestFamily(transport: TestTransport(server: server, account: "first-owner"))
        let hannaInvitation = try await firstFamily.store.createChildInvitation(memberID: firstFamily.hanna.id)
        let joined = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                        transport: TestTransport(server: server, account: "child-account"),
                                        clock: { firstFamily.clock.now }, automaticSync: false)
        try await joined.redeemInvitation(hannaInvitation.qrPayload)

        let siblingInvitation = try await firstFamily.store.createChildInvitation(memberID: firstFamily.alek.id)
        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: TestTransport(server: server, account: "child-account"),
                                             clock: { firstFamily.clock.now }, automaticSync: false)
        await XCTAssertThrowsErrorAsync(try await replacement.redeemInvitation(siblingInvitation.qrPayload),
                                        expected: .accountMembershipConflict)
        XCTAssertNil(replacement.household)

        let secondFamily = try TestFamily(transport: TestTransport(server: server, account: "second-owner"))
        let otherInvitation = try await secondFamily.store.createChildInvitation(memberID: secondFamily.hanna.id)
        await XCTAssertThrowsErrorAsync(try await replacement.redeemInvitation(otherInvitation.qrPayload),
                                        expected: .accountMembershipConflict)
        XCTAssertNil(replacement.household)
        XCTAssertFalse(server.zones[otherInvitation.shareURL.lastPathComponent]!.participants.contains("child-account"))
    }

    func testInvitationClaimSequenceOverflowFailsSafely() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let zoneName = invitation.shareURL.lastPathComponent
        let invitationFact = try XCTUnwrap(server.zones[zoneName]?.facts.values.first { fact in
            if case .invitation(let value) = fact.body { return value.id == invitation.invitation.id }
            return false
        })
        server.zones[zoneName]?.facts[invitationFact.id] = HouseholdFact(
            id: invitationFact.id,
            householdID: invitationFact.householdID,
            sequence: Int64.max,
            authorDeviceID: invitationFact.authorDeviceID,
            authorMemberID: invitationFact.authorMemberID,
            body: invitationFact.body
        )
        let transport = TestTransport(server: server, account: "overflow-child")
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)

        await XCTAssertThrowsErrorAsync(try await joining.redeemInvitation(invitation.qrPayload),
                                        expected: .malformedData)
        XCTAssertNil(joining.household)
        XCTAssertFalse(server.zones[zoneName]!.participants.contains("overflow-child"))
        XCTAssertNil(server.zones[zoneName]!.facts[invitation.invitation.claimFactID])
    }

    func testSystemAcceptedInvitationRollsBackWhenCodeRedemptionFails() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let repository = try HouseholdRepository(inMemory: true)
        let transport = TestTransport(server: server, account: "metadata-child")
        let joining = try HouseholdStore(repository: repository, transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)

        let location = try await transport.invitationLocation(for: invitation.shareURL)
        var observedProvisionalState = false
        transport.beforeAccept = {
            observedProvisionalState = (try? repository.session().pendingInvitationAcceptance?.phase) == .acceptingAccess
        }
        try await joining.acceptSystemInvitation(location: location) {
            try await transport.accept(url: invitation.shareURL, expected: location)
        }
        XCTAssertTrue(observedProvisionalState)
        XCTAssertEqual(joining.household?.id, family.store.household?.id)
        XCTAssertEqual(joining.session.pendingInvitationAcceptance?.phase, .awaitingRedemption)
        XCTAssertEqual(joining.session.pendingInvitationAcceptance?.invitationID, invitation.invitation.id)
        XCTAssertEqual(joining.session.pendingInvitationAcceptance?.expiresAt, invitation.invitation.expiresAt)

        await XCTAssertThrowsErrorAsync(
            try await joining.redeemInvitation("2345-6789-AB"),
            expected: .invitationNotFound
        )
        XCTAssertNil(joining.household)
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertTrue(try repository.facts(householdID: invitation.invitation.householdID).isEmpty)
        XCTAssertFalse(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains("metadata-child"))
    }

    func testPendingMetadataAcceptanceExpiresAndLeavesAccess() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "metadata-child")
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        try await joining.acceptSystemInvitation(location: location) {
            try await transport.accept(url: invitation.shareURL, expected: location)
        }

        family.move(to: "2026-09-08T17:00:01Z")
        try await joining.retryInvitationCleanup()
        XCTAssertNil(joining.household)
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertEqual(transport.leaveAttempts, 1)
        XCTAssertFalse(server.zones[location.zoneName]!.participants.contains("metadata-child"))
    }

    func testPendingMetadataAcceptanceUsesServerTimeWithJoinerClockAhead() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(60)
        let transport = TestTransport(server: server, account: "ahead-child")
        let joiningClock = TestClock("2027-09-07T16:00:00Z")
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { joiningClock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)

        try await joining.acceptSystemInvitation(location: location) {
            try await transport.accept(url: invitation.shareURL, expected: location)
        }

        XCTAssertEqual(joining.session.pendingInvitationAcceptance?.phase, .awaitingRedemption)
        XCTAssertEqual(joining.household?.id, family.store.household?.id)
        XCTAssertEqual(transport.leaveAttempts, 0)
    }

    func testPendingMetadataCleanupUsesServerTimeWithJoinerClockBehind() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(60)
        let transport = TestTransport(server: server, account: "behind-child")
        let joiningClock = TestClock("2025-09-07T16:00:00Z")
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { joiningClock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        try await joining.acceptSystemInvitation(location: location) {
            try await transport.accept(url: invitation.shareURL, expected: location)
        }
        server.authoritativeTime = invitation.invitation.expiresAt.addingTimeInterval(1)

        try await joining.retryInvitationCleanup()

        XCTAssertNil(joining.household)
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertEqual(transport.leaveAttempts, 1)
    }

    func testPendingCleanupDelayUsesServerTimeWhenDeviceClockIsAhead() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(60)
        let transport = TestTransport(server: server, account: "ahead-child")
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { invitation.invitation.expiresAt.addingTimeInterval(365 * 86_400) },
                                         automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        try await joining.acceptSystemInvitation(location: location) {
            try await transport.accept(url: invitation.shareURL, expected: location)
        }

        let delay = try await joining.pendingInvitationCleanupDelay()

        XCTAssertEqual(delay, InvitationCode.lifetime - 60)
        XCTAssertNotNil(joining.session.pendingInvitationAcceptance)
    }

    func testPendingCleanupDelayUsesServerTimeWhenDeviceClockIsBehind() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(60)
        let transport = TestTransport(server: server, account: "behind-child")
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { invitation.invitation.createdAt.addingTimeInterval(-365 * 86_400) },
                                         automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        try await joining.acceptSystemInvitation(location: location) {
            try await transport.accept(url: invitation.shareURL, expected: location)
        }

        let delay = try await joining.pendingInvitationCleanupDelay()

        XCTAssertEqual(delay, InvitationCode.lifetime - 60)
        XCTAssertNotNil(joining.session.pendingInvitationAcceptance)
    }

    func testPendingCleanupEarlyWakeRecomputesAuthoritativeDelay() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(60)
        let transport = TestTransport(server: server, account: "early-child")
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        try await joining.acceptSystemInvitation(location: location) {
            try await transport.accept(url: invitation.shareURL, expected: location)
        }
        let firstDelay = try await joining.pendingInvitationCleanupDelay()
        server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(120)

        let retryDelay = try await joining.retryScheduledInvitationCleanup()
        let rescheduledDelay = try await joining.pendingInvitationCleanupDelay()

        XCTAssertNil(retryDelay)
        XCTAssertEqual(firstDelay, InvitationCode.lifetime - 60)
        XCTAssertEqual(rescheduledDelay, InvitationCode.lifetime - 120)
        XCTAssertNotNil(joining.session.pendingInvitationAcceptance)
    }

    func testPendingCleanupTransientValidationFailureUsesBoundedBackoff() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(60)
        let transport = TestTransport(server: server, account: "retry-child")
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        try await joining.acceptSystemInvitation(location: location) {
            try await transport.accept(url: invitation.shareURL, expected: location)
        }
        transport.invitationValidationTimeFailures = 1

        let retryDelay = try await joining.pendingInvitationCleanupDelay()
        transport.invitationValidationTimeFailures = 1
        let wakeRetryDelay = try await joining.retryScheduledInvitationCleanup()
        let recoveredDelay = try await joining.pendingInvitationCleanupDelay()

        XCTAssertEqual(retryDelay, 30)
        XCTAssertEqual(wakeRetryDelay, 30)
        XCTAssertEqual(recoveredDelay, InvitationCode.lifetime - 60)
        XCTAssertNotNil(joining.session.pendingInvitationAcceptance)
    }

    func testScheduledPendingCleanupLeavesAccessAtAuthoritativeExpiry() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "expired-child")
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { invitation.invitation.createdAt.addingTimeInterval(-365 * 86_400) },
                                         automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        try await joining.acceptSystemInvitation(location: location) {
            try await transport.accept(url: invitation.shareURL, expected: location)
        }
        server.authoritativeTime = invitation.invitation.expiresAt

        let cleanupDelay = try await joining.pendingInvitationCleanupDelay()
        let retryDelay = try await joining.retryScheduledInvitationCleanup()

        XCTAssertEqual(cleanupDelay, 0)
        XCTAssertNil(retryDelay)
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertEqual(transport.leaveAttempts, 1)
        XCTAssertFalse(server.zones[location.zoneName]!.participants.contains("expired-child"))
    }

    func testMembershipLeaseUsesServerTimeAcrossDivergentDeviceClocks() async throws {
        let server = TestCloudServer()
        let joiningTransport = TestTransport(server: server, account: "skewed-child")
        let oldHousehold = UUID()
        let oldAttempt = UUID()
        let serverStart = ISO8601DateFormatter().date(from: "2026-09-07T16:00:00Z")!
        server.authoritativeTime = serverStart
        let lock = try await joiningTransport.acquireAccountMembershipLock(
            householdID: oldHousehold, attemptID: oldAttempt,
            leaseDuration: InvitationCode.lifetime,
            clientTime: serverStart.addingTimeInterval(365 * 86_400)
        )
        XCTAssertEqual(lock.expiresAt, serverStart.addingTimeInterval(InvitationCode.lifetime))

        server.authoritativeTime = lock.expiresAt.addingTimeInterval(-1)
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let joiningClock = TestClock("2026-09-07T16:00:00Z")
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                         transport: joiningTransport,
                                         clock: { joiningClock.now }, automaticSync: false)

        await XCTAssertThrowsErrorAsync(try await joining.redeemInvitation(invitation.qrPayload),
                                        expected: .accountMembershipConflict)
        XCTAssertEqual(server.accountMembershipLocks["skewed-child"]?.attemptID, oldAttempt)
        server.authoritativeTime = lock.expiresAt.addingTimeInterval(1)

        try await joining.redeemInvitation(invitation.qrPayload)

        XCTAssertEqual(joining.selectedMember?.id, family.hanna.id)
        XCTAssertNotEqual(server.accountMembershipLocks["skewed-child"]?.attemptID, oldAttempt)
    }

    func testRevokedPendingMetadataAcceptanceLeavesAccess() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "metadata-child")
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        try await joining.acceptSystemInvitation(location: location) {
            try await transport.accept(url: invitation.shareURL, expected: location)
        }

        try await family.store.revokeInvitation(invitation.invitation)
        try await joining.retryInvitationCleanup()
        XCTAssertNil(joining.household)
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertFalse(server.zones[location.zoneName]!.participants.contains("metadata-child"))
    }

    func testPendingSystemAcceptanceRejectsPackagedShareFromAnotherFamily() async throws {
        let server = TestCloudServer()
        let first = try TestFamily(transport: TestTransport(server: server, account: "first-owner"))
        let firstInvitation = try await first.store.createChildInvitation(memberID: first.hanna.id)
        let second = try TestFamily(transport: TestTransport(server: server, account: "second-owner"))
        let secondInvitation = try await second.store.createChildInvitation(memberID: second.hanna.id)
        let transport = TestTransport(server: server, account: "joining-child")
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { first.clock.now }, automaticSync: false)
        let firstLocation = try await transport.invitationLocation(for: firstInvitation.shareURL)
        try await joining.acceptSystemInvitation(location: firstLocation) {
            try await transport.accept(url: firstInvitation.shareURL, expected: firstLocation)
        }
        var components = URLComponents()
        components.scheme = "earnedit-invitation"
        components.host = "join"
        components.queryItems = [
            URLQueryItem(name: "code", value: firstInvitation.code),
            URLQueryItem(name: "share", value: secondInvitation.shareURL.absoluteString)
        ]

        await XCTAssertThrowsErrorAsync(try await joining.redeemInvitation(try XCTUnwrap(components.url).absoluteString),
                                        expected: .invitationNotFound)
        XCTAssertNil(joining.household)
        XCTAssertFalse(server.zones[firstInvitation.shareURL.lastPathComponent]!.participants.contains("joining-child"))
        XCTAssertFalse(server.zones[secondInvitation.shareURL.lastPathComponent]!.participants.contains("joining-child"))
    }

    func testPersistedInvitationContainsDigestButNeverClearTextCode() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let issued = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let facts = try family.repository.facts(householdID: family.store.household!.id)
        let payload = try JSONEncoder().encode(facts)
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains(issued.code))
        XCTAssertTrue(family.store.snapshot.invitations.contains { $0.codeDigest == InvitationCode.digest(issued.code) })
    }

    func testFailedInvitationUploadRevokesAccessAndArchivesUnsharedParent() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: transport)
        try await family.store.connect()
        transport.server.failUploadAfter = 0

        do {
            _ = try await family.store.createParentInvitation(name: "Unshared Parent", avatar: .fox)
            XCTFail("The invitation upload should fail")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }

        let invitation = try XCTUnwrap(family.store.familyInvitations.first)
        XCTAssertEqual(family.store.invitationStatus(invitation), .revoked)
        XCTAssertFalse(family.store.profiles.contains { $0.id == invitation.memberID })
        XCTAssertTrue(server.zones[family.store.session.location!.zoneName]!.pendingInvitationParticipants.isEmpty)

        transport.server.failUploadAfter = nil
        try await family.store.synchronize()
        let remote = HouseholdSnapshot(facts: try await transport.fetch(from: family.store.session.location!))
        XCTAssertTrue(remote.isInvitationRevoked(invitation.id))
        XCTAssertNotNil(remote.member(invitation.memberID)?.archivedFrom)
    }

    func testRevokingParentInstallationLeavesHouseholdAndOtherMembersIntact() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createParentInvitation(name: "Parent B", avatar: .fox)
        let repository = try HouseholdRepository(inMemory: true)
        let transport = TestTransport(server: server, account: "parent-b")
        let parentB = try HouseholdStore(repository: repository, transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        try await parentB.redeemInvitation(invitation.qrPayload)
        let householdID = try XCTUnwrap(parentB.household?.id)
        let memberIDs = Set(family.store.snapshot.members.map(\.id))

        try await family.store.revokeInvitation(invitation.invitation)
        do { try await parentB.synchronize(); XCTFail("Revoked Apple access must fail") }
        catch { XCTAssertEqual((error as? CKError)?.code, .permissionFailure) }
        XCTAssertThrowsError(try parentB.saveMember(name: "Blocked", role: .child, avatar: .star))
        let reopened = try HouseholdStore(repository: repository, transport: transport,
                                          clock: { family.clock.now }, automaticSync: false)
        XCTAssertTrue(reopened.cloudIsReadOnly)
        XCTAssertThrowsError(try reopened.saveChore(weekday: .monday, title: "Blocked", mode: .all, memberIDs: []))
        XCTAssertEqual(family.store.household?.id, householdID)
        XCTAssertEqual(Set(family.store.snapshot.members.map(\.id)), memberIDs)
        XCTAssertEqual(family.store.selectedMember?.id, family.parent.id)
    }

    func testOlderOwnerInstallationKeepsOnlyItsPreviouslySelectedProfile() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        try await family.store.connect()
        let repository = try HouseholdRepository(inMemory: true)
        let transport = TestTransport(server: server, account: "owner")
        let oldInstallation = try HouseholdStore(repository: repository, transport: transport,
                                                 clock: { family.clock.now }, automaticSync: false)
        try await oldInstallation.joinExisting(family.store.session.location!)
        var oldSession = oldInstallation.session
        oldSession.selectedMemberID = family.hanna.id
        oldSession.legacyProfileIDs = nil
        try repository.commit(facts: [], session: oldSession)

        let migrated = try HouseholdStore(repository: repository, transport: transport,
                                          clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(migrated.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(migrated.profiles.map(\.id), [family.hanna.id])
        XCTAssertThrowsError(try migrated.selectProfile(family.parent.id))
        XCTAssertEqual(try repository.session().legacyProfileIDs, [family.hanna.id])
    }
}

private extension XCTestCase {
    @MainActor
    func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> Any,
                                   expected: HouseholdError, file: StaticString = #filePath,
                                   line: UInt = #line) async {
        do {
            _ = try await expression()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? HouseholdError, expected, file: file, line: line)
        }
    }
}

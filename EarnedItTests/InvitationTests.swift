import CloudKit
import XCTest
@testable import EarnedIt

@MainActor
final class InvitationTests: XCTestCase {
    private func connectedOwnerFixture(account: String = "owner") async throws -> (
        server: TestCloudServer,
        transport: TestTransport,
        repository: HouseholdRepository,
        store: HouseholdStore,
        householdID: UUID,
        location: CloudLocation,
        parent: FamilyMember,
        child: FamilyMember,
        lock: AccountMembershipLock
    ) {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: account)
        let repository = try HouseholdRepository(inMemory: true)
        let store = try HouseholdStore(
            repository: repository,
            transport: transport,
            clock: { TestClock().now },
            automaticSync: false
        )
        try store.createFamily(name: "Test Family", parentName: "Test Parent")
        let parent = try XCTUnwrap(store.selectedMember)
        let child = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
        try store.finishSetup()
        try await store.connect()
        return (
            server,
            transport,
            repository,
            store,
            try XCTUnwrap(store.household?.id),
            try XCTUnwrap(store.session.location),
            parent,
            child,
            try XCTUnwrap(server.accountMembershipLocks[account])
        )
    }

    func testSlowInvitationUploadDoesNotLaunchCompetingScheduledSync() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let store = try HouseholdStore(
            repository: HouseholdRepository(inMemory: true),
            transport: transport,
            automaticSync: true
        )
        try store.createFamily(name: "Test Family", parentName: "Test Parent")
        let child = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
        try store.finishSetup()
        try await store.connect()
        try await Task.sleep(for: .milliseconds(500))
        store.errorMessage = nil
        transport.invitationFactUploadDelay = .milliseconds(500)

        _ = try await store.createChildInvitation(memberID: child.id)

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.syncMessage, "Up to date")
        XCTAssertEqual(store.pendingCount, 0)
    }

    func testExistingInvitationRecoveryReturnsDigestMatchedRawAppleURL() async throws {
        let fixture = try await connectedOwnerFixture()
        let issued = try await fixture.store.createChildInvitation(memberID: fixture.child.id)

        let recovered = try await fixture.store.recoverInvitation(issued.invitation)

        XCTAssertEqual(recovered.invitation, issued.invitation)
        XCTAssertEqual(recovered.shareURL, issued.shareURL)
        XCTAssertEqual(recovered.qrPayload, issued.shareURL.absoluteString)
        XCTAssertNotEqual(recovered.qrPayload, issued.invitationURL.absoluteString)
    }

    func testExistingInvitationRecoveryRejectsMismatchedURLParticipantAndMissingAccess() async throws {
        let fixture = try await connectedOwnerFixture()
        let issued = try await fixture.store.createChildInvitation(memberID: fixture.child.id)

        fixture.transport.recoveredInvitationURL = URL(string: "https://test.invalid/different")!
        await XCTAssertThrowsErrorAsync(
            try await fixture.store.recoverInvitation(issued.invitation),
            expected: .invitationUnavailable
        )

        fixture.transport.recoveredInvitationURL = nil
        fixture.transport.recoveredInvitationParticipantID = "different-participant"
        await XCTAssertThrowsErrorAsync(
            try await fixture.store.recoverInvitation(issued.invitation),
            expected: .invitationUnavailable
        )

        fixture.transport.recoveredInvitationParticipantID = nil
        for rejection in ["status", "permission", "role"] {
            fixture.transport.recoveredInvitationStatusPending = rejection != "status"
            fixture.transport.recoveredInvitationCanWrite = rejection != "permission"
            fixture.transport.recoveredInvitationRoleIsPrivate = rejection != "role"
            await XCTAssertThrowsErrorAsync(
                try await fixture.store.recoverInvitation(issued.invitation),
                expected: .invitationUnavailable
            )
        }
        fixture.transport.recoveredInvitationStatusPending = true
        fixture.transport.recoveredInvitationCanWrite = true
        fixture.transport.recoveredInvitationRoleIsPrivate = true
        fixture.server.zones[fixture.location.zoneName]?.pendingInvitationParticipants.remove(
            issued.invitation.cloudShareParticipantID
        )
        await XCTAssertThrowsErrorAsync(
            try await fixture.store.recoverInvitation(issued.invitation),
            expected: .invitationUnavailable
        )
    }

    func testCleanFirstChildInvitationCreatesAndRetainsOwnerMembership() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let store = try HouseholdStore(
            repository: HouseholdRepository(inMemory: true),
            transport: transport,
            clock: { TestClock().now },
            automaticSync: false
        )

        XCTAssertNil(server.accountMembershipLocks["owner"])
        try store.createFamily(name: "Test Family", parentName: "Test Parent")
        let child = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
        try store.finishSetup()

        let invitation = try await store.createChildInvitation(memberID: child.id)
        let householdID = try XCTUnwrap(store.household?.id)
        let ownerLock = try XCTUnwrap(server.accountMembershipLocks["owner"])

        XCTAssertEqual(ownerLock.householdID, householdID)
        XCTAssertEqual(ownerLock.state, .active)
        XCTAssertEqual(ownerLock.claimBinding, AccountMembershipBinding.owner(householdID: householdID))
        XCTAssertEqual(
            ownerLock.ownerAuthorityBinding,
            AccountMembershipBinding.ownerAuthority(participantID: "owner")
        )
        XCTAssertEqual(store.session.accountMembershipLockAttemptID, ownerLock.attemptID)
        XCTAssertEqual(invitation.invitation.memberID, child.id)
        XCTAssertEqual(invitation.invitation.role, .child)
    }

    func testActiveOwnerMembershipCanIssueFirstExactChildInvitation() async throws {
        let fixture = try await connectedOwnerFixture()
        let server = fixture.server
        let transport = fixture.transport
        let store = fixture.store
        let ownerLock = fixture.lock
        let retainedOwnerLock = AccountMembershipLock(
            householdID: ownerLock.householdID,
            attemptID: UUID(),
            state: ownerLock.state,
            expiresAt: ownerLock.expiresAt,
            claimBinding: ownerLock.claimBinding,
            ownerAuthorityBinding: ownerLock.ownerAuthorityBinding
        )
        server.accountMembershipLocks["owner"] = retainedOwnerLock
        let acquireCount = transport.accountLockAcquireMutationEnqueues
        let activationCount = transport.accountLockActivationMutationEnqueues
        var observedStates: [AccountMembershipLockState] = []
        transport.beforeAccountLockActivationSubmission = {
            if let current = server.accountMembershipLocks["owner"] {
                observedStates.append(current.state)
            }
        }

        let invitation = try await store.createChildInvitation(memberID: fixture.child.id)

        XCTAssertEqual(invitation.invitation.householdID, fixture.householdID)
        XCTAssertEqual(invitation.invitation.memberID, fixture.child.id)
        XCTAssertEqual(invitation.invitation.role, .child)
        XCTAssertEqual(server.accountMembershipLocks["owner"], retainedOwnerLock)
        XCTAssertEqual(store.session.accountMembershipLockAttemptID, retainedOwnerLock.attemptID)
        XCTAssertEqual(transport.accountLockAcquireMutationEnqueues, acquireCount)
        XCTAssertEqual(transport.accountLockActivationMutationEnqueues, activationCount + 2)
        XCTAssertEqual(observedStates, [.active, .active])

        let childStore = try HouseholdStore(
            repository: HouseholdRepository(inMemory: true),
            transport: TestTransport(server: server, account: "child"),
            clock: { TestClock().now },
            automaticSync: false
        )
        try await childStore.redeemInvitation(invitation.qrPayload)
        XCTAssertEqual(childStore.selectedMember?.id, fixture.child.id)
        XCTAssertEqual(childStore.profiles.map(\.id), [fixture.child.id])
        XCTAssertThrowsError(try childStore.selectProfile(fixture.parent.id)) {
            XCTAssertEqual($0 as? HouseholdError, .permission)
        }
        XCTAssertEqual(server.accountMembershipLocks["owner"], retainedOwnerLock)
    }

    func testLegacyOwnerWithoutAttemptAdoptsExactActiveMembership() async throws {
        let fixture = try await connectedOwnerFixture()
        var legacySession = fixture.store.session
        legacySession.accountMembershipLockAttemptID = nil
        try fixture.repository.commit(facts: [], session: legacySession)
        let reopened = try HouseholdStore(
            repository: fixture.repository,
            transport: fixture.transport,
            clock: { TestClock().now },
            automaticSync: false
        )

        let invitation = try await reopened.createChildInvitation(memberID: fixture.child.id)

        XCTAssertEqual(invitation.invitation.memberID, fixture.child.id)
        XCTAssertEqual(reopened.session.accountMembershipLockAttemptID, fixture.lock.attemptID)
        XCTAssertEqual(fixture.server.accountMembershipLocks["owner"], fixture.lock)
    }

    func testActiveMembershipForDifferentHouseholdStillBlocksOwnerInvitation() async throws {
        let fixture = try await connectedOwnerFixture()
        let differentHouseholdID = UUID()
        let conflictingLock = AccountMembershipLock(
            householdID: differentHouseholdID,
            attemptID: UUID(),
            state: .active,
            expiresAt: .distantFuture,
            claimBinding: AccountMembershipBinding.owner(householdID: differentHouseholdID),
            ownerAuthorityBinding: AccountMembershipBinding.ownerAuthority(participantID: "owner")
        )
        fixture.server.accountMembershipLocks["owner"] = conflictingLock

        await XCTAssertThrowsErrorAsync(
            try await fixture.store.createChildInvitation(memberID: fixture.child.id),
            expected: .accountMembershipConflict
        )

        XCTAssertEqual(fixture.server.accountMembershipLocks["owner"], conflictingLock)
        XCTAssertEqual(fixture.transport.invitationAccessCreationCalls, 0)
        XCTAssertFalse(try XCTUnwrap(fixture.server.zones[fixture.location.zoneName]).shareExists)
        XCTAssertTrue(fixture.store.familyInvitations.isEmpty)
    }

    func testSameHouseholdOwnerMembershipRejectsChangedAccountGeneration() async throws {
        let fixture = try await connectedOwnerFixture()
        let retainedOwnerLock = AccountMembershipLock(
            householdID: fixture.lock.householdID,
            attemptID: UUID(),
            state: fixture.lock.state,
            expiresAt: fixture.lock.expiresAt,
            claimBinding: fixture.lock.claimBinding,
            ownerAuthorityBinding: fixture.lock.ownerAuthorityBinding
        )
        fixture.server.accountMembershipLocks["owner"] = retainedOwnerLock
        fixture.transport.afterAccountMembershipLockRead = {
            fixture.transport.afterAccountMembershipLockRead = nil
            fixture.store.cloudAccountDidChange()
        }

        await XCTAssertThrowsErrorAsync(
            try await fixture.store.createChildInvitation(memberID: fixture.child.id),
            expected: .wrongAccount
        )

        XCTAssertEqual(fixture.transport.accountGeneration, 1)
        XCTAssertEqual(fixture.server.accountMembershipLocks["owner"], retainedOwnerLock)
        XCTAssertEqual(fixture.transport.invitationAccessCreationCalls, 0)
        XCTAssertFalse(try XCTUnwrap(fixture.server.zones[fixture.location.zoneName]).shareExists)
    }

    func testSameHouseholdOwnerMembershipRejectsAccountGenerationChangedDuringFetch() async throws {
        let fixture = try await connectedOwnerFixture()
        let retainedOwnerLock = AccountMembershipLock(
            householdID: fixture.lock.householdID,
            attemptID: UUID(),
            state: fixture.lock.state,
            expiresAt: fixture.lock.expiresAt,
            claimBinding: fixture.lock.claimBinding,
            ownerAuthorityBinding: fixture.lock.ownerAuthorityBinding
        )
        fixture.server.accountMembershipLocks["owner"] = retainedOwnerLock
        fixture.transport.beforeFetch = {
            fixture.transport.beforeFetch = nil
            fixture.store.cloudAccountDidChange()
        }

        await XCTAssertThrowsErrorAsync(
            try await fixture.store.createChildInvitation(memberID: fixture.child.id),
            expected: .wrongAccount
        )

        XCTAssertEqual(fixture.transport.accountGeneration, 1)
        XCTAssertEqual(fixture.server.accountMembershipLocks["owner"], retainedOwnerLock)
        XCTAssertEqual(fixture.transport.invitationAccessCreationCalls, 0)
        XCTAssertFalse(try XCTUnwrap(fixture.server.zones[fixture.location.zoneName]).shareExists)
    }

    func testSameHouseholdOwnerReuseRequiresExactClaimAndOwnerAuthority() async throws {
        for mismatchedField in ["claim", "owner-authority"] {
            let account = "owner-\(mismatchedField)"
            let fixture = try await connectedOwnerFixture(account: account)
            let blockedLock = AccountMembershipLock(
                householdID: fixture.householdID,
                attemptID: fixture.lock.attemptID,
                state: .active,
                expiresAt: .distantFuture,
                claimBinding: mismatchedField == "claim" ? "wrong-claim" : fixture.lock.claimBinding,
                ownerAuthorityBinding: mismatchedField == "owner-authority"
                    ? AccountMembershipBinding.ownerAuthority(participantID: "different-account")
                    : fixture.lock.ownerAuthorityBinding
            )
            fixture.server.accountMembershipLocks[account] = blockedLock

            await XCTAssertThrowsErrorAsync(
                try await fixture.store.createChildInvitation(memberID: fixture.child.id),
                expected: .accountMembershipConflict
            )

            XCTAssertEqual(fixture.server.accountMembershipLocks[account], blockedLock)
            XCTAssertEqual(fixture.transport.invitationAccessCreationCalls, 0)
            XCTAssertFalse(try XCTUnwrap(fixture.server.zones[fixture.location.zoneName]).shareExists)
        }
    }

    func testReleasedOrStaleOwnerMembershipCannotRegainInvitationAuthority() async throws {
        for state in [AccountMembershipLockState.released, .provisional] {
            let fixture = try await connectedOwnerFixture(account: "owner-\(state.rawValue)")
            let blockedLock = AccountMembershipLock(
                householdID: fixture.householdID,
                attemptID: state == .released ? fixture.lock.attemptID : UUID(),
                state: state,
                expiresAt: TestClock().now.addingTimeInterval(-1),
                claimBinding: state == .released ? fixture.lock.claimBinding : nil,
                ownerAuthorityBinding: state == .released ? fixture.lock.ownerAuthorityBinding : nil
            )
            fixture.server.accountMembershipLocks[fixture.transport.account] = blockedLock

            await XCTAssertThrowsErrorAsync(
                try await fixture.store.createChildInvitation(memberID: fixture.child.id),
                expected: .accountMembershipConflict
            )

            XCTAssertEqual(fixture.server.accountMembershipLocks[fixture.transport.account], blockedLock)
            XCTAssertEqual(fixture.transport.invitationAccessCreationCalls, 0)
            XCTAssertFalse(try XCTUnwrap(fixture.server.zones[fixture.location.zoneName]).shareExists)
        }
    }

    func testLegacyOwnerWithoutAttemptRejectsReleasedOrStaleMembership() async throws {
        for state in [AccountMembershipLockState.released, .provisional] {
            let fixture = try await connectedOwnerFixture(account: "legacy-owner-\(state.rawValue)")
            var legacySession = fixture.store.session
            legacySession.accountMembershipLockAttemptID = nil
            try fixture.repository.commit(facts: [], session: legacySession)
            let reopened = try HouseholdStore(
                repository: fixture.repository,
                transport: fixture.transport,
                clock: { TestClock().now },
                automaticSync: false
            )
            let blockedLock = AccountMembershipLock(
                householdID: fixture.householdID,
                attemptID: state == .released ? fixture.lock.attemptID : UUID(),
                state: state,
                expiresAt: TestClock().now.addingTimeInterval(-1),
                claimBinding: state == .released ? fixture.lock.claimBinding : nil,
                ownerAuthorityBinding: state == .released ? fixture.lock.ownerAuthorityBinding : nil
            )
            fixture.server.accountMembershipLocks[fixture.transport.account] = blockedLock

            await XCTAssertThrowsErrorAsync(
                try await reopened.createChildInvitation(memberID: fixture.child.id),
                expected: .accountMembershipConflict
            )

            XCTAssertEqual(fixture.server.accountMembershipLocks[fixture.transport.account], blockedLock)
            XCTAssertEqual(fixture.transport.invitationAccessCreationCalls, 0)
            XCTAssertFalse(try XCTUnwrap(fixture.server.zones[fixture.location.zoneName]).shareExists)
        }
    }

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
        await XCTAssertThrowsErrorAsync(try await joining.retryScheduledInvitationCleanup() as Any, expected: .wrongAccount)
        XCTAssertEqual(transport.leaveAttempts, 1)
        XCTAssertNotNil(joining.session.pendingInvitationAcceptance)

        transport.account = "joining-child"
        transport.beforeLeave = { await Task.yield() }
        async let firstRetry: (TimeInterval?, HouseholdError?) = {
            do { return (try await joining.retryScheduledInvitationCleanup(), nil) }
            catch { return (nil, error as? HouseholdError) }
        }()
        async let repeatedRetry: (TimeInterval?, HouseholdError?) = {
            do { return (try await joining.retryScheduledInvitationCleanup(), nil) }
            catch { return (nil, error as? HouseholdError) }
        }()
        let retryResults = await (firstRetry, repeatedRetry)

        XCTAssertEqual([retryResults.0.1, retryResults.1.1].compactMap { $0 }, [.pendingChanges])
        XCTAssertEqual([retryResults.0.0, retryResults.1.0].compactMap { $0 }.count, 0)
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
            do {
                try await Task.detached { @MainActor in
                    try await first.redeemInvitation(invitation.qrPayload)
                }.value
            }
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
        XCTAssertEqual(secondTransport.leaveAttempts, 0)
        XCTAssertNotNil(second.session.pendingInvitationAcceptance)
        try await second.retryInvitationCleanup()
        XCTAssertNil(second.session.pendingInvitationAcceptance)
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
        let oldAttemptID = first.session.accountMembershipLockAttemptID
        try await family.store.revokeInvitation(firstInvitation.invitation)

        let secondInvitation = try await family.store.createChildInvitation(memberID: family.alek.id)
        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: TestTransport(server: server, account: account),
                                             clock: { family.clock.now }, automaticSync: false)
        try await replacement.redeemInvitation(secondInvitation.qrPayload)

        XCTAssertEqual(replacement.selectedMember?.id, family.alek.id)
        XCTAssertNotEqual(replacement.session.accountMembershipClaimBinding, oldBinding)
        XCTAssertNotEqual(replacement.session.accountMembershipLockAttemptID, oldAttemptID)
        do { try await first.synchronize(); XCTFail("The revoked generation must stay closed") }
        catch { XCTAssertEqual(error as? HouseholdError, .accountMembershipConflict) }
        XCTAssertEqual(first.selectedMember?.id, family.hanna.id)
        XCTAssertTrue(first.cloudIsReadOnly)
        XCTAssertThrowsError(try first.selectProfile(family.alek.id))
    }

    func testRevokedGenerationReplacementFailureKeepsOldLockUntilAtomicRetry() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let firstInvitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let account = "returning-child"
        let first = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                       transport: TestTransport(server: server, account: account),
                                       clock: { family.clock.now }, automaticSync: false)
        try await first.redeemInvitation(firstInvitation.qrPayload)
        let oldLock = try XCTUnwrap(server.accountMembershipLocks[account])
        try await family.store.revokeInvitation(firstInvitation.invitation)

        let secondInvitation = try await family.store.createChildInvitation(memberID: family.alek.id)
        let transport = TestTransport(server: server, account: account)
        transport.accountLockReplacementFailures = 1
        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: transport,
                                             clock: { family.clock.now }, automaticSync: false)

        do {
            try await replacement.redeemInvitation(secondInvitation.qrPayload)
            XCTFail("The injected replacement failure must stop redemption")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }
        XCTAssertEqual(server.accountMembershipLocks[account], oldLock)
        XCTAssertEqual(server.accountMembershipLocks[account]?.state, .active)
        XCTAssertEqual(transport.accountLockReplacementMutationEnqueues, 0)
        XCTAssertEqual(transport.accountLockMutationEnqueues, 0)

        try await replacement.continuePendingInvitation()
        XCTAssertEqual(replacement.selectedMember?.id, family.alek.id)
        XCTAssertNotEqual(server.accountMembershipLocks[account]?.attemptID, oldLock.attemptID)
        XCTAssertEqual(server.accountMembershipLocks[account]?.state, .active)
        do { try await first.synchronize(); XCTFail("The revoked generation must stay closed") }
        catch { XCTAssertEqual(error as? HouseholdError, .accountMembershipConflict) }
    }

    func testUnrevokedJournalGenerationCannotUseAtomicReplacement() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let firstInvitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let account = "returning-child"
        let first = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                       transport: TestTransport(server: server, account: account),
                                       clock: { family.clock.now }, automaticSync: false)
        try await first.redeemInvitation(firstInvitation.qrPayload)
        let oldLock = try XCTUnwrap(server.accountMembershipLocks[account])
        let secondInvitation = try await family.store.createChildInvitation(memberID: family.alek.id)
        let transport = TestTransport(server: server, account: account)
        let replacement = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: transport,
                                             clock: { family.clock.now }, automaticSync: false)

        await XCTAssertThrowsErrorAsync(
            try await replacement.redeemInvitation(secondInvitation.qrPayload),
            expected: .accountMembershipConflict
        )
        XCTAssertEqual(server.accountMembershipLocks[account], oldLock)
        XCTAssertEqual(transport.accountLockReplacementMutationEnqueues, 0)
        XCTAssertNil(replacement.selectedMember)
        let location = try XCTUnwrap(family.store.session.location)
        let remote = try await transport.fetch(from: location)
        XCTAssertNil(HouseholdSnapshot(facts: remote).invitationClaim(secondInvitation.invitation.id))
    }

    func testCrashAfterAtomicRevokedGenerationReplacementResumesProvisionalAttempt() async throws {
        let directory = URL.temporaryDirectory.appending(path: "revoked-replacement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repositoryURL = directory.appending(path: "replacement.store")
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let firstInvitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let account = "returning-child"
        let stale = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                       transport: TestTransport(server: server, account: account),
                                       clock: { family.clock.now }, automaticSync: false)
        try await stale.redeemInvitation(firstInvitation.qrPayload)
        let oldLock = try XCTUnwrap(server.accountMembershipLocks[account])
        try await family.store.revokeInvitation(firstInvitation.invitation)
        let secondInvitation = try await family.store.createChildInvitation(memberID: family.alek.id)

        var replacementAttemptID: UUID?
        do {
            let transport = TestTransport(server: server, account: account)
            transport.accountLockReplacementPostCommitFailures = 1
            let interrupted = try HouseholdStore(
                repository: HouseholdRepository(url: repositoryURL),
                transport: transport,
                clock: { family.clock.now },
                automaticSync: false
            )
            do {
                try await interrupted.redeemInvitation(secondInvitation.qrPayload)
                XCTFail("The simulated post-commit crash must interrupt redemption")
            } catch {
                XCTAssertEqual((error as? CKError)?.code, .networkFailure)
            }
            replacementAttemptID = interrupted.session.pendingInvitationAcceptance?.accountLockAttemptID
            XCTAssertEqual(server.accountMembershipLocks[account]?.attemptID, replacementAttemptID)
            XCTAssertEqual(server.accountMembershipLocks[account]?.state, .provisional)
            XCTAssertNil(server.accountMembershipLocks[account]?.claimBinding)
            XCTAssertNotEqual(replacementAttemptID, oldLock.attemptID)
            XCTAssertEqual(transport.accountLockMutationEnqueues, 0)
            do { try await stale.synchronize(); XCTFail("The old attempt must not reactivate the provisional lock") }
            catch { XCTAssertEqual(error as? HouseholdError, .accountMembershipConflict) }
            XCTAssertEqual(server.accountMembershipLocks[account]?.attemptID, replacementAttemptID)
            XCTAssertEqual(server.accountMembershipLocks[account]?.state, .provisional)
        }

        let reopenedTransport = TestTransport(server: server, account: account)
        let reopened = try HouseholdStore(
            repository: HouseholdRepository(url: repositoryURL),
            transport: reopenedTransport,
            clock: { family.clock.now },
            automaticSync: false
        )
        try await reopened.continuePendingInvitation()
        XCTAssertEqual(reopened.selectedMember?.id, family.alek.id)
        XCTAssertEqual(reopened.session.accountMembershipLockAttemptID, replacementAttemptID)
        XCTAssertEqual(server.accountMembershipLocks[account]?.attemptID, replacementAttemptID)
        XCTAssertEqual(server.accountMembershipLocks[account]?.state, .active)
        XCTAssertEqual(reopenedTransport.accountLockReplacementMutationEnqueues, 0)
        do { try await stale.synchronize(); XCTFail("The old generation must never reactivate") }
        catch { XCTAssertEqual(error as? HouseholdError, .accountMembershipConflict) }
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
            do {
                try await Task.detached { @MainActor in
                    try await secondJoin.redeemInvitation(secondInvitation.qrPayload)
                }.value
            }
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
            claimBinding: "binding-\(invitation)-\(member)",
            ownerAuthorityBinding: "owner-authority",
            now: now
        )
        let continuation = try await transport.acquireAccountMembershipLock(
            householdID: household, attemptID: UUID(), leaseDuration: 60, clientTime: now
        )
        XCTAssertEqual(continuation, active)
        await XCTAssertThrowsErrorAsync(
            try await transport.activateAccountMembershipLock(
                householdID: household, attemptID: continuation.attemptID,
                claimBinding: "different-binding",
                ownerAuthorityBinding: "owner-authority",
                now: now
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
        XCTAssertEqual(server.accountMembershipLocks["shared-account"]?.claimBinding, active.claimBinding)
        XCTAssertEqual(server.accountMembershipLocks["shared-account"]?.ownerAuthorityBinding,
                       active.ownerAuthorityBinding)

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

    func testAccountChangeBeforeAcquireOrActivationSubmissionCannotMutateEitherAccount() async throws {
        let server = TestCloudServer()
        let acquireTransport = TestTransport(server: server, account: "first-account")
        acquireTransport.beforeAccountLockAcquireSubmission = { acquireTransport.account = "second-account" }

        await XCTAssertThrowsErrorAsync(
            try await acquireTransport.acquireAccountMembershipLock(
                householdID: UUID(), attemptID: UUID(), leaseDuration: 60, clientTime: Date()
            ),
            expected: .wrongAccount
        )
        XCTAssertTrue(server.accountMembershipLocks.isEmpty)
        XCTAssertEqual(acquireTransport.accountLockAcquireMutationEnqueues, 0)

        let activationTransport = TestTransport(server: server, account: "first-account")
        let householdID = UUID()
        let attemptID = UUID()
        let provisional = try await activationTransport.acquireAccountMembershipLock(
            householdID: householdID,
            attemptID: attemptID,
            leaseDuration: 60,
            clientTime: Date()
        )
        activationTransport.beforeAccountLockActivationSubmission = {
            activationTransport.account = "second-account"
        }

        await XCTAssertThrowsErrorAsync(
            try await activationTransport.activateAccountMembershipLock(
                householdID: householdID,
                attemptID: attemptID,
                claimBinding: "claim",
                ownerAuthorityBinding: "authority",
                now: Date()
            ),
            expected: .wrongAccount
        )
        XCTAssertEqual(server.accountMembershipLocks["first-account"], provisional)
        XCTAssertNil(server.accountMembershipLocks["second-account"])
        XCTAssertEqual(activationTransport.accountLockActivationMutationEnqueues, 0)
    }

    func testRevokedGenerationReplacementRequiresEveryExactLockFieldAndStableAccount() async throws {
        let server = TestCloudServer()
        let account = "returning-child"
        let householdID = UUID()
        let oldAttemptID = UUID()
        let binding = "retained-revoked-claim-binding"
        let oldLock = AccountMembershipLock(
            householdID: householdID,
            attemptID: oldAttemptID,
            state: .active,
            expiresAt: .distantFuture,
            claimBinding: binding,
            ownerAuthorityBinding: "owner-authority"
        )
        server.accountMembershipLocks[account] = oldLock
        let transport = TestTransport(server: server, account: account)

        for mismatch in [
            (UUID(), oldAttemptID, binding),
            (householdID, UUID(), binding),
            (householdID, oldAttemptID, "different-binding")
        ] {
            await XCTAssertThrowsErrorAsync(
                try await transport.replaceActiveRevokedAccountMembershipLock(
                    householdID: mismatch.0,
                    revokedAttemptID: mismatch.1,
                    revokedClaimBinding: mismatch.2,
                    replacementAttemptID: UUID(),
                    expectedParticipantID: account,
                    leaseDuration: 60,
                    validatedAt: Date()
                ),
                expected: .accountMembershipConflict
            )
            XCTAssertEqual(server.accountMembershipLocks[account], oldLock)
        }

        transport.beforeAccountLockReplacementSubmission = { transport.account = "different-account" }
        await XCTAssertThrowsErrorAsync(
            try await transport.replaceActiveRevokedAccountMembershipLock(
                householdID: householdID,
                revokedAttemptID: oldAttemptID,
                revokedClaimBinding: binding,
                replacementAttemptID: UUID(),
                expectedParticipantID: account,
                leaseDuration: 60,
                validatedAt: Date()
            ),
            expected: .wrongAccount
        )
        XCTAssertEqual(server.accountMembershipLocks[account], oldLock)
        XCTAssertNil(server.accountMembershipLocks["different-account"])
        XCTAssertEqual(transport.accountLockReplacementMutationEnqueues, 0)

        let postCommitServer = TestCloudServer()
        postCommitServer.accountMembershipLocks[account] = oldLock
        let postCommitTransport = TestTransport(server: postCommitServer, account: account)
        let replacementAttemptID = UUID()
        postCommitTransport.afterAccountLockReplacementSubmission = {
            postCommitTransport.account = "different-account"
        }
        await XCTAssertThrowsErrorAsync(
            try await postCommitTransport.replaceActiveRevokedAccountMembershipLock(
                householdID: householdID,
                revokedAttemptID: oldAttemptID,
                revokedClaimBinding: binding,
                replacementAttemptID: replacementAttemptID,
                expectedParticipantID: account,
                leaseDuration: 60,
                validatedAt: Date()
            ),
            expected: .wrongAccount
        )
        XCTAssertEqual(postCommitServer.accountMembershipLocks[account]?.attemptID, replacementAttemptID)
        XCTAssertEqual(postCommitServer.accountMembershipLocks[account]?.state, .provisional)
        XCTAssertNil(postCommitServer.accountMembershipLocks["different-account"])
        XCTAssertEqual(postCommitTransport.accountLockReplacementMutationEnqueues, 1)
    }

    func testConcurrentRevokedGenerationReplacementHasOneConditionalWinner() async throws {
        let server = TestCloudServer()
        let account = "returning-child"
        let householdID = UUID()
        let oldAttemptID = UUID()
        let binding = "retained-revoked-claim-binding"
        let oldLock = AccountMembershipLock(
            householdID: householdID,
            attemptID: oldAttemptID,
            state: .active,
            expiresAt: .distantFuture,
            claimBinding: binding,
            ownerAuthorityBinding: "owner-authority"
        )
        server.accountMembershipLocks[account] = oldLock
        let pausedTransport = TestTransport(server: server, account: account)
        let winningTransport = TestTransport(server: server, account: account)
        let gate = TestSuspensionGate()
        pausedTransport.beforeAccountLockReplacementSubmission = { await gate.wait() }
        let pausedAttemptID = UUID()
        let winningAttemptID = UUID()

        let paused = Task {
            try await pausedTransport.replaceActiveRevokedAccountMembershipLock(
                householdID: householdID,
                revokedAttemptID: oldAttemptID,
                revokedClaimBinding: binding,
                replacementAttemptID: pausedAttemptID,
                expectedParticipantID: account,
                leaseDuration: 60,
                validatedAt: Date()
            )
        }
        while !gate.isWaiting { await Task.yield() }
        let winner = try await winningTransport.replaceActiveRevokedAccountMembershipLock(
            householdID: householdID,
            revokedAttemptID: oldAttemptID,
            revokedClaimBinding: binding,
            replacementAttemptID: winningAttemptID,
            expectedParticipantID: account,
            leaseDuration: 60,
            validatedAt: Date()
        )
        gate.resume()
        do {
            _ = try await paused.value
            XCTFail("A stale concurrent replacement must lose")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .accountMembershipConflict)
        }

        XCTAssertEqual(winner.attemptID, winningAttemptID)
        XCTAssertEqual(winner.state, .provisional)
        XCTAssertEqual(server.accountMembershipLocks[account], winner)
        XCTAssertEqual(pausedTransport.accountLockReplacementMutationEnqueues, 0)
        XCTAssertEqual(winningTransport.accountLockReplacementMutationEnqueues, 1)
        XCTAssertEqual(pausedTransport.accountLockMutationEnqueues, 0)
        XCTAssertEqual(winningTransport.accountLockMutationEnqueues, 0)
        await XCTAssertThrowsErrorAsync(
            try await winningTransport.activateAccountMembershipLock(
                householdID: householdID,
                attemptID: oldAttemptID,
                claimBinding: binding,
                ownerAuthorityBinding: "owner-authority",
                now: Date()
            ),
            expected: .accountMembershipConflict
        )
        XCTAssertEqual(server.accountMembershipLocks[account], winner)
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

    func testRevocationRetainsSurvivingFamilyMembershipLock() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "revoked-child")
        let child = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                       clock: { family.clock.now }, automaticSync: false)
        try await child.redeemInvitation(invitation.qrPayload)
        try await family.store.revokeInvitation(invitation.invitation)
        let lock = try XCTUnwrap(server.accountMembershipLocks["revoked-child"])

        do { try await child.synchronize(); XCTFail("Revoked access must fail") } catch {}
        XCTAssertNotNil(child.session.accountMembershipLockAttemptID)
        XCTAssertEqual(server.accountMembershipLocks["revoked-child"], lock)
        do { try await child.synchronize(); XCTFail("Revoked access must keep failing") } catch {}
        XCTAssertNotNil(child.session.accountMembershipLockAttemptID)
        XCTAssertEqual(server.accountMembershipLocks["revoked-child"], lock)
        XCTAssertEqual(transport.accountLockMutationEnqueues, 0)
        XCTAssertFalse(child.canRemoveUnavailableFamilyFromDevice)
        XCTAssertFalse(child.hasFamilyDeletionNotice)
        XCTAssertThrowsError(try child.removeUnavailableFamilyFromDevice())
        XCTAssertNotNil(child.household)
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

    func testRawAppleURLClaimsExactChildWithoutClearCode() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let repository = try HouseholdRepository(inMemory: true)
        let transport = TestTransport(server: server, account: "raw-link-child")
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
        XCTAssertEqual(joining.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(joining.profiles.map(\.id), [family.hanna.id])
        XCTAssertEqual(joining.snapshot.invitationClaim(invitation.invitation.id)?.codeDigest,
                       invitation.invitation.codeDigest)
        XCTAssertEqual(server.accountMembershipLocks["raw-link-child"]?.state, .active)
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertThrowsError(try joining.selectProfile(family.alek.id))
        XCTAssertThrowsError(try joining.selectProfile(family.parent.id))
    }

    func testRawAppleURLInterruptedClaimResumesWithoutClearCode() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "raw-retry-child")
        transport.claimError = CKError(.networkFailure)
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)

        do {
            try await joining.acceptSystemInvitation(location: location) {
                try await transport.accept(url: invitation.shareURL, expected: location)
            }
            XCTFail("The interrupted raw-link claim must report its transport error")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }

        XCTAssertEqual(joining.session.pendingInvitationAcceptance?.phase, .awaitingRedemption)
        XCTAssertEqual(joining.session.pendingInvitationAcceptance?.invitationID, invitation.invitation.id)
        XCTAssertNil(joining.selectedMember)
        XCTAssertEqual(transport.leaveAttempts, 0)

        transport.claimError = nil
        try await joining.retryInvitationCleanup()

        XCTAssertEqual(joining.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(joining.profiles.map(\.id), [family.hanna.id])
        XCTAssertEqual(server.accountMembershipLocks["raw-retry-child"]?.state, .active)
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertEqual(transport.leaveAttempts, 0)
    }

    func testRawAppleURLClaimUsesServerTimeDespiteDeviceClockSkew() async throws {
        for (index, joiningDate) in ["2025-09-07T16:00:00Z", "2027-09-07T16:00:00Z"].enumerated() {
            let server = TestCloudServer()
            let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
            let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
            server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(60)
            let transport = TestTransport(server: server, account: "skewed-child-\(index)")
            let joiningClock = TestClock(joiningDate)
            let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                             transport: transport,
                                             clock: { joiningClock.now }, automaticSync: false)
            let location = try await transport.invitationLocation(for: invitation.shareURL)

            try await joining.acceptSystemInvitation(location: location) {
                try await transport.accept(url: invitation.shareURL, expected: location)
            }

            XCTAssertEqual(joining.session.selectedMemberID, family.hanna.id)
            XCTAssertEqual(joining.snapshot.invitationClaim(invitation.invitation.id)?.memberID,
                           family.hanna.id)
            XCTAssertEqual(server.accountMembershipLocks["skewed-child-\(index)"]?.state, .active)
            XCTAssertEqual(transport.invitationValidationTimeCalls, 2)
            XCTAssertNil(joining.session.pendingInvitationAcceptance)
            XCTAssertEqual(transport.leaveAttempts, 0)
        }
    }

    func testRawAppleURLUsesAuthoritativeExpiryAndRejectsRevocation() async throws {
        for refusal in [HouseholdError.invitationExpired, .invitationRevoked] {
            let server = TestCloudServer()
            let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
            let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
            if refusal == .invitationExpired {
                server.authoritativeTime = invitation.invitation.expiresAt
            } else {
                try await family.store.revokeInvitation(invitation.invitation)
                server.zones[invitation.shareURL.lastPathComponent]?.pendingInvitationParticipants.insert(
                    invitation.invitation.cloudShareParticipantID
                )
            }
            let account = refusal == .invitationExpired ? "raw-expired" : "raw-revoked"
            let transport = TestTransport(server: server, account: account)
            let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                             clock: { family.clock.now }, automaticSync: false)
            let location = try await transport.invitationLocation(for: invitation.shareURL)

            await XCTAssertThrowsErrorAsync(
                try await joining.acceptSystemInvitation(location: location) {
                    try await transport.accept(url: invitation.shareURL, expected: location)
                },
                expected: refusal
            )

            XCTAssertNil(joining.household)
            XCTAssertNil(joining.selectedMember)
            XCTAssertEqual(server.accountMembershipLocks[account]?.state, .released)
            XCTAssertFalse(server.zones[location.zoneName]!.participants.contains(account))
        }
    }

    func testRawAppleURLRejectsWrongParticipantStatusPermissionAndRole() async throws {
        enum Rejection {
            case participant, status, permission, role
        }
        for rejection in [Rejection.participant, .status, .permission, .role] {
            let server = TestCloudServer()
            let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
            let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
            let account = "raw-rejected-\(rejection)"
            let transport = TestTransport(server: server, account: account)
            switch rejection {
            case .participant: transport.acceptedParticipantIDTransforms = true
            case .status: transport.invitationAccessStatusAccepted = false
            case .permission: transport.invitationAccessCanWrite = false
            case .role: transport.invitationAccessRoleIsPrivate = false
            }
            let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                             clock: { family.clock.now }, automaticSync: false)
            let location = try await transport.invitationLocation(for: invitation.shareURL)

            await XCTAssertThrowsErrorAsync(
                try await joining.acceptSystemInvitation(location: location) {
                    try await transport.accept(url: invitation.shareURL, expected: location)
                },
                expected: .invitationNotFound
            )

            XCTAssertNil(joining.household)
            XCTAssertNil(joining.selectedMember)
            XCTAssertNil(joining.session.pendingInvitationAcceptance)
            XCTAssertEqual(server.accountMembershipLocks[account]?.state, .released)
            XCTAssertFalse(server.zones[location.zoneName]!.participants.contains(account))
        }
    }

    func testRawAppleURLInterruptedValidationUsesBoundedCleanupBackoff() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(60)
        let transport = TestTransport(server: server, account: "raw-validation-retry")
        transport.invitationValidationTimeFailures = 1
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)

        do {
            try await joining.acceptSystemInvitation(location: location) {
                try await transport.accept(url: invitation.shareURL, expected: location)
            }
            XCTFail("The validation write failure must remain retryable")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }

        transport.invitationValidationTimeFailures = 1
        let cleanupDelay = try await joining.pendingInvitationCleanupDelay()
        XCTAssertEqual(cleanupDelay, 30)
        transport.invitationValidationTimeFailures = 1
        let retryDelay = try await joining.retryScheduledInvitationCleanup()
        XCTAssertEqual(retryDelay, 30)

        try await joining.retryInvitationCleanup()

        XCTAssertEqual(joining.selectedMember?.id, family.hanna.id)
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertEqual(transport.leaveAttempts, 0)
    }

    func testRawAppleURLCannotCrossHouseholdsOrReplayForAnotherAccount() async throws {
        let server = TestCloudServer()
        let first = try TestFamily(transport: TestTransport(server: server, account: "first-owner"))
        let firstInvitation = try await first.store.createChildInvitation(memberID: first.hanna.id)
        let second = try TestFamily(transport: TestTransport(server: server, account: "second-owner"))
        let secondInvitation = try await second.store.createChildInvitation(memberID: second.hanna.id)
        let crossingTransport = TestTransport(server: server, account: "crossing-child")
        let crossing = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                          transport: crossingTransport,
                                          clock: { first.clock.now }, automaticSync: false)
        let firstLocation = try await crossingTransport.invitationLocation(for: firstInvitation.shareURL)

        await XCTAssertThrowsErrorAsync(
            try await crossing.acceptSystemInvitation(location: firstLocation) {
                try await crossingTransport.accept(url: secondInvitation.shareURL, expected: firstLocation)
            },
            expected: .invitationNotFound
        )
        XCTAssertNil(crossing.household)
        XCTAssertFalse(server.zones[firstInvitation.shareURL.lastPathComponent]!.participants
            .contains("crossing-child"))
        XCTAssertFalse(server.zones[secondInvitation.shareURL.lastPathComponent]!.participants
            .contains("crossing-child"))

        let firstTransport = TestTransport(server: server, account: "first-child")
        let firstRecipient = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                                transport: firstTransport,
                                                clock: { first.clock.now }, automaticSync: false)
        let acceptedLocation = try await firstTransport.invitationLocation(for: firstInvitation.shareURL)
        try await firstRecipient.acceptSystemInvitation(location: acceptedLocation) {
            try await firstTransport.accept(url: firstInvitation.shareURL, expected: acceptedLocation)
        }
        XCTAssertEqual(firstRecipient.selectedMember?.id, first.hanna.id)

        let replayTransport = TestTransport(server: server, account: "replay-child")
        let replay = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                        transport: replayTransport,
                                        clock: { first.clock.now }, automaticSync: false)
        let replayLocation = try await replayTransport.invitationLocation(for: firstInvitation.shareURL)
        await XCTAssertThrowsErrorAsync(
            try await replay.acceptSystemInvitation(location: replayLocation) {
                try await replayTransport.accept(url: firstInvitation.shareURL, expected: replayLocation)
            },
            expected: .invitationConsumed
        )
        XCTAssertNil(replay.household)
        XCTAssertNil(replay.selectedMember)
        XCTAssertFalse(server.zones[replayLocation.zoneName]!.participants.contains("replay-child"))
    }

    func testPendingMetadataAcceptanceExpiresAndLeavesAccess() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "metadata-child")
        transport.claimError = CKError(.networkFailure)
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        do {
            try await joining.acceptSystemInvitation(location: location) {
                try await transport.accept(url: invitation.shareURL, expected: location)
            }
            XCTFail("The injected claim interruption must remain pending")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }

        family.move(to: "2026-09-08T17:00:01Z")
        transport.claimError = nil
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
        transport.claimError = CKError(.networkFailure)
        let joiningClock = TestClock("2027-09-07T16:00:00Z")
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { joiningClock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)

        do {
            try await joining.acceptSystemInvitation(location: location) {
                try await transport.accept(url: invitation.shareURL, expected: location)
            }
            XCTFail("The injected claim interruption must remain pending")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }

        XCTAssertEqual(joining.session.pendingInvitationAcceptance?.phase, .awaitingRedemption)
        XCTAssertEqual(joining.session.pendingInvitationAcceptance?.location.householdID,
                       family.store.household?.id)
        XCTAssertEqual(transport.leaveAttempts, 0)
    }

    func testPendingMetadataCleanupUsesServerTimeWithJoinerClockBehind() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(60)
        let transport = TestTransport(server: server, account: "behind-child")
        transport.claimError = CKError(.networkFailure)
        let joiningClock = TestClock("2025-09-07T16:00:00Z")
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { joiningClock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        do {
            try await joining.acceptSystemInvitation(location: location) {
                try await transport.accept(url: invitation.shareURL, expected: location)
            }
            XCTFail("The injected claim interruption must remain pending")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }
        server.authoritativeTime = invitation.invitation.expiresAt.addingTimeInterval(1)
        transport.claimError = nil

        try await joining.retryInvitationCleanup()

        XCTAssertNil(joining.household)
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertEqual(transport.leaveAttempts, 1)
    }

    func testPendingCleanupDelayUsesServerTimeWithDivergentDeviceClocks() async throws {
        for joiningDate in ["2025-09-07T16:00:00Z", "2027-09-07T16:00:00Z"] {
            let server = TestCloudServer()
            let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
            let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
            server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(60)
            let transport = TestTransport(server: server, account: "pending-\(joiningDate)")
            transport.claimError = CKError(.networkFailure)
            let joiningClock = TestClock(joiningDate)
            let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                             clock: { joiningClock.now }, automaticSync: false)
            let location = try await transport.invitationLocation(for: invitation.shareURL)
            do {
                try await joining.acceptSystemInvitation(location: location) {
                    try await transport.accept(url: invitation.shareURL, expected: location)
                }
                XCTFail("The injected claim interruption must remain pending")
            } catch {
                XCTAssertEqual((error as? CKError)?.code, .networkFailure)
            }

            let cleanupDelay = try await joining.pendingInvitationCleanupDelay()
            XCTAssertEqual(cleanupDelay, InvitationCode.lifetime - 60)
            XCTAssertNotNil(joining.session.pendingInvitationAcceptance)
        }
    }

    func testPendingCleanupEarlyWakeRecomputesAuthoritativeDelay() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(60)
        let transport = TestTransport(server: server, account: "early-child")
        transport.claimError = CKError(.networkFailure)
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        do {
            try await joining.acceptSystemInvitation(location: location) {
                try await transport.accept(url: invitation.shareURL, expected: location)
            }
            XCTFail("The injected claim interruption must remain pending")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }
        let firstDelay = try await joining.pendingInvitationCleanupDelay()
        server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(120)

        let recomputedDelay = try await joining.pendingInvitationCleanupDelay()

        XCTAssertEqual(firstDelay, InvitationCode.lifetime - 60)
        XCTAssertEqual(recomputedDelay, InvitationCode.lifetime - 120)
        XCTAssertNotNil(joining.session.pendingInvitationAcceptance)
    }

    func testPendingCleanupTransientValidationFailureUsesBoundedBackoff() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(60)
        let transport = TestTransport(server: server, account: "retry-child")
        transport.claimError = CKError(.networkFailure)
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        do {
            try await joining.acceptSystemInvitation(location: location) {
                try await transport.accept(url: invitation.shareURL, expected: location)
            }
            XCTFail("The injected claim interruption must remain pending")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
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
        server.authoritativeTime = invitation.invitation.createdAt.addingTimeInterval(60)
        let transport = TestTransport(server: server, account: "expired-child")
        transport.claimError = CKError(.networkFailure)
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { invitation.invitation.createdAt.addingTimeInterval(-365 * 86_400) },
                                         automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        do {
            try await joining.acceptSystemInvitation(location: location) {
                try await transport.accept(url: invitation.shareURL, expected: location)
            }
            XCTFail("The injected claim interruption must remain pending")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }
        transport.claimError = nil
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
        transport.claimError = CKError(.networkFailure)
        let joining = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                         clock: { family.clock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        do {
            try await joining.acceptSystemInvitation(location: location) {
                try await transport.accept(url: invitation.shareURL, expected: location)
            }
            XCTFail("The injected claim interruption must remain pending")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }

        transport.claimError = nil
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
        transport.invitationLocationError = CKError(.participantMayNeedVerification)
        try await joining.redeemInvitation(firstInvitation.qrPayload) { _ in true }
        transport.invitationLocationError = nil
        let secondLocation = try await transport.invitationLocation(for: secondInvitation.shareURL)
        var acceptanceCalls = 0

        await XCTAssertThrowsErrorAsync(
            try await joining.acceptSystemInvitation(location: secondLocation) { acceptanceCalls += 1 },
            expected: .invitationNotFound
        )

        XCTAssertEqual(acceptanceCalls, 0)
        XCTAssertNil(joining.household)
        XCTAssertEqual(joining.session.pendingInvitationPackage?.codeDigest,
                       InvitationCode.digest(firstInvitation.code))
        XCTAssertFalse(server.zones[firstInvitation.shareURL.lastPathComponent]!.participants
            .contains("joining-child"))
        XCTAssertFalse(server.zones[secondInvitation.shareURL.lastPathComponent]!.participants
            .contains("joining-child"))
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

@MainActor
final class MembershipRecoveryTests: XCTestCase {
    private func fresh(_ transport: TestTransport, clock: TestClock) throws -> HouseholdStore {
        try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                           clock: { clock.now }, automaticSync: false)
    }

    func testCodeBeforeAppleAcceptanceThenRawSystemURLClaimsExactChild() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "child")
        let joining = try fresh(transport, clock: family.clock)
        await XCTAssertThrowsErrorAsync(try await joining.redeemInvitation(invitation.code), expected: .invitationNotFound)
        XCTAssertNil(server.accountMembershipLocks["child"])
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        try await joining.acceptSystemInvitation(location: location) {
            try await transport.accept(url: invitation.shareURL, expected: location)
        }
        XCTAssertEqual(server.accountMembershipLocks["child"]?.state, .active)
        XCTAssertEqual(joining.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(joining.profiles.map(\.id), [family.hanna.id])
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertThrowsError(try joining.selectProfile(family.parent.id))
        XCTAssertThrowsError(try joining.selectProfile(family.alek.id))
        XCTAssertThrowsError(try joining.saveMember(name: "Unauthorized", role: .parent, avatar: .sun))
    }

    func testCleanupDuringNativeAcceptanceDoesNotReproduceMembershipConflict() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "child")
        let joining = try fresh(transport, clock: family.clock)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        var cleanupError: Error?
        var observedAcceptingAccess = false
        transport.beforeAccept = {
            observedAcceptingAccess = joining.session.pendingInvitationAcceptance?.phase == .acceptingAccess
                && server.accountMembershipLocks["child"]?.state == .provisional
            do { _ = try await joining.retryScheduledInvitationCleanup() }
            catch { cleanupError = error }
        }
        await XCTAssertThrowsErrorAsync(try await joining.acceptSystemInvitation(location: location) {
            try await transport.accept(url: invitation.shareURL, expected: location)
        }, expected: .invitationNotFound)
        XCTAssertTrue(observedAcceptingAccess)
        XCTAssertNil(cleanupError)
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertEqual(server.accountMembershipLocks["child"]?.state, .released)
        XCTAssertTrue(server.zones[location.zoneName]!.participants.contains("child"))
        XCTAssertNil(joining.selectedMember)
        transport.beforeAccept = nil
        try await joining.redeemInvitation(invitation.code)
        XCTAssertEqual(joining.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(joining.profiles.map(\.id), [family.hanna.id])
        XCTAssertEqual(server.accountMembershipLocks["child"]?.state, .active)
    }

    func testAcceptedImportWithoutPendingEnvelopeContinuesItsPersistedAttempt() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "child")
        let joining = try fresh(transport, clock: family.clock)
        try await joining.join(url: invitation.shareURL)
        let attempt = try XCTUnwrap(joining.session.accountMembershipLockAttemptID)
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertTrue(joining.profiles.isEmpty)
        try await joining.redeemInvitation(invitation.code)
        XCTAssertEqual(joining.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(server.accountMembershipLocks["child"]?.attemptID, attempt)
        XCTAssertEqual(server.accountMembershipLocks["child"]?.state, .active)
    }

    func testFreshOwnerLaunchRecoversSurvivingActiveMembershipAndJournal() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let chore = try family.chore()
        try await family.store.connect()
        let lock = try XCTUnwrap(server.accountMembershipLocks["owner"])
        let replacement = try fresh(TestTransport(server: server, account: "owner"), clock: family.clock)
        XCTAssertNil(replacement.household)
        XCTAssertNotEqual(replacement.session.deviceID, family.store.session.deviceID)
        try await replacement.reconcileAccountMembershipLock()
        XCTAssertEqual(replacement.household?.id, family.store.household?.id)
        XCTAssertEqual(replacement.selectedMember?.id, family.parent.id)
        XCTAssertEqual(replacement.selectedMember?.role, .parent)
        XCTAssertEqual(replacement.profiles.map(\.id), [family.parent.id])
        XCTAssertEqual(replacement.dailyList().map(\.id), [chore])
        XCTAssertEqual(replacement.pendingCount, 0)
        XCTAssertEqual(server.createCalls, 1)
        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
        XCTAssertThrowsError(try replacement.createFamily(name: "Duplicate", parentName: "Duplicate"))
        _ = try replacement.saveMember(name: "Recovered Child", role: .child, avatar: .flower)
    }

    func testLegacyOwnerRecoveryRecreatesOnlyMissingLifecycleMarker() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        try await family.store.connect()
        let householdID = try XCTUnwrap(family.store.household?.id)
        server.accountMembershipLocks.removeValue(forKey: "owner")
        server.lifecycleAuthorities.removeValue(forKey: householdID)
        let replacement = try fresh(TestTransport(server: server, account: "owner"), clock: family.clock)

        try await replacement.reconcileAccountMembershipLock()

        XCTAssertEqual(replacement.household?.id, householdID)
        XCTAssertEqual(replacement.selectedMember?.id, family.parent.id)
        XCTAssertEqual(server.accountMembershipLocks["owner"]?.state, .active)
        XCTAssertEqual(server.lifecycleAuthorities[householdID]?.state, .active)
        XCTAssertEqual(server.zones.count, 1)
    }

    func testFreshExactOwnerLockWithoutLocationOffersExplicitOwnerSelfRelease() async throws {
        let server = TestCloudServer()
        let householdID = UUID()
        let lock = AccountMembershipLock(
            householdID: householdID,
            attemptID: UUID(),
            state: .active,
            expiresAt: .distantFuture,
            claimBinding: AccountMembershipBinding.owner(householdID: householdID),
            ownerAuthorityBinding: AccountMembershipBinding.ownerAuthority(participantID: "owner")
        )
        server.accountMembershipLocks["owner"] = lock
        let repository = try HouseholdRepository(inMemory: true)
        var staleSession = try repository.session()
        staleSession.cloudParticipantID = "owner"
        staleSession.cloudCanWrite = true
        staleSession.accountMembershipLockAttemptID = lock.attemptID
        staleSession.accountMembershipClaimBinding = lock.claimBinding
        staleSession.celebratedWeeks = ["2026-W38"]
        try repository.commit(facts: [], session: staleSession)
        let clock = TestClock()
        var replacement = try HouseholdStore(
            repository: repository,
            transport: TestTransport(server: server, account: "owner"),
            clock: { clock.now },
            automaticSync: false
        )

        do {
            try await replacement.reconcileAccountMembershipLock()
            XCTFail("A missing owner location must require an explicit owner recovery choice")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .ownerMembershipUnavailable)
        }

        XCTAssertNil(replacement.household)
        XCTAssertTrue(replacement.requiresMembershipRecovery)
        XCTAssertTrue(replacement.canReleaseStaleOwnerMembership)
        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)

        let otherLock = AccountMembershipLock(
            householdID: UUID(), attemptID: UUID(), state: .active, expiresAt: .distantFuture,
            claimBinding: "other-account-claim", ownerAuthorityBinding: "other-owner-authority"
        )
        server.accountMembershipLocks["other"] = otherLock
        try await replacement.releaseStaleOwnerMembership()

        XCTAssertEqual(server.accountMembershipLocks["owner"]?.state, .released)
        XCTAssertEqual(server.accountMembershipLocks["owner"]?.claimBinding, lock.claimBinding)
        XCTAssertEqual(server.accountMembershipLocks["owner"]?.ownerAuthorityBinding, lock.ownerAuthorityBinding)
        XCTAssertEqual(server.accountMembershipLocks["other"], otherLock)
        XCTAssertTrue(server.lifecycleAuthorities.isEmpty)
        XCTAssertFalse(replacement.requiresMembershipRecovery)
        XCTAssertFalse(replacement.canReleaseStaleOwnerMembership)
        XCTAssertFalse(replacement.hasFamilyDeletionNotice)
        XCTAssertNil(replacement.household)
        XCTAssertNil(replacement.session.cloudParticipantID)
        XCTAssertNil(replacement.session.location)
        XCTAssertNil(replacement.session.cloudCanWrite)
        XCTAssertNil(replacement.session.accountMembershipLockAttemptID)
        XCTAssertNil(replacement.session.accountMembershipClaimBinding)
        XCTAssertEqual(replacement.session.deviceID, staleSession.deviceID)
        XCTAssertEqual(replacement.session.celebratedWeeks, staleSession.celebratedWeeks)

        replacement = try HouseholdStore(
            repository: repository,
            transport: TestTransport(server: server, account: "owner"),
            clock: { clock.now },
            automaticSync: false
        )
        XCTAssertNil(replacement.session.cloudParticipantID)
        XCTAssertNil(replacement.session.accountMembershipLockAttemptID)
        XCTAssertNil(replacement.session.accountMembershipClaimBinding)
        XCTAssertEqual(replacement.session.deviceID, staleSession.deviceID)
        XCTAssertEqual(replacement.session.celebratedWeeks, staleSession.celebratedWeeks)
        try replacement.createFamily(name: "New Family", parentName: "Owner")
        XCTAssertEqual(replacement.household?.name, "New Family")
    }

    func testReleasedLegacyOwnerLockCompletesInterruptedSelfReleaseRoutingCleanup() async throws {
        let server = TestCloudServer()
        let householdID = UUID()
        let lock = AccountMembershipLock(
            householdID: householdID,
            attemptID: UUID(),
            state: .released,
            expiresAt: .distantPast,
            claimBinding: AccountMembershipBinding.owner(householdID: householdID),
            ownerAuthorityBinding: nil
        )
        server.accountMembershipLocks["owner"] = lock
        server.lifecycleAuthorities[householdID] = .init(
            state: .active,
            creator: "owner",
            lastModifier: "owner"
        )
        let repository = try HouseholdRepository(inMemory: true)
        var interruptedSession = try repository.session()
        interruptedSession.cloudParticipantID = "owner"
        interruptedSession.cloudCanWrite = true
        interruptedSession.accountMembershipLockAttemptID = lock.attemptID
        interruptedSession.accountMembershipClaimBinding = lock.claimBinding
        interruptedSession.celebratedWeeks = ["2026-W38"]
        try repository.commit(facts: [], session: interruptedSession)
        let replacement = try HouseholdStore(
            repository: repository,
            transport: TestTransport(server: server, account: "owner"),
            clock: { TestClock().now },
            automaticSync: false
        )

        try await replacement.reconcileAccountMembershipLock()

        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
        XCTAssertFalse(replacement.requiresMembershipRecovery)
        XCTAssertFalse(replacement.hasFamilyDeletionNotice)
        XCTAssertNil(replacement.session.cloudParticipantID)
        XCTAssertNil(replacement.session.location)
        XCTAssertNil(replacement.session.cloudCanWrite)
        XCTAssertNil(replacement.session.accountMembershipLockAttemptID)
        XCTAssertNil(replacement.session.accountMembershipClaimBinding)
        XCTAssertEqual(replacement.session.deviceID, interruptedSession.deviceID)
        XCTAssertEqual(replacement.session.celebratedWeeks, interruptedSession.celebratedWeeks)
        XCTAssertEqual(try repository.session(), replacement.session)
    }

    func testInterruptedSelfReleaseCleanupRejectsGenerationChange() async throws {
        let server = TestCloudServer()
        let householdID = UUID()
        let lock = AccountMembershipLock(
            householdID: householdID,
            attemptID: UUID(),
            state: .released,
            expiresAt: .distantPast,
            claimBinding: AccountMembershipBinding.owner(householdID: householdID),
            ownerAuthorityBinding: nil
        )
        server.accountMembershipLocks["owner"] = lock
        server.lifecycleAuthorities[householdID] = .init(
            state: .active,
            creator: "owner",
            lastModifier: "owner"
        )
        let repository = try HouseholdRepository(inMemory: true)
        var interruptedSession = try repository.session()
        interruptedSession.cloudParticipantID = "owner"
        interruptedSession.cloudCanWrite = true
        interruptedSession.accountMembershipLockAttemptID = lock.attemptID
        interruptedSession.accountMembershipClaimBinding = lock.claimBinding
        try repository.commit(facts: [], session: interruptedSession)
        let transport = TestTransport(server: server, account: "owner")
        let replacement = try HouseholdStore(
            repository: repository,
            transport: transport,
            clock: { TestClock().now },
            automaticSync: false
        )
        transport.beforeMembershipLocation = { replacement.cloudAccountDidChange() }

        await XCTAssertThrowsErrorAsync(
            try await replacement.reconcileAccountMembershipLock(),
            expected: .accountMembershipConflict
        )

        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
        XCTAssertEqual(replacement.session, interruptedSession)
        XCTAssertEqual(try repository.session(), interruptedSession)
        XCTAssertTrue(replacement.requiresMembershipRecovery)
        XCTAssertFalse(replacement.hasFamilyDeletionNotice)
    }

    func testOwnerSelfReleaseFailsClosedAfterAccountLockGenerationOrLocationChanges() async throws {
        for condition in 0..<4 {
            let server = TestCloudServer()
            let householdID = UUID()
            let lock = AccountMembershipLock(
                householdID: householdID, attemptID: UUID(), state: .active,
                expiresAt: .distantFuture,
                claimBinding: AccountMembershipBinding.owner(householdID: householdID),
                ownerAuthorityBinding: AccountMembershipBinding.ownerAuthority(participantID: "owner")
            )
            server.accountMembershipLocks["owner"] = lock
            let transport = TestTransport(server: server, account: "owner")
            let replacement = try fresh(transport, clock: TestClock())
            await XCTAssertThrowsErrorAsync(
                try await replacement.reconcileAccountMembershipLock(),
                expected: .ownerMembershipUnavailable
            )
            XCTAssertTrue(replacement.canReleaseStaleOwnerMembership)

            switch condition {
            case 0:
                let otherHouseholdID = UUID()
                server.accountMembershipLocks["other"] = AccountMembershipLock(
                    householdID: otherHouseholdID, attemptID: UUID(), state: .active,
                    expiresAt: .distantFuture,
                    claimBinding: AccountMembershipBinding.owner(householdID: otherHouseholdID)
                )
                transport.account = "other"
            case 1:
                server.accountMembershipLocks["owner"] = AccountMembershipLock(
                    householdID: lock.householdID, attemptID: UUID(), state: lock.state,
                    expiresAt: lock.expiresAt, claimBinding: lock.claimBinding,
                    ownerAuthorityBinding: lock.ownerAuthorityBinding
                )
            case 2:
                server.zones["first"] = .init(householdID: householdID, name: "First", owner: "owner")
                server.zones["second"] = .init(householdID: householdID, name: "Second", owner: "owner")
            default:
                replacement.cloudAccountDidChange()
            }

            do {
                try await replacement.releaseStaleOwnerMembership()
                XCTFail("Changed recovery evidence must prevent owner self-release")
            } catch {
                XCTAssertEqual(
                    error as? HouseholdError,
                    condition == 0 ? .wrongAccount : .accountMembershipConflict
                )
            }
            XCTAssertFalse(replacement.canReleaseStaleOwnerMembership)
            XCTAssertNotEqual(server.accountMembershipLocks["owner"]?.state, .released)
            XCTAssertNotEqual(server.accountMembershipLocks["other"]?.state, .released)
        }
    }

    func testOwnerSelfReleaseRejectsGenerationChangeDuringRevalidation() async throws {
        let server = TestCloudServer()
        let householdID = UUID()
        let lock = AccountMembershipLock(
            householdID: householdID,
            attemptID: UUID(),
            state: .active,
            expiresAt: .distantFuture,
            claimBinding: AccountMembershipBinding.owner(householdID: householdID),
            ownerAuthorityBinding: AccountMembershipBinding.ownerAuthority(participantID: "owner")
        )
        server.accountMembershipLocks["owner"] = lock
        let transport = TestTransport(server: server, account: "owner")
        let replacement = try fresh(transport, clock: TestClock())
        await XCTAssertThrowsErrorAsync(
            try await replacement.reconcileAccountMembershipLock(),
            expected: .ownerMembershipUnavailable
        )
        transport.beforeMembershipLocation = { replacement.cloudAccountDidChange() }

        await XCTAssertThrowsErrorAsync(
            try await replacement.releaseStaleOwnerMembership(),
            expected: .wrongAccount
        )

        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
        XCTAssertEqual(transport.accountLockMutationEnqueues, 0)
    }

    func testExpiredUnclaimedProvisionalWithoutLocationReleasesAndReturnsToOnboarding() async throws {
        let clock = TestClock()
        let server = TestCloudServer()
        server.authoritativeTime = clock.now
        let lock = AccountMembershipLock(
            householdID: UUID(), attemptID: UUID(), state: .provisional,
            expiresAt: clock.now.addingTimeInterval(-1), claimBinding: nil
        )
        server.accountMembershipLocks["joining"] = lock
        let replacement = try fresh(TestTransport(server: server, account: "joining"), clock: clock)

        try await replacement.reconcileAccountMembershipLock()

        XCTAssertEqual(server.accountMembershipLocks["joining"]?.state, .released)
        XCTAssertEqual(server.accountMembershipLocks["joining"]?.attemptID, lock.attemptID)
        XCTAssertFalse(replacement.requiresMembershipRecovery)
        XCTAssertFalse(replacement.canReleaseStaleOwnerMembership)
        XCTAssertFalse(replacement.hasFamilyDeletionNotice)
        XCTAssertNil(replacement.household)
        try replacement.createFamily(name: "Available Again", parentName: "Parent")
        XCTAssertEqual(replacement.household?.name, "Available Again")
    }

    func testUnexpiredProvisionalWithoutLocationRemainsHeld() async throws {
        let clock = TestClock()
        let server = TestCloudServer()
        server.authoritativeTime = clock.now
        let lock = AccountMembershipLock(
            householdID: UUID(), attemptID: UUID(), state: .provisional,
            expiresAt: clock.now.addingTimeInterval(60), claimBinding: nil
        )
        server.accountMembershipLocks["joining"] = lock
        let transport = TestTransport(server: server, account: "joining")
        let replacement = try fresh(transport, clock: clock)

        await XCTAssertThrowsErrorAsync(
            try await replacement.reconcileAccountMembershipLock(),
            expected: .invitationUnavailable
        )

        XCTAssertEqual(server.accountMembershipLocks["joining"], lock)
        XCTAssertEqual(transport.accountLockMutationEnqueues, 0)
        XCTAssertTrue(replacement.requiresMembershipRecovery)
        XCTAssertFalse(replacement.canReleaseStaleOwnerMembership)
        XCTAssertFalse(replacement.hasFamilyDeletionNotice)
    }

    func testExpiredProvisionalValidationLocationAndAccountFailuresRemainHeld() async throws {
        let clock = TestClock()
        for failure in 0..<3 {
            let server = TestCloudServer()
            server.authoritativeTime = clock.now
            let account = "joining-\(failure)"
            let lock = AccountMembershipLock(
                householdID: UUID(), attemptID: UUID(), state: .provisional,
                expiresAt: clock.now.addingTimeInterval(-1), claimBinding: nil
            )
            server.accountMembershipLocks[account] = lock
            let transport = TestTransport(server: server, account: account)
            switch failure {
            case 0:
                transport.accountMembershipValidationTimeError = CKError(.networkFailure)
            case 1:
                transport.membershipLocationError = CKError(.serviceUnavailable)
            default:
                transport.beforeMembershipLocation = { transport.account = "other-account" }
            }
            let replacement = try fresh(transport, clock: clock)

            do {
                try await replacement.reconcileAccountMembershipLock()
                XCTFail("Uncertain expiry recovery must fail closed")
            } catch {
                if failure == 2 {
                    XCTAssertEqual(error as? HouseholdError, .wrongAccount)
                } else {
                    XCTAssertNotNil(error as? CKError)
                }
            }

            XCTAssertEqual(server.accountMembershipLocks[account], lock)
            XCTAssertEqual(transport.accountLockMutationEnqueues, 0)
            XCTAssertTrue(replacement.requiresMembershipRecovery)
            XCTAssertFalse(replacement.canReleaseStaleOwnerMembership)
            XCTAssertFalse(replacement.hasFamilyDeletionNotice)
        }
    }

    func testFullLockReleaseRejectsEveryConcurrentLockChangeAndAccountGenerationChange() async throws {
        let clock = TestClock()
        let householdID = UUID()
        let original = AccountMembershipLock(
            householdID: householdID, attemptID: UUID(), state: .active,
            expiresAt: .distantFuture,
            claimBinding: AccountMembershipBinding.owner(householdID: householdID),
            ownerAuthorityBinding: AccountMembershipBinding.ownerAuthority(participantID: "account")
        )
        let changedLocks: [AccountMembershipLock] = [
            AccountMembershipLock(householdID: UUID(), attemptID: original.attemptID, state: original.state,
                                  expiresAt: original.expiresAt, claimBinding: original.claimBinding),
            AccountMembershipLock(householdID: original.householdID, attemptID: UUID(), state: original.state,
                                  expiresAt: original.expiresAt, claimBinding: original.claimBinding),
            AccountMembershipLock(householdID: original.householdID, attemptID: original.attemptID, state: .active,
                                  expiresAt: .distantFuture, claimBinding: "concurrent-activation",
                                  ownerAuthorityBinding: "concurrent-owner"),
            AccountMembershipLock(householdID: original.householdID, attemptID: original.attemptID,
                                  state: original.state, expiresAt: original.expiresAt.addingTimeInterval(1),
                                  claimBinding: original.claimBinding),
            AccountMembershipLock(householdID: original.householdID, attemptID: original.attemptID,
                                  state: original.state, expiresAt: original.expiresAt,
                                  claimBinding: original.claimBinding, ownerAuthorityBinding: "changed-authority")
        ]

        for changed in changedLocks {
            let server = TestCloudServer()
            server.accountMembershipLocks["account"] = original
            let transport = TestTransport(server: server, account: "account")
            transport.beforeAccountLockReleaseSubmission = {
                server.accountMembershipLocks["account"] = changed
            }

            let released = try await transport.releaseAccountMembershipLock(
                expectedLock: original,
                expectedParticipantID: "account",
                reason: .ownerSelfRelease,
                clientTime: clock.now,
                expectedAccountGeneration: transport.accountGeneration
            )
            XCTAssertFalse(released)
            XCTAssertEqual(server.accountMembershipLocks["account"], changed)
        }

        let server = TestCloudServer()
        server.accountMembershipLocks["account"] = original
        let transport = TestTransport(server: server, account: "account")
        transport.beforeAccountLockReleaseSubmission = { transport.accountDidChange() }
        await XCTAssertThrowsErrorAsync(
            try await transport.releaseAccountMembershipLock(
                expectedLock: original,
                expectedParticipantID: "account",
                reason: .ownerSelfRelease,
                clientTime: clock.now,
                expectedAccountGeneration: transport.accountGeneration
            ),
            expected: .wrongAccount
        )
        XCTAssertEqual(server.accountMembershipLocks["account"], original)
    }

    func testExpiredProvisionalConcurrentActivationPreventsRecoveryRelease() async throws {
        let clock = TestClock()
        let server = TestCloudServer()
        server.authoritativeTime = clock.now
        let lock = AccountMembershipLock(
            householdID: UUID(), attemptID: UUID(), state: .provisional,
            expiresAt: clock.now.addingTimeInterval(-1), claimBinding: nil
        )
        server.accountMembershipLocks["joining"] = lock
        let transport = TestTransport(server: server, account: "joining")
        var activated = lock
        activated.state = .active
        activated.expiresAt = .distantFuture
        activated.claimBinding = "concurrent-invitation"
        activated.ownerAuthorityBinding = "concurrent-owner"
        transport.beforeAccountLockReleaseSubmission = {
            server.accountMembershipLocks["joining"] = activated
        }
        let replacement = try fresh(transport, clock: clock)

        await XCTAssertThrowsErrorAsync(
            try await replacement.reconcileAccountMembershipLock(),
            expected: .accountMembershipConflict
        )

        XCTAssertEqual(server.accountMembershipLocks["joining"], activated)
        XCTAssertTrue(replacement.requiresMembershipRecovery)
        XCTAssertFalse(replacement.canReleaseStaleOwnerMembership)
    }

    func testExpiredProvisionalRecoveryRejectsClassificationGenerationChange() async throws {
        let clock = TestClock()
        let server = TestCloudServer()
        server.authoritativeTime = clock.now
        let lock = AccountMembershipLock(
            householdID: UUID(),
            attemptID: UUID(),
            state: .provisional,
            expiresAt: clock.now.addingTimeInterval(-1),
            claimBinding: nil
        )
        server.accountMembershipLocks["joining"] = lock
        let transport = TestTransport(server: server, account: "joining")
        let replacement = try fresh(transport, clock: clock)
        transport.afterAccountMembershipLockRead = { replacement.cloudAccountDidChange() }

        await XCTAssertThrowsErrorAsync(
            try await replacement.reconcileAccountMembershipLock(),
            expected: .wrongAccount
        )

        XCTAssertEqual(server.accountMembershipLocks["joining"], lock)
        XCTAssertEqual(transport.accountLockMutationEnqueues, 0)
        XCTAssertTrue(replacement.requiresMembershipRecovery)
    }

    func testExpiredProvisionalConnectCannotReleaseConcurrentActivation() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: transport)
        server.authoritativeTime = family.clock.now
        let householdID = try XCTUnwrap(family.store.household?.id)
        let lock = AccountMembershipLock(
            householdID: householdID,
            attemptID: UUID(),
            state: .provisional,
            expiresAt: family.clock.now.addingTimeInterval(-1),
            claimBinding: nil
        )
        var activated = lock
        activated.state = .active
        activated.expiresAt = .distantFuture
        activated.claimBinding = "concurrent-invitation"
        activated.ownerAuthorityBinding = "concurrent-owner"
        server.accountMembershipLocks["owner"] = lock
        transport.beforeAccountLockReleaseSubmission = {
            server.accountMembershipLocks["owner"] = activated
        }

        await XCTAssertThrowsErrorAsync(
            try await family.store.connect(),
            expected: .accountMembershipConflict
        )

        XCTAssertEqual(server.accountMembershipLocks["owner"], activated)
        XCTAssertEqual(server.createCalls, 0)
    }

    func testNonOwnerClaimsNeverReceiveOwnerSelfRelease() async throws {
        let clock = TestClock()
        let householdID = UUID()
        let claims = [
            "invitation-bound-claim",
            AccountMembershipBinding.legacyShared(householdID: householdID, participantID: "account")
        ]
        for (index, claim) in claims.enumerated() {
            let server = TestCloudServer()
            let lock = AccountMembershipLock(
                householdID: householdID, attemptID: UUID(), state: .active,
                expiresAt: .distantFuture, claimBinding: claim
            )
            let account = "account-\(index)"
            server.accountMembershipLocks[account] = lock
            let replacement = try fresh(TestTransport(server: server, account: account), clock: clock)

            await XCTAssertThrowsErrorAsync(
                try await replacement.reconcileAccountMembershipLock(),
                expected: .invitationUnavailable
            )

            XCTAssertEqual(server.accountMembershipLocks[account], lock)
            XCTAssertFalse(replacement.canReleaseStaleOwnerMembership)
            XCTAssertFalse(replacement.hasFamilyDeletionNotice)
        }
    }

    func testLegacyExactOwnerTerminalDeletionUsesAuthenticatedLifecycleCleanup() async throws {
        let clock = TestClock()
        let server = TestCloudServer()
        let householdID = UUID()
        let lock = AccountMembershipLock(
            householdID: householdID, attemptID: UUID(), state: .active,
            expiresAt: .distantFuture,
            claimBinding: AccountMembershipBinding.owner(householdID: householdID),
            ownerAuthorityBinding: nil
        )
        server.accountMembershipLocks["owner"] = lock
        server.lifecycleAuthorities[householdID] = TestCloudServer.LifecycleAuthority(
            state: .deleted, creator: "owner", lastModifier: "owner"
        )
        let replacement = try fresh(TestTransport(server: server, account: "owner"), clock: clock)

        try await replacement.reconcileAccountMembershipLock()

        XCTAssertEqual(server.accountMembershipLocks["owner"]?.state, .released)
        XCTAssertFalse(replacement.requiresMembershipRecovery)
        XCTAssertFalse(replacement.canReleaseStaleOwnerMembership)
        XCTAssertTrue(replacement.hasFamilyDeletionNotice)
        XCTAssertNil(replacement.household)
    }

    func testReleasedOwnerLockRetainsAuthenticatedTerminalDeletionCleanup() async throws {
        let server = TestCloudServer()
        let householdID = UUID()
        let lock = AccountMembershipLock(
            householdID: householdID, attemptID: UUID(), state: .released,
            expiresAt: .distantPast,
            claimBinding: AccountMembershipBinding.owner(householdID: householdID),
            ownerAuthorityBinding: AccountMembershipBinding.ownerAuthority(participantID: "owner")
        )
        server.accountMembershipLocks["owner"] = lock
        server.lifecycleAuthorities[householdID] = .init(
            state: .deleted, creator: "owner", lastModifier: "owner"
        )
        let replacement = try fresh(TestTransport(server: server, account: "owner"), clock: TestClock())

        try await replacement.reconcileAccountMembershipLock()

        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
        XCTAssertFalse(replacement.requiresMembershipRecovery)
        XCTAssertTrue(replacement.hasFamilyDeletionNotice)
        XCTAssertNil(replacement.household)
    }

    func testReleasedLegacyOwnerLockRetainsAuthenticatedTerminalDeletionCleanup() async throws {
        let server = TestCloudServer()
        let householdID = UUID()
        let lock = AccountMembershipLock(
            householdID: householdID,
            attemptID: UUID(),
            state: .released,
            expiresAt: .distantPast,
            claimBinding: AccountMembershipBinding.owner(householdID: householdID),
            ownerAuthorityBinding: nil
        )
        server.accountMembershipLocks["owner"] = lock
        server.lifecycleAuthorities[householdID] = .init(
            state: .deleted,
            creator: "owner",
            lastModifier: "owner"
        )
        let replacement = try fresh(TestTransport(server: server, account: "owner"), clock: TestClock())

        try await replacement.reconcileAccountMembershipLock()

        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
        XCTAssertFalse(replacement.requiresMembershipRecovery)
        XCTAssertTrue(replacement.hasFamilyDeletionNotice)
        XCTAssertNil(replacement.household)
    }

    func testTerminalDeletionCleanupRejectsClassificationGenerationChange() async throws {
        let server = TestCloudServer()
        let householdID = UUID()
        let lock = AccountMembershipLock(
            householdID: householdID,
            attemptID: UUID(),
            state: .active,
            expiresAt: .distantFuture,
            claimBinding: AccountMembershipBinding.owner(householdID: householdID),
            ownerAuthorityBinding: nil
        )
        server.accountMembershipLocks["owner"] = lock
        server.lifecycleAuthorities[householdID] = .init(
            state: .deleted,
            creator: "owner",
            lastModifier: "owner"
        )
        let transport = TestTransport(server: server, account: "owner")
        let replacement = try fresh(transport, clock: TestClock())
        var lockReads = 0
        transport.afterAccountMembershipLockRead = {
            lockReads += 1
            if lockReads == 2 { replacement.cloudAccountDidChange() }
        }

        await XCTAssertThrowsErrorAsync(
            try await replacement.reconcileAccountMembershipLock(),
            expected: .accountMembershipConflict
        )

        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
        XCTAssertEqual(transport.accountLockMutationEnqueues, 0)
        XCTAssertTrue(replacement.requiresMembershipRecovery)
        XCTAssertFalse(replacement.hasFamilyDeletionNotice)
    }

    func testReleasedOwnerLockWithConflictingAuthorityCannotClaimDeletion() async throws {
        let server = TestCloudServer()
        let householdID = UUID()
        let attackerAuthority = AccountMembershipBinding.ownerAuthority(participantID: "attacker")
        let lock = AccountMembershipLock(
            householdID: householdID,
            attemptID: UUID(),
            state: .released,
            expiresAt: .distantPast,
            claimBinding: AccountMembershipBinding.owner(householdID: householdID),
            ownerAuthorityBinding: attackerAuthority
        )
        server.accountMembershipLocks["owner"] = lock
        server.lifecycleAuthorities[householdID] = .init(
            state: .deleted,
            creator: "attacker",
            lastModifier: "attacker"
        )
        let replacement = try fresh(TestTransport(server: server, account: "owner"), clock: TestClock())

        await XCTAssertThrowsErrorAsync(
            try await replacement.reconcileAccountMembershipLock(),
            expected: .accountMembershipConflict
        )

        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
        XCTAssertTrue(replacement.requiresMembershipRecovery)
        XCTAssertFalse(replacement.hasFamilyDeletionNotice)
    }

    func testReleasedOwnerLockWithConflictingRoutingRemainsBlocked() async throws {
        let server = TestCloudServer()
        let householdID = UUID()
        let lock = AccountMembershipLock(
            householdID: householdID,
            attemptID: UUID(),
            state: .released,
            expiresAt: .distantPast,
            claimBinding: AccountMembershipBinding.owner(householdID: householdID),
            ownerAuthorityBinding: AccountMembershipBinding.ownerAuthority(participantID: "owner")
        )
        server.accountMembershipLocks["owner"] = lock
        server.lifecycleAuthorities[householdID] = .init(
            state: .active,
            creator: "owner",
            lastModifier: "owner"
        )
        let repository = try HouseholdRepository(inMemory: true)
        var session = try repository.session()
        session.cloudParticipantID = "different-account"
        session.accountMembershipLockAttemptID = lock.attemptID
        session.accountMembershipClaimBinding = lock.claimBinding
        try repository.commit(facts: [], session: session)
        let replacement = try HouseholdStore(
            repository: repository,
            transport: TestTransport(server: server, account: "owner"),
            clock: { TestClock().now },
            automaticSync: false
        )

        await XCTAssertThrowsErrorAsync(
            try await replacement.reconcileAccountMembershipLock(),
            expected: .accountMembershipConflict
        )

        XCTAssertTrue(replacement.requiresMembershipRecovery)
        XCTAssertEqual(replacement.session, session)
        XCTAssertFalse(replacement.hasFamilyDeletionNotice)
    }

    func testAuthenticatedOwnerDeletionReleaseFailureRetriesTerminalCleanup() async throws {
        let server = TestCloudServer()
        let householdID = UUID()
        let lock = AccountMembershipLock(
            householdID: householdID, attemptID: UUID(), state: .active,
            expiresAt: .distantFuture,
            claimBinding: AccountMembershipBinding.owner(householdID: householdID),
            ownerAuthorityBinding: AccountMembershipBinding.ownerAuthority(participantID: "owner")
        )
        server.accountMembershipLocks["owner"] = lock
        server.lifecycleAuthorities[householdID] = .init(
            state: .deleted, creator: "owner", lastModifier: "owner"
        )
        let transport = TestTransport(server: server, account: "owner")
        transport.accountLockReleaseFailures = 1
        let replacement = try fresh(transport, clock: TestClock())

        do {
            try await replacement.reconcileAccountMembershipLock()
            XCTFail("A failed terminal release must remain retryable")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }
        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
        XCTAssertTrue(replacement.requiresMembershipRecovery)
        XCTAssertFalse(replacement.canReleaseStaleOwnerMembership)
        XCTAssertFalse(replacement.hasFamilyDeletionNotice)

        try await replacement.reconcileAccountMembershipLock()

        XCTAssertEqual(server.accountMembershipLocks["owner"]?.state, .released)
        XCTAssertFalse(replacement.requiresMembershipRecovery)
        XCTAssertTrue(replacement.hasFamilyDeletionNotice)
    }

    func testOwnerLifecycleNonterminalUnavailableAndForgedStatesNeverBecomeDeletion() async throws {
        let clock = TestClock()
        for condition in 0..<8 {
            let server = TestCloudServer()
            let householdID = UUID()
            let lock = AccountMembershipLock(
                householdID: householdID, attemptID: UUID(), state: .active,
                expiresAt: .distantFuture,
                claimBinding: AccountMembershipBinding.owner(householdID: householdID),
                ownerAuthorityBinding: condition == 7 ? "conflicting-authority" : nil
            )
            server.accountMembershipLocks["owner"] = lock
            switch condition {
            case 0:
                server.lifecycleAuthorities[householdID] = .init(
                    state: .active, creator: "owner", lastModifier: "owner"
                )
            case 1:
                server.lifecycleAuthorities[householdID] = .init(
                    state: .deleting, creator: "owner", lastModifier: "owner"
                )
            case 2:
                break
            case 3:
                server.lifecycleAuthorities[householdID] = .init(
                    state: .deleted, creator: "attacker", lastModifier: "owner"
                )
            case 4:
                server.lifecycleAuthorities[householdID] = .init(
                    state: .deleted, creator: "owner", lastModifier: "attacker"
                )
            case 5, 6:
                break
            default:
                server.lifecycleAuthorities[householdID] = .init(
                    state: .deleted, creator: "owner", lastModifier: "owner"
                )
            }
            let transport = TestTransport(server: server, account: "owner")
            if condition == 5 { transport.lifecycleStateError = HouseholdError.malformedData }
            if condition == 6 { transport.lifecycleStateError = CKError(.networkFailure) }
            let replacement = try fresh(transport, clock: clock)

            do {
                try await replacement.reconcileAccountMembershipLock()
                XCTFail("Only authenticated terminal deletion may complete cleanup")
            } catch {
                if condition == 3 || condition == 4 || condition == 7 {
                    XCTAssertEqual(error as? HouseholdError, .accountMembershipConflict)
                }
            }

            XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
            XCTAssertFalse(replacement.hasFamilyDeletionNotice)
            XCTAssertEqual(replacement.canReleaseStaleOwnerMembership, [0, 1, 2, 5, 6].contains(condition))
        }
    }

    func testIncompleteOwnerBootstrapZoneDoesNotInventProfilesOrDeleteData() async throws {
        let clock = TestClock()
        let server = TestCloudServer()
        let householdID = UUID()
        let zoneName = "EarnedIt-\(householdID.uuidString)"
        server.zones[zoneName] = TestCloudServer.Zone(
            householdID: householdID, name: "Incomplete", owner: "owner"
        )
        server.lifecycleAuthorities[householdID] = .init(
            state: .active, creator: "owner", lastModifier: "owner"
        )
        let lock = AccountMembershipLock(
            householdID: householdID, attemptID: UUID(), state: .active,
            expiresAt: .distantFuture,
            claimBinding: AccountMembershipBinding.owner(householdID: householdID),
            ownerAuthorityBinding: AccountMembershipBinding.ownerAuthority(participantID: "owner")
        )
        server.accountMembershipLocks["owner"] = lock
        let replacement = try fresh(TestTransport(server: server, account: "owner"), clock: clock)

        await XCTAssertThrowsErrorAsync(
            try await replacement.reconcileAccountMembershipLock(),
            expected: .familyStillSyncing
        )

        XCTAssertNotNil(server.zones[zoneName])
        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
        XCTAssertNil(replacement.household)
        XCTAssertTrue(replacement.profiles.isEmpty)
        XCTAssertFalse(replacement.canReleaseStaleOwnerMembership)
        XCTAssertFalse(replacement.hasFamilyDeletionNotice)
    }

    func testFreshJoinedParentAndChildRecoverOnlyTheirExactCommittedProfile() async throws {
        for role in [UserRole.parent, .child] {
            let server = TestCloudServer()
            let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
            let invitation = role == .parent
                ? try await family.store.createParentInvitation(name: "Joined Parent", avatar: .fox)
                : try await family.store.createChildInvitation(memberID: family.hanna.id)
            let original = try fresh(TestTransport(server: server, account: "joined"), clock: family.clock)
            try await original.redeemInvitation(invitation.qrPayload)
            let lock = try XCTUnwrap(server.accountMembershipLocks["joined"])
            let replacement = try fresh(TestTransport(server: server, account: "joined"), clock: family.clock)
            try await replacement.reconcileAccountMembershipLock()
            XCTAssertEqual(replacement.household?.id, family.store.household?.id)
            XCTAssertEqual(replacement.selectedMember?.id, invitation.invitation.memberID)
            XCTAssertEqual(replacement.selectedMember?.role, role)
            XCTAssertEqual(replacement.profiles.map(\.id), [invitation.invitation.memberID])
            XCTAssertEqual(server.accountMembershipLocks["joined"], lock)
            XCTAssertThrowsError(try replacement.selectProfile(family.alek.id))
        }
    }

    func testColdRestartResumesInterruptedRawSystemURLClaim() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "child")
        transport.claimError = CKError(.networkFailure)
        let repository = try HouseholdRepository(inMemory: true)
        let original = try HouseholdStore(repository: repository, transport: transport,
                                          clock: { family.clock.now }, automaticSync: false)
        let location = try await transport.invitationLocation(for: invitation.shareURL)
        do {
            try await original.acceptSystemInvitation(location: location) {
                try await transport.accept(url: invitation.shareURL, expected: location)
            }
            XCTFail("The interrupted claim must report its transport error")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }
        let lock = try XCTUnwrap(server.accountMembershipLocks["child"])
        XCTAssertEqual(lock.state, .provisional)
        transport.claimError = nil
        let replacement = try HouseholdStore(repository: repository, transport: transport,
                                             clock: { family.clock.now }, automaticSync: false)

        try await replacement.retryInvitationCleanup()

        XCTAssertEqual(replacement.household?.id, family.store.household?.id)
        XCTAssertEqual(replacement.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(replacement.profiles.map(\.id), [family.hanna.id])
        XCTAssertNil(replacement.session.pendingInvitationAcceptance)
        XCTAssertEqual(server.accountMembershipLocks["child"]?.attemptID, lock.attemptID)
        XCTAssertEqual(server.accountMembershipLocks["child"]?.state, .active)
    }

    func testProvisionalAccountRejectsDifferentHouseholdThenContinuesMatchingChild() async throws {
        let server = TestCloudServer()
        let first = try TestFamily(transport: TestTransport(server: server, account: "first-owner"))
        let invitation = try await first.store.createChildInvitation(memberID: first.hanna.id)
        let second = try TestFamily(transport: TestTransport(server: server, account: "second-owner"))
        let otherInvitation = try await second.store.createChildInvitation(memberID: second.hanna.id)
        let original = try fresh(TestTransport(server: server, account: "child"), clock: first.clock)
        try await original.join(url: invitation.shareURL)
        let lock = try XCTUnwrap(server.accountMembershipLocks["child"])
        let concurrent = try fresh(TestTransport(server: server, account: "child"), clock: first.clock)
        await XCTAssertThrowsErrorAsync(try await concurrent.redeemInvitation(otherInvitation.qrPayload),
                                        expected: .accountMembershipConflict)
        XCTAssertEqual(server.accountMembershipLocks["child"], lock)
        XCTAssertFalse(server.zones[otherInvitation.shareURL.lastPathComponent]!.participants.contains("child"))
        XCTAssertNil(concurrent.selectedMember)
        try await original.redeemInvitation(invitation.code)
        XCTAssertEqual(original.profiles.map(\.id), [first.hanna.id])
    }

    func testRevokedMembershipIsNotRecoveredOrReleasedBecauseLocalStateIsMissing() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let original = try fresh(TestTransport(server: server, account: "child"), clock: family.clock)
        try await original.redeemInvitation(invitation.qrPayload)
        let lock = try XCTUnwrap(server.accountMembershipLocks["child"])
        try await family.store.revokeInvitation(invitation.invitation)
        let transport = TestTransport(server: server, account: "child")
        let replacement = try fresh(transport, clock: family.clock)
        await XCTAssertThrowsErrorAsync(try await replacement.reconcileAccountMembershipLock(), expected: .invitationUnavailable)
        XCTAssertNil(replacement.household)
        XCTAssertTrue(replacement.requiresMembershipRecovery)
        XCTAssertFalse(replacement.canReleaseStaleOwnerMembership)
        XCTAssertTrue(replacement.profiles.isEmpty)
        XCTAssertEqual(server.accountMembershipLocks["child"], lock)
        XCTAssertEqual(transport.accountLockMutationEnqueues, 0)
        XCTAssertEqual(transport.leaveAttempts, 0)
        // Disconfirm a dependence on zone disappearance: retained transport access must still
        // refuse the revoked journal generation, even if a zone remains visible temporarily.
        server.zones[invitation.shareURL.lastPathComponent]?.participants.insert("child")
        await XCTAssertThrowsErrorAsync(try await replacement.reconcileAccountMembershipLock(),
                                        expected: .accountMembershipConflict)
        XCTAssertNil(replacement.selectedMember)
        XCTAssertEqual(server.accountMembershipLocks["child"], lock)
    }

    func testRevokedGenerationCannotReleaseActiveLockToJoinDifferentHousehold() async throws {
        let server = TestCloudServer()
        let first = try TestFamily(transport: TestTransport(server: server, account: "first-owner"))
        let firstInvitation = try await first.store.createChildInvitation(memberID: first.hanna.id)
        let original = try fresh(TestTransport(server: server, account: "child"), clock: first.clock)
        try await original.redeemInvitation(firstInvitation.qrPayload)
        let lock = try XCTUnwrap(server.accountMembershipLocks["child"])
        try await first.store.revokeInvitation(firstInvitation.invitation)
        server.lifecycleAuthorities[UUID()] = TestCloudServer.LifecycleAuthority(
            state: .deleted,
            creator: "unrelated-owner",
            lastModifier: "unrelated-owner"
        )

        let second = try TestFamily(transport: TestTransport(server: server, account: "second-owner"))
        let secondInvitation = try await second.store.createChildInvitation(memberID: second.hanna.id)
        let replacement = try fresh(TestTransport(server: server, account: "child"), clock: first.clock)

        await XCTAssertThrowsErrorAsync(
            try await replacement.redeemInvitation(secondInvitation.qrPayload),
            expected: .accountMembershipConflict
        )
        XCTAssertNil(replacement.household)
        XCTAssertEqual(server.accountMembershipLocks["child"], lock)
    }

    func testReleasedLockCannotRecoverVisibleOwnerZone() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        try await family.store.connect()
        var lock = try XCTUnwrap(server.accountMembershipLocks["owner"])
        lock.state = .released
        lock.claimBinding = nil
        server.accountMembershipLocks["owner"] = lock
        let replacement = try fresh(TestTransport(server: server, account: "owner"), clock: family.clock)
        try await replacement.reconcileAccountMembershipLock()
        XCTAssertNil(replacement.household)
        XCTAssertTrue(replacement.profiles.isEmpty)
        XCTAssertFalse(replacement.isCheckingAccountMembership)
        XCTAssertFalse(replacement.requiresMembershipRecovery)
        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
    }

    func testAmbiguousLegacyHouseholdsAndParentsRefuseWithoutChoosingAuthority() async throws {
        let server = TestCloudServer()
        let first = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        try await first.store.connect()
        server.accountMembershipLocks.removeValue(forKey: "owner")
        let second = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        try await second.store.connect()
        server.accountMembershipLocks.removeValue(forKey: "owner")
        let replacement = try fresh(TestTransport(server: server, account: "owner"), clock: first.clock)
        await XCTAssertThrowsErrorAsync(try await replacement.reconcileAccountMembershipLock(), expected: .accountMembershipConflict)
        XCTAssertNil(replacement.household)
        XCTAssertTrue(replacement.requiresMembershipRecovery)
        XCTAssertNil(server.accountMembershipLocks["owner"])
        XCTAssertThrowsError(try replacement.createFamily(name: "Duplicate", parentName: "Duplicate"))
        server.zones.removeValue(forKey: "EarnedIt-\(second.store.household!.id)")
        _ = try first.store.saveMember(name: "Legacy Parent", role: .parent, avatar: .fox)
        try await first.store.synchronize()
        let lock = try XCTUnwrap(server.accountMembershipLocks["owner"])
        await XCTAssertThrowsErrorAsync(try await replacement.reconcileAccountMembershipLock(), expected: .accountMembershipConflict)
        XCTAssertNil(replacement.selectedMember)
        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
    }

    func testLegacySingleProfileRecoversAndMultipleProfilesRefuse() async throws {
        for ambiguous in [false, true] {
            let server = TestCloudServer()
            let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
            try await family.store.connect()
            let location = try XCTUnwrap(family.store.session.location)
            server.zones[location.zoneName]?.participants.insert("legacy")
            let original = try fresh(TestTransport(server: server, account: "legacy"), clock: family.clock)
            let discovered = try await TestTransport(server: server, account: "legacy").membershipLocation(householdID: location.householdID)
            let shared = try XCTUnwrap(discovered)
            try await original.joinExisting(shared)
            let ids = ambiguous ? [family.hanna.id, family.alek.id] : [family.hanna.id]
            try original.requestProfiles(ids, deviceName: "Legacy Test Device")
            try await original.synchronize()
            try await family.store.synchronize()
            let request = try XCTUnwrap(family.store.pendingRequests.first)
            try family.store.approve(request, memberIDs: ids)
            try await family.store.synchronize()
            try await original.synchronize()
            let lock = try XCTUnwrap(server.accountMembershipLocks["legacy"])
            let replacement = try fresh(TestTransport(server: server, account: "legacy"), clock: family.clock)
            if ambiguous {
                await XCTAssertThrowsErrorAsync(try await replacement.reconcileAccountMembershipLock(), expected: .accountMembershipConflict)
                XCTAssertNil(replacement.selectedMember)
                XCTAssertTrue(replacement.profiles.isEmpty)
            } else {
                try await replacement.reconcileAccountMembershipLock()
                XCTAssertEqual(replacement.selectedMember?.id, family.hanna.id)
                XCTAssertEqual(replacement.profiles.map(\.id), [family.hanna.id])
            }
            XCTAssertEqual(server.accountMembershipLocks["legacy"], lock)
        }
    }

    func testRecoveryFailureKeepsMembershipBlocksCreationAndCanRetry() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        try await family.store.connect()
        let lock = try XCTUnwrap(server.accountMembershipLocks["owner"])
        let transport = TestTransport(server: server, account: "owner")
        transport.fetchError = CKError(.networkFailure)
        let replacement = try fresh(transport, clock: family.clock)
        XCTAssertTrue(replacement.isCheckingAccountMembership)
        do { try await replacement.reconcileAccountMembershipLock(); XCTFail("Expected offline recovery failure") }
        catch { XCTAssertEqual((error as? CKError)?.code, .networkFailure) }
        XCTAssertFalse(replacement.isCheckingAccountMembership)
        XCTAssertTrue(replacement.requiresMembershipRecovery)
        XCTAssertNil(replacement.household)
        XCTAssertThrowsError(try replacement.createFamily(name: "Duplicate", parentName: "Duplicate"))
        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
        transport.fetchError = nil
        try await replacement.reconcileAccountMembershipLock()
        XCTAssertFalse(replacement.requiresMembershipRecovery)
        XCTAssertEqual(replacement.selectedMember?.id, family.parent.id)
        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
    }

    func testEmptyAccountCompletesMembershipCheckBeforeNormalFirstRun() async throws {
        let server = TestCloudServer()
        let replacement = try fresh(TestTransport(server: server, account: "new-account"), clock: TestClock())
        XCTAssertTrue(replacement.isCheckingAccountMembership)
        try await replacement.reconcileAccountMembershipLock()
        XCTAssertFalse(replacement.isCheckingAccountMembership)
        XCTAssertFalse(replacement.requiresMembershipRecovery)
        XCTAssertNil(replacement.household)
        try replacement.createFamily(name: "New Family", parentName: "New Parent")
        XCTAssertNotNil(replacement.household)
        XCTAssertNil(server.accountMembershipLocks["new-account"])
    }

    func testOwnerLocalResetKeepsCloudMembershipAndRecoveredJournalPersists() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "membership-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: transport, url: directory.appending(path: "task-test.store"))
        try await family.store.connect()
        let lock = try XCTUnwrap(server.accountMembershipLocks["owner"])
        try family.store.resetLocalData()
        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
        XCTAssertTrue(family.store.isCheckingAccountMembership)
        XCTAssertNil(family.store.household)
        try await family.store.reconcileAccountMembershipLock()
        let reopened = try HouseholdStore(repository: HouseholdRepository(url: directory.appending(path: "task-test.store")),
                                           transport: transport, clock: { family.clock.now }, automaticSync: false)
        XCTAssertEqual(reopened.household?.id, family.store.household?.id)
        XCTAssertEqual(reopened.selectedMember?.id, family.parent.id)
        XCTAssertEqual(reopened.profiles.map(\.id), [family.parent.id])
        XCTAssertEqual(reopened.pendingCount, 0)
        XCTAssertEqual(transport.leaveAttempts, 0)
        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
    }

    func testRecoveryRejectsConflictingBindingAndAmbiguousNativeLocations() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        try await family.store.connect()
        var lock = try XCTUnwrap(server.accountMembershipLocks["owner"])
        lock.claimBinding = "conflicting-test-binding"
        server.accountMembershipLocks["owner"] = lock
        let replacement = try fresh(TestTransport(server: server, account: "owner"), clock: family.clock)
        await XCTAssertThrowsErrorAsync(try await replacement.reconcileAccountMembershipLock(), expected: .accountMembershipConflict)
        XCTAssertNil(replacement.selectedMember)
        XCTAssertEqual(server.accountMembershipLocks["owner"], lock)
        let ownerLocation = try XCTUnwrap(family.store.session.location)
        let otherLocation = CloudLocation(householdID: ownerLocation.householdID, zoneName: ownerLocation.zoneName,
                                           ownerName: "another-owner", isOwner: false)
        XCTAssertThrowsError(try CloudKitHouseholdTransport.uniqueMembershipLocation([ownerLocation, otherLocation]))
        XCTAssertEqual(try CloudKitHouseholdTransport.uniqueMembershipLocation([ownerLocation]), ownerLocation)
        XCTAssertNil(try CloudKitHouseholdTransport.uniqueMembershipLocation([]))
    }

    func testAccountChangeDuringRecoveryCannotRestoreAuthorityOrMutateOtherAccount() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        try await family.store.connect()
        let location = try XCTUnwrap(family.store.session.location)
        server.zones[location.zoneName]?.participants.insert("other-account")
        let locks = server.accountMembershipLocks
        let transport = TestTransport(server: server, account: "owner")
        transport.beforeFetch = { transport.account = "other-account" }
        let replacement = try fresh(transport, clock: family.clock)
        await XCTAssertThrowsErrorAsync(try await replacement.reconcileAccountMembershipLock(), expected: .wrongAccount)
        XCTAssertNil(replacement.household)
        XCTAssertTrue(replacement.profiles.isEmpty)
        XCTAssertEqual(server.accountMembershipLocks, locks)
        XCTAssertEqual(transport.leaveAttempts, 0)
        XCTAssertEqual(transport.accountLockMutationEnqueues, 0)
    }


    func testAcceptedCodeAfterCompleteLocalLossContinuesOriginalProvisionalLease() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let original = try fresh(TestTransport(server: server, account: "child"), clock: family.clock)
        try await original.join(url: invitation.shareURL)
        let lock = try XCTUnwrap(server.accountMembershipLocks["child"])
        let replacement = try fresh(TestTransport(server: server, account: "child"), clock: family.clock)
        try await replacement.redeemInvitation(invitation.code)
        XCTAssertEqual(replacement.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(replacement.profiles.map(\.id), [family.hanna.id])
        XCTAssertEqual(server.accountMembershipLocks["child"]?.attemptID, lock.attemptID)
        XCTAssertEqual(server.accountMembershipLocks["child"]?.state, .active)
    }

    func testFreshProvisionalCommittedClaimCompletesActiveRecovery() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let original = try fresh(TestTransport(server: server, account: "child"), clock: family.clock)
        try await original.redeemInvitation(invitation.qrPayload)
        var lock = try XCTUnwrap(server.accountMembershipLocks["child"])
        lock.state = .provisional
        lock.claimBinding = nil
        server.accountMembershipLocks["child"] = lock
        let replacement = try fresh(TestTransport(server: server, account: "child"), clock: family.clock)
        try await replacement.reconcileAccountMembershipLock()
        XCTAssertEqual(replacement.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(server.accountMembershipLocks["child"]?.state, .active)
        XCTAssertEqual(server.accountMembershipLocks["child"]?.attemptID, lock.attemptID)
    }

    func testExpiredUnclaimedProvisionalMembershipRefusesRecoveryWithoutAuthority() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let original = try fresh(TestTransport(server: server, account: "child"), clock: family.clock)
        try await original.join(url: invitation.shareURL)
        let lock = try XCTUnwrap(server.accountMembershipLocks["child"])
        server.authoritativeTime = invitation.invitation.expiresAt.addingTimeInterval(1)
        let replacement = try fresh(TestTransport(server: server, account: "child"), clock: family.clock)
        await XCTAssertThrowsErrorAsync(try await replacement.reconcileAccountMembershipLock(), expected: .invitationUnavailable)
        XCTAssertNil(replacement.household)
        XCTAssertTrue(replacement.profiles.isEmpty)
        XCTAssertEqual(server.accountMembershipLocks["child"], lock)
    }

}

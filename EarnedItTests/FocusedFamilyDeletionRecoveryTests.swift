import CloudKit
import XCTest
@testable import EarnedIt

@MainActor
final class FocusedFamilyDeletionRecoveryTests: XCTestCase {
    func testReinstalledOwnerFinishesDeletionBeforeOfflineChildResetAndFreshReinvite() async throws {
        let fixture = try await makeFixture(named: "reinstalled-owner-child")
        let childID = try XCTUnwrap(fixture.store.snapshot.members.first { $0.role == .child }?.id)
        let invitation = try await fixture.store.createChildInvitation(memberID: childID)
        let childTransport = TestTransport(server: fixture.server, account: "child")
        let child = try HouseholdStore(repository: HouseholdRepository(inMemory: true),
                                       transport: childTransport, clock: { fixture.clock.now }, automaticSync: false)
        try await child.redeemInvitation(invitation.qrPayload)
        let childLock = try XCTUnwrap(fixture.server.accountMembershipLocks["child"])
        fixture.transport.lifecycleFinalizeFailures = 1
        await XCTAssertThrowsCloudFailure(try await fixture.store.deleteFamily())
        let ownerLock = try XCTUnwrap(fixture.server.accountMembershipLocks["owner"])
        let recovered = try reinstalledOwner(fixture)
        try await recovered.reconcileAccountMembershipLock()

        XCTAssertTrue(recovered.canFinishDeletingFamily)
        XCTAssertFalse(recovered.canReleaseStaleOwnerMembership)
        XCTAssertNil(recovered.session.pendingFamilyDeletion)
        XCTAssertThrowsError(try createSameNamedFamily(in: recovered))
        await assertRefused(try await recovered.releaseStaleOwnerMembership())
        await assertRefused(try await recovered.deleteAllEarnedItData())
        await assertRefused(try await recovered.redeemInvitation(invitation.qrPayload))
        XCTAssertEqual(fixture.server.accountMembershipLocks["owner"], ownerLock)
        XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .deleting)
        do { try await child.synchronize(); XCTFail("Deleting authority must not permit child reset") }
        catch { XCTAssertEqual((error as? CKError)?.code, .zoneNotFound) }
        XCTAssertFalse(child.hasUnavailableFamilyRecovery)
        XCTAssertEqual(fixture.server.accountMembershipLocks["child"], childLock)
        childTransport.fetchError = CKError(.networkFailure)
        try await recovered.finishRecoveredFamilyDeletion()
        XCTAssertFalse(recovered.canFinishDeletingFamily)
        XCTAssertFalse(recovered.requiresMembershipRecovery)
        XCTAssertEqual(recovered.session.completedUnavailableFamilyRecovery?.membershipAttemptID, ownerLock.attemptID)
        XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .deleted)
        XCTAssertEqual(fixture.server.accountMembershipLocks["owner"]?.state, .released)
        await XCTAssertThrowsCloudFailure(try await child.synchronize())
        XCTAssertFalse(child.hasUnavailableFamilyRecovery)
        XCTAssertEqual(fixture.server.accountMembershipLocks["child"], childLock)
        childTransport.fetchError = nil
        try await child.synchronize()
        XCTAssertTrue(child.hasUnavailableFamilyRecovery)
        try await child.resetUnavailableFamily()
        try await child.reconcileAccountMembershipLock()
        try await recovered.reconcileAccountMembershipLock()
        XCTAssertFalse(recovered.hasUnavailableFamilyRecovery)
        try createSameNamedFamily(in: recovered)
        let freshID = try XCTUnwrap(recovered.household?.id)
        let freshChild = try XCTUnwrap(recovered.snapshot.members.first { $0.role == .child })
        let newInvitation = try await recovered.createChildInvitation(memberID: freshChild.id)
        try await child.redeemInvitation(newInvitation.qrPayload)
        XCTAssertNotEqual(freshID, fixture.householdID)
        XCTAssertEqual(child.household?.id, freshID)
        XCTAssertEqual(child.selectedMember?.id, freshChild.id)
        XCTAssertEqual(fixture.server.accountMembershipLocks["child"]?.householdID, freshID)
        XCTAssertEqual(fixture.server.accountMembershipLocks["owner"]?.householdID, freshID)
        XCTAssertNil(fixture.server.zones[fixture.location.zoneName])
        XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .deleted)
    }

    func testRecoveredDeletionRetriesFinalizationReleaseAndLocalCleanup() async throws {
        for phase in [InterruptionPhase.deletedAuthority, .membershipRelease, .localCleanup] {
            let fixture = try await makeFixture(named: "recovered-\(phase.rawValue)")
            fixture.transport.lifecycleFinalizeFailures = 1
            await XCTAssertThrowsCloudFailure(try await fixture.store.deleteFamily())
            let recovered = try reinstalledOwner(fixture)
            try await recovered.reconcileAccountMembershipLock()
            configureFailure(phase, transport: fixture.transport, resetter: fixture.resetter)
            await XCTAssertThrowsCloudFailure(try await recovered.finishRecoveredFamilyDeletion())
            XCTAssertTrue(recovered.canFinishDeletingFamily)
            XCTAssertTrue(recovered.requiresMembershipRecovery)
            XCTAssertNil(fixture.server.zones[fixture.location.zoneName])
            fixture.resetter.error = nil
            try await recovered.finishRecoveredFamilyDeletion()
            XCTAssertFalse(recovered.requiresMembershipRecovery)
            XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .deleted)
            XCTAssertEqual(fixture.server.accountMembershipLocks["owner"]?.state, .released)
            try await recovered.reconcileAccountMembershipLock()
            XCTAssertFalse(recovered.hasUnavailableFamilyRecovery)
        }
    }

    func testReinstallAfterRecoveredTerminalPublicationUsesExistingConfirmedReset() async throws {
        let fixture = try await makeFixture(named: "terminal-reinstall")
        fixture.transport.lifecycleFinalizeFailures = 1
        await XCTAssertThrowsCloudFailure(try await fixture.store.deleteFamily())
        let recovered = try reinstalledOwner(fixture)
        try await recovered.reconcileAccountMembershipLock()
        fixture.transport.accountLockReleaseFailures = 1
        await XCTAssertThrowsCloudFailure(try await recovered.finishRecoveredFamilyDeletion())
        let published = fixture.transport.lifecycleMutationEnqueues
        let again = try reinstalledOwner(fixture)
        try await again.reconcileAccountMembershipLock()
        XCTAssertTrue(again.hasUnavailableFamilyRecovery)
        XCTAssertEqual(again.unavailableFamilyReason, .deleted)
        try await again.resetUnavailableFamily()
        try await again.reconcileAccountMembershipLock()
        XCTAssertFalse(again.hasUnavailableFamilyRecovery)
        XCTAssertEqual(fixture.transport.lifecycleMutationEnqueues, published)
    }

    func testRecoveredPublicationRejectsInvalidServerEvidenceWithoutMutation() async throws {
        for condition in 0..<12 {
            let fixture = try await makeFixture(named: "refusal-\(condition)")
            fixture.transport.lifecycleFinalizeFailures = 1
            await XCTAssertThrowsCloudFailure(try await fixture.store.deleteFamily())
            let lock = try XCTUnwrap(fixture.server.accountMembershipLocks["owner"])
            let generation = fixture.transport.accountGeneration
            var expectedLock = lock
            switch condition {
            case 0: fixture.server.lifecycleAuthorities[fixture.householdID] = nil
            case 1: fixture.server.lifecycleAuthorities[fixture.householdID]?.state = .active
            case 2: fixture.server.lifecycleAuthorities[fixture.householdID] = .init(
                state: .deleting, creator: "foreign", lastModifier: "owner")
            case 3: fixture.server.lifecycleAuthorities[fixture.householdID]?.lastModifier = "foreign"
            case 4:
                fixture.server.zones[fixture.location.zoneName] = .init(
                    householdID: fixture.householdID, name: "Present", owner: "owner")
            case 5: fixture.transport.account = "different-account"
            case 6:
                fixture.transport.account = "different-account"
                fixture.transport.account = "owner"
            case 7:
                fixture.server.accountMembershipLocks["owner"] = .init(
                    householdID: lock.householdID, attemptID: UUID(), state: .active,
                    expiresAt: lock.expiresAt, claimBinding: lock.claimBinding,
                    ownerAuthorityBinding: lock.ownerAuthorityBinding)
            case 8: fixture.server.accountMembershipLocks["owner"]?.claimBinding = "invited-parent"
            case 9: fixture.server.accountMembershipLocks["owner"]?.ownerAuthorityBinding = "foreign"
            case 10: fixture.server.accountMembershipLocks["owner"] = nil
            default: expectedLock.claimBinding = "child-claim"
            }
            let locks = fixture.server.accountMembershipLocks
            let authority = fixture.server.lifecycleAuthorities[fixture.householdID]
            let zones = Set(fixture.server.zones.keys)
            let mutations = fixture.transport.lifecycleMutationEnqueues
            await assertRefused(try await fixture.transport.finalizeRecoveredFamilyDeletion(
                expectedLock: expectedLock, expectedParticipantID: "owner", expectedAccountGeneration: generation))
            XCTAssertEqual(fixture.transport.lifecycleMutationEnqueues, mutations, "\(condition)")
            XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, authority?.state)
            XCTAssertEqual(fixture.server.accountMembershipLocks, locks)
            XCTAssertEqual(Set(fixture.server.zones.keys), zones)
            XCTAssertEqual(fixture.store.household?.id, fixture.householdID)
        }
    }

    func testRecoveredFinalizationRechecksAccountLockAndZoneAcrossSuspension() async throws {
        for condition in 0..<5 {
            let fixture = try await makeFixture(named: "publication-race-\(condition)")
            fixture.transport.lifecycleFinalizeFailures = 1
            await XCTAssertThrowsCloudFailure(try await fixture.store.deleteFamily())
            let recovered = try reinstalledOwner(fixture)
            try await recovered.reconcileAccountMembershipLock()
            let mutations = fixture.transport.lifecycleMutationEnqueues
            fixture.transport.beforeLifecycleFinalize = {
                fixture.transport.beforeLifecycleFinalize = nil
                switch condition {
                case 0: fixture.transport.account = "other"
                case 1:
                    fixture.transport.account = "other"
                    fixture.transport.account = "owner"
                case 2:
                    let old = fixture.server.accountMembershipLocks["owner"]!
                    fixture.server.accountMembershipLocks["owner"] = .init(
                        householdID: old.householdID, attemptID: UUID(), state: .active,
                        expiresAt: old.expiresAt, claimBinding: old.claimBinding,
                        ownerAuthorityBinding: old.ownerAuthorityBinding)
                case 3:
                    fixture.server.zones[fixture.location.zoneName] = .init(
                        householdID: fixture.householdID, name: "Present", owner: "owner")
                default: fixture.server.lifecycleAuthorities[fixture.householdID] = .init(
                    state: .deleting, creator: "foreign", lastModifier: "owner")
                }
            }
            await assertRefused(try await recovered.finishRecoveredFamilyDeletion())
            XCTAssertEqual(fixture.transport.lifecycleMutationEnqueues, mutations)
            XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .deleting)
            XCTAssertNotEqual(fixture.server.accountMembershipLocks["owner"]?.state, .released)
            XCTAssertNil(recovered.session.completedUnavailableFamilyRecovery)
            XCTAssertTrue(recovered.requiresMembershipRecovery)
        }
    }

    func testRecoveredOldGenerationCannotReleaseOrClearNewHouseholdDuringRelease() async throws {
        let fixture = try await makeFixture(named: "release-race")
        fixture.transport.lifecycleFinalizeFailures = 1
        await XCTAssertThrowsCloudFailure(try await fixture.store.deleteFamily())
        let recovered = try reinstalledOwner(fixture)
        try await recovered.reconcileAccountMembershipLock()
        let newID = UUID()
        let newLock = AccountMembershipLock(householdID: newID, attemptID: UUID(), state: .active,
            expiresAt: .distantFuture, claimBinding: AccountMembershipBinding.owner(householdID: newID),
            ownerAuthorityBinding: AccountMembershipBinding.ownerAuthority(participantID: "owner"))
        let newZone = "EarnedIt-\(newID.uuidString)"
        fixture.transport.beforeAccountLockReleaseSubmission = {
            fixture.server.accountMembershipLocks["owner"] = newLock
            fixture.server.zones[newZone] = .init(householdID: newID, name: "New", owner: "owner")
            fixture.server.lifecycleAuthorities[newID] = .init(state: .active, creator: "owner", lastModifier: "owner")
        }
        await assertRefused(try await recovered.finishRecoveredFamilyDeletion())
        XCTAssertEqual(fixture.server.accountMembershipLocks["owner"], newLock)
        XCTAssertNotNil(fixture.server.zones[newZone])
        XCTAssertEqual(fixture.server.lifecycleAuthorities[newID]?.state, .active)
        XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .deleted)
        XCTAssertNil(recovered.session.completedUnavailableFamilyRecovery)
        XCTAssertTrue(recovered.requiresMembershipRecovery)
    }

    func testEmptyOwnerAccountResetCannotBypassDeletionBeforeDiscovery() async throws {
        let fixture = try await makeFixture(named: "reset-bypass")
        fixture.transport.lifecycleFinalizeFailures = 1
        await XCTAssertThrowsCloudFailure(try await fixture.store.deleteFamily())
        let recovered = try reinstalledOwner(fixture)
        let lock = fixture.server.accountMembershipLocks["owner"]
        await assertRefused(try await recovered.deleteAllEarnedItData())
        XCTAssertEqual(fixture.server.accountMembershipLocks["owner"], lock)
        XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .deleting)
        XCTAssertNil(recovered.session.accountDataResetProgress)
        try await recovered.reconcileAccountMembershipLock()
        XCTAssertTrue(recovered.canFinishDeletingFamily)
    }

    func testReinstalledOwnerCanFinishPreviouslySelfReleasedDeletingGenerationIdempotently() async throws {
        let fixture = try await makeFixture(named: "legacy-released-deleting")
        fixture.transport.lifecycleFinalizeFailures = 1
        await XCTAssertThrowsCloudFailure(try await fixture.store.deleteFamily())
        fixture.server.accountMembershipLocks["owner"]?.state = .released
        let lock = try XCTUnwrap(fixture.server.accountMembershipLocks["owner"])
        let recovered = try reinstalledOwner(fixture)
        try await recovered.reconcileAccountMembershipLock()
        XCTAssertTrue(recovered.canFinishRecoveredFamilyDeletion)
        XCTAssertThrowsError(try createSameNamedFamily(in: recovered))
        let releases = fixture.transport.accountLockMutationEnqueues
        try await recovered.finishRecoveredFamilyDeletion()
        XCTAssertEqual(fixture.server.accountMembershipLocks["owner"], lock)
        XCTAssertEqual(fixture.transport.accountLockMutationEnqueues, releases)
        XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .deleted)
        let published = fixture.transport.lifecycleMutationEnqueues
        try await fixture.transport.finalizeRecoveredFamilyDeletion(expectedLock: lock,
            expectedParticipantID: "owner", expectedAccountGeneration: fixture.transport.accountGeneration)
        XCTAssertEqual(fixture.transport.lifecycleMutationEnqueues, published)
        XCTAssertFalse(recovered.requiresMembershipRecovery)
        try await recovered.reconcileAccountMembershipLock()
        XCTAssertFalse(recovered.hasUnavailableFamilyRecovery)
    }

    func testRecoveredDeletionRetriesAfterLostFinalizationAcknowledgement() async throws {
        let fixture = try await makeFixture(named: "lost-finalization-response")
        fixture.transport.lifecycleFinalizeFailures = 1
        await XCTAssertThrowsCloudFailure(try await fixture.store.deleteFamily())
        let recovered = try reinstalledOwner(fixture)
        try await recovered.reconcileAccountMembershipLock()
        fixture.transport.recoveredFinalizePostCommitFailures = 1
        await XCTAssertThrowsCloudFailure(try await recovered.finishRecoveredFamilyDeletion())
        XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .deleted)
        XCTAssertEqual(fixture.server.accountMembershipLocks["owner"]?.state, .active)
        XCTAssertTrue(recovered.canFinishRecoveredFamilyDeletion)
        let publications = fixture.transport.lifecycleMutationEnqueues
        try await recovered.finishRecoveredFamilyDeletion()
        XCTAssertEqual(fixture.transport.lifecycleMutationEnqueues, publications)
        XCTAssertFalse(recovered.requiresMembershipRecovery)
        XCTAssertEqual(fixture.server.accountMembershipLocks["owner"]?.state, .released)
    }

    func testAccountSwitchAfterRecoveredReleaseRetainsLocalRecoveryUntilOriginalAccountReturns() async throws {
        let fixture = try await makeFixture(named: "post-release-account-switch")
        fixture.transport.lifecycleFinalizeFailures = 1
        await XCTAssertThrowsCloudFailure(try await fixture.store.deleteFamily())
        let recovered = try reinstalledOwner(fixture)
        try await recovered.reconcileAccountMembershipLock()
        let cleanups = fixture.resetter.clearCount
        fixture.transport.afterAccountLockReleaseSubmission = {
            fixture.transport.afterAccountLockReleaseSubmission = nil
            fixture.transport.account = "other"
        }
        await assertRefused(try await recovered.finishRecoveredFamilyDeletion())
        XCTAssertEqual(fixture.resetter.clearCount, cleanups)
        XCTAssertNil(recovered.session.completedUnavailableFamilyRecovery)
        XCTAssertTrue(recovered.requiresMembershipRecovery)
        XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .deleted)
        XCTAssertEqual(fixture.server.accountMembershipLocks["owner"]?.state, .released)
        XCTAssertNil(fixture.server.accountMembershipLocks["other"])
        fixture.transport.account = "owner"
        try await recovered.retryAccountMembershipRecovery()
        XCTAssertTrue(recovered.hasUnavailableFamilyRecovery)
        try await recovered.resetUnavailableFamily()
        XCTAssertFalse(recovered.requiresMembershipRecovery)
    }

    func testChangedAccountReinstallDoesNotRecoverOriginalOwnersDeletion() async throws {
        let fixture = try await makeFixture(named: "wrong-account-reinstall")
        fixture.transport.lifecycleFinalizeFailures = 1
        await XCTAssertThrowsCloudFailure(try await fixture.store.deleteFamily())
        let lock = fixture.server.accountMembershipLocks["owner"]
        let publications = fixture.transport.lifecycleMutationEnqueues
        fixture.transport.account = "other"
        let other = try reinstalledOwner(fixture)
        try await other.reconcileAccountMembershipLock()
        XCTAssertFalse(other.canFinishRecoveredFamilyDeletion)
        await assertRefused(try await other.finishRecoveredFamilyDeletion())
        XCTAssertNil(other.household)
        XCTAssertEqual(fixture.server.accountMembershipLocks["owner"], lock)
        XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .deleting)
        XCTAssertEqual(fixture.transport.lifecycleMutationEnqueues, publications)
        fixture.transport.account = "owner"
        try await other.retryAccountMembershipRecovery()
        XCTAssertTrue(other.canFinishRecoveredFamilyDeletion)
        try await other.finishRecoveredFamilyDeletion()
    }

    func testRecoveredOwnerDiscoveryRejectsAccountSwitchDuringLockRead() async throws {
        let fixture = try await makeFixture(named: "discovery-account-switch")
        fixture.transport.lifecycleFinalizeFailures = 1
        await XCTAssertThrowsCloudFailure(try await fixture.store.deleteFamily())
        let recovered = try reinstalledOwner(fixture)
        let publications = fixture.transport.lifecycleMutationEnqueues
        let lock = fixture.server.accountMembershipLocks["owner"]
        fixture.transport.afterAccountMembershipLockRead = {
            fixture.transport.afterAccountMembershipLockRead = nil
            fixture.transport.account = "other"
        }
        await assertRefused(try await recovered.reconcileAccountMembershipLock())
        XCTAssertFalse(recovered.canFinishRecoveredFamilyDeletion)
        XCTAssertFalse(recovered.canReleaseStaleOwnerMembership)
        XCTAssertNil(recovered.session.completedUnavailableFamilyRecovery)
        XCTAssertEqual(fixture.server.accountMembershipLocks["owner"], lock)
        XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .deleting)
        XCTAssertEqual(fixture.transport.lifecycleMutationEnqueues, publications)
    }

    private func reinstalledOwner(_ fixture: Fixture) throws -> HouseholdStore {
        try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: fixture.transport,
                           clock: { fixture.clock.now }, automaticSync: false, localDataResetter: fixture.resetter)
    }

    private func assertRefused(_ expression: @autoclosure () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { try await expression(); XCTFail("Expected fail-closed refusal", file: file, line: line) }
        catch { XCTAssertTrue(error is HouseholdError, "\(error)", file: file, line: line) }
    }

    private enum InterruptionPhase: String, CaseIterable {
        case lifecycleAuthority
        case deletingAuthority
        case familyZone
        case deletedAuthority
        case membershipRelease
        case localCleanup
    }

    func testEveryDeletionPhaseRelaunchesAndFinishesTheSameGeneration() async throws {
        for phase in InterruptionPhase.allCases {
            let fixture = try await makeFixture(named: phase.rawValue)
            let original = fixture.store.session
            configureFailure(phase, transport: fixture.transport, resetter: fixture.resetter)

            do {
                try await fixture.store.deleteFamily()
                XCTFail("Expected \(phase.rawValue) interruption")
            } catch {
                XCTAssertEqual((error as? CKError)?.code, .networkFailure, phase.rawValue)
            }

            XCTAssertEqual(fixture.store.session.pendingFamilyDeletion, true, phase.rawValue)
            XCTAssertEqual(fixture.store.session.householdID, original.householdID, phase.rawValue)
            XCTAssertEqual(fixture.store.session.location, original.location, phase.rawValue)
            XCTAssertEqual(
                fixture.store.session.accountMembershipLockAttemptID,
                original.accountMembershipLockAttemptID,
                phase.rawValue
            )

            let interruptedState = expectedInterruptedState(for: phase)
            XCTAssertEqual(
                fixture.server.lifecycleAuthorities[fixture.householdID]?.state,
                interruptedState.lifecycle,
                phase.rawValue
            )
            XCTAssertEqual(fixture.server.zones[fixture.location.zoneName] != nil, interruptedState.zoneExists,
                           phase.rawValue)
            XCTAssertEqual(fixture.server.accountMembershipLocks["owner"]?.state, interruptedState.lockState,
                           phase.rawValue)

            fixture.resetter.error = nil
            let relaunched = try HouseholdStore(
                repository: HouseholdRepository(url: fixture.storeURL),
                transport: fixture.transport,
                clock: { fixture.clock.now },
                automaticSync: false,
                localDataResetter: fixture.resetter
            )

            XCTAssertEqual(relaunched.session.pendingFamilyDeletion, true, phase.rawValue)
            XCTAssertEqual(relaunched.session.householdID, fixture.householdID, phase.rawValue)
            XCTAssertEqual(relaunched.session.location, fixture.location, phase.rawValue)
            XCTAssertEqual(relaunched.session.accountMembershipLockAttemptID, fixture.attemptID, phase.rawValue)

            try await relaunched.deleteFamily()

            XCTAssertNil(relaunched.household, phase.rawValue)
            XCTAssertNil(fixture.server.zones[fixture.location.zoneName], phase.rawValue)
            XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .deleted,
                           phase.rawValue)
            let released = try XCTUnwrap(fixture.server.accountMembershipLocks["owner"], phase.rawValue)
            XCTAssertEqual(released.householdID, fixture.householdID, phase.rawValue)
            XCTAssertEqual(released.attemptID, fixture.attemptID, phase.rawValue)
            XCTAssertEqual(released.state, .released, phase.rawValue)
            XCTAssertEqual(relaunched.session.completedUnavailableFamilyRecovery?.householdID,
                           fixture.householdID, phase.rawValue)
        }
    }

    func testPendingDeletionRefusesChangedAccountThenResumesForOriginalAccount() async throws {
        let fixture = try await makeFixture(named: "changed-account")
        fixture.transport.lifecycleBeginFailures = 1

        await XCTAssertThrowsCloudFailure(try await fixture.store.deleteFamily())
        XCTAssertEqual(fixture.store.session.pendingFamilyDeletion, true)

        fixture.transport.account = "different-owner"
        let wrongAccount = try HouseholdStore(
            repository: HouseholdRepository(url: fixture.storeURL),
            transport: fixture.transport,
            clock: { fixture.clock.now },
            automaticSync: false,
            localDataResetter: fixture.resetter
        )
        do {
            try await wrongAccount.deleteFamily()
            XCTFail("A different account must not continue pending deletion")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .wrongAccount)
        }
        XCTAssertNotNil(fixture.server.zones[fixture.location.zoneName])
        XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .active)
        XCTAssertEqual(wrongAccount.session.pendingFamilyDeletion, true)

        fixture.transport.account = "owner"
        try await wrongAccount.deleteFamily()

        XCTAssertNil(wrongAccount.household)
        XCTAssertNil(fixture.server.zones[fixture.location.zoneName])
        XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .deleted)
    }

    func testPendingDeletionCancelsQueuedAutomaticSyncBeforeFailure() async throws {
        let fixture = try await makeFixture(named: "queued-sync", automaticSync: true)
        let fetchCalls = fixture.transport.fetchCalls
        fixture.transport.lifecycleBeginFailures = 1
        fixture.store.scheduleSync()

        await XCTAssertThrowsCloudFailure(try await fixture.store.deleteFamily())
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(fixture.store.session.pendingFamilyDeletion, true)
        XCTAssertEqual(fixture.transport.fetchCalls, fetchCalls)
        XCTAssertNil(fixture.store.errorMessage)

        try await fixture.store.deleteFamily()
        XCTAssertNil(fixture.store.household)
        XCTAssertEqual(fixture.server.lifecycleAuthorities[fixture.householdID]?.state, .deleted)
    }

    func testPendingOldGenerationCannotDeleteFreshSameNamedFamilyInIsolatedStore() async throws {
        let old = try await makeFixture(named: "old-generation")
        old.resetter.error = CKError(.networkFailure)

        await XCTAssertThrowsCloudFailure(try await old.store.deleteFamily())
        XCTAssertEqual(old.store.session.pendingFamilyDeletion, true)
        XCTAssertNil(old.server.zones[old.location.zoneName])
        XCTAssertEqual(old.server.lifecycleAuthorities[old.householdID]?.state, .deleted)
        XCTAssertEqual(old.server.accountMembershipLocks["owner"]?.state, .released)

        old.resetter.error = nil
        let freshStoreURL = try isolatedStoreURL(named: "fresh-generation")
        let freshRepository = try HouseholdRepository(url: freshStoreURL)
        let fresh = try HouseholdStore(
            repository: freshRepository,
            transport: old.transport,
            clock: { old.clock.now },
            automaticSync: false
        )
        try createSameNamedFamily(in: fresh)
        try await fresh.connect()
        let freshHouseholdID = try XCTUnwrap(fresh.household?.id)
        let freshLocation = try XCTUnwrap(fresh.session.location)
        let freshAttemptID = try XCTUnwrap(fresh.session.accountMembershipLockAttemptID)

        XCTAssertNotEqual(freshHouseholdID, old.householdID)
        XCTAssertNotEqual(freshAttemptID, old.attemptID)

        let stale = try HouseholdStore(
            repository: HouseholdRepository(url: old.storeURL),
            transport: old.transport,
            clock: { old.clock.now },
            automaticSync: false,
            localDataResetter: old.resetter
        )
        do {
            try await stale.deleteFamily()
            XCTFail("The old deletion generation must not delete the fresh household")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .accountMembershipConflict)
        }

        XCTAssertEqual(stale.session.pendingFamilyDeletion, true)
        XCTAssertEqual(stale.household?.id, old.householdID)
        XCTAssertEqual(fresh.household?.id, freshHouseholdID)
        XCTAssertNotNil(old.server.zones[freshLocation.zoneName])
        XCTAssertEqual(old.server.lifecycleAuthorities[freshHouseholdID]?.state, .active)
        XCTAssertEqual(old.server.accountMembershipLocks["owner"]?.householdID, freshHouseholdID)
        XCTAssertEqual(old.server.accountMembershipLocks["owner"]?.attemptID, freshAttemptID)
    }

    private struct Fixture {
        let storeURL: URL
        let server: TestCloudServer
        let transport: TestTransport
        let resetter: TestAccountLocalDataResetter
        let clock: TestClock
        let store: HouseholdStore
        let householdID: UUID
        let location: CloudLocation
        let attemptID: UUID
    }

    private func makeFixture(named name: String, automaticSync: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "focused-deletion-\(name)-\(UUID().uuidString)")
        let storeURL = root.appending(path: "shared-household-v1.store")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let resetter = TestAccountLocalDataResetter()
        let clock = TestClock()
        let store = try HouseholdStore(
            repository: HouseholdRepository(url: storeURL),
            transport: transport,
            clock: { clock.now },
            automaticSync: automaticSync,
            localDataResetter: resetter
        )
        try createSameNamedFamily(in: store)
        try await store.connect()

        return Fixture(
            storeURL: storeURL,
            server: server,
            transport: transport,
            resetter: resetter,
            clock: clock,
            store: store,
            householdID: try XCTUnwrap(store.household?.id),
            location: try XCTUnwrap(store.session.location),
            attemptID: try XCTUnwrap(store.session.accountMembershipLockAttemptID)
        )
    }

    private func createSameNamedFamily(in store: HouseholdStore) throws {
        try store.createFamily(name: "Test Family", parentName: "Test Parent")
        _ = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
        _ = try store.saveMember(name: "Alek", role: .child, avatar: .rocket)
        try store.finishSetup()
    }

    private func configureFailure(
        _ phase: InterruptionPhase,
        transport: TestTransport,
        resetter: TestAccountLocalDataResetter
    ) {
        switch phase {
        case .lifecycleAuthority: transport.lifecycleEnsureFailures = 1
        case .deletingAuthority: transport.lifecycleBeginFailures = 1
        case .familyZone: transport.deleteFamilyFailures = 1
        case .deletedAuthority: transport.lifecycleFinalizeFailures = 1
        case .membershipRelease: transport.accountLockReleaseFailures = 1
        case .localCleanup: resetter.error = CKError(.networkFailure)
        }
    }

    private func expectedInterruptedState(for phase: InterruptionPhase) -> (
        lifecycle: FamilyLifecycleState,
        zoneExists: Bool,
        lockState: AccountMembershipLockState
    ) {
        switch phase {
        case .lifecycleAuthority, .deletingAuthority:
            return (.active, true, .active)
        case .familyZone:
            return (.deleting, true, .active)
        case .deletedAuthority:
            return (.deleting, false, .active)
        case .membershipRelease:
            return (.deleted, false, .active)
        case .localCleanup:
            return (.deleted, false, .released)
        }
    }

    private func isolatedStoreURL(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "focused-deletion-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appending(path: "shared-household-v1.store")
    }

    private func XCTAssertThrowsCloudFailure(
        _ expression: @autoclosure () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected a CloudKit network failure", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure, file: file, line: line)
        }
    }
}

import CloudKit
import CryptoKit
import XCTest
@testable import EarnedIt

@MainActor
final class InvitationDiagnosticsTests: XCTestCase {
    func testProductionInvitationPathEmitsOrderedMajorStagesWithoutPublishingSuccessfulTrace() async throws {
        let server = TestCloudServer()
        let diagnostics = FamilyTransitionDiagnostics()
        let transport = TestTransport(
            server: server,
            account: "owner-account",
            familyTransitionDiagnostics: diagnostics
        )
        let store = try HouseholdStore(
            repository: HouseholdRepository(inMemory: true),
            transport: transport,
            clock: { TestClock().now },
            automaticSync: false
        )
        try store.createFamily(name: "Test Family", parentName: "Test Parent")
        let parent = try XCTUnwrap(store.selectedMember)
        let child = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
        try store.finishSetup()

        let issued = try await store.createChildInvitation(memberID: child.id)

        XCTAssertEqual(issued.invitation.memberID, child.id)
        XCTAssertEqual(issued.invitation.role, .child)
        XCTAssertNotNil(parent)
        XCTAssertNil(store.latestInvitationDiagnostics)

        let orderedStages: [(FamilyTransitionDiagnosticStage, FamilyTransitionDiagnosticOutcome)] = [
            (.invitationStart, .started),
            (.invitationDiagnosticPreamble, .started),
            (.invitationDiagnosticIdentityRead, .started),
            (.invitationDiagnosticMembershipLockRead, .started),
            (.invitationGeneration, .started),
            (.zoneConnectionBootstrap, .started),
            (.participantLookup, .started),
            (.membershipLockAcquire, .started),
            (.zoneCreate, .started),
            (.lifecycleAuthorityPrepare, .started),
            (.initialFactSynchronization, .started),
            (.journalFetch, .started),
            (.ownerMembershipValidation, .started),
            (.membershipLockRead, .started),
            (.journalUpload, .started),
            (.preInvitationSynchronization, .started),
            (.invitationStateValidation, .started),
            (.validationTimeWrite, .started),
            (.shareFetch, .started),
            (.shareCreate, .started),
            (.invitationAccessOwnerValidation, .started),
            (.participantCreate, .started),
            (.invitationAppend, .started),
            (.invitationFactUpload, .started),
            (.completed, .succeeded)
        ]
        let positions = try orderedStages.map { stage, outcome in
            try XCTUnwrap(
                diagnostics.events.firstIndex { $0.stage == stage && $0.outcome == outcome },
                "Missing trace event: \(stage.rawValue) \(outcome.rawValue)"
            )
        }
        XCTAssertEqual(positions, positions.sorted())

        for stage in [
            "invitationGeneration", "zoneConnectionBootstrap", "initialFactSynchronization",
            "preInvitationSynchronization", "ownerMembershipValidation", "lifecycleAuthorityPrepare",
            "membershipLockRead", "journalFetch", "journalUpload", "participantCreate",
            "invitationAppend", "invitationFactUpload"
        ] {
            XCTAssertTrue(diagnostics.events.contains {
                $0.stage.rawValue == stage && $0.outcome == .started
            }, stage)
            XCTAssertTrue(diagnostics.events.contains {
                $0.stage.rawValue == stage && $0.outcome == .succeeded
            }, stage)
        }
    }

    func testPublicAttemptBoundaryClearsPriorFailureBeforeLocalValidationFailure() async throws {
        let diagnostics = FamilyTransitionDiagnostics()
        let transport = TestTransport(
            server: TestCloudServer(),
            account: "owner-account",
            familyTransitionDiagnostics: diagnostics
        )
        let store = try HouseholdStore(
            repository: HouseholdRepository(inMemory: true),
            transport: transport,
            automaticSync: false
        )
        try store.createFamily(name: "Test Family", parentName: "Test Parent")
        _ = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
        try store.finishSetup()
        diagnostics.beginInvitation(
            householdID: try XCTUnwrap(store.household).id,
            targetRole: .child,
            localAttemptID: nil,
            localParticipantID: "owner-account",
            hasCloudLocation: false
        )
        diagnostics.record(stage: .participantCreate, outcome: .failed,
                           error: HouseholdError.invitation)
        diagnostics.finish(outcome: .failed, error: HouseholdError.invitation)
        XCTAssertNotNil(store.latestInvitationDiagnostics)

        do {
            _ = try await store.createParentInvitation(name: "Test Parent", avatar: .star)
            XCTFail("The duplicate parent name must fail before invitation issuance")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .duplicateName)
        }

        XCTAssertNil(store.latestInvitationDiagnostics)
        XCTAssertTrue(diagnostics.events.isEmpty)
    }

    func testFailedOwnerMembershipTraceRetainsFirstFailureComparisonAndPreConversionError() async throws {
        let server = TestCloudServer()
        let diagnostics = FamilyTransitionDiagnostics()
        let rawCloudUser = "private-cloud-user-record-name"
        let transport = TestTransport(
            server: server,
            account: rawCloudUser,
            familyTransitionDiagnostics: diagnostics
        )
        let store = try HouseholdStore(
            repository: HouseholdRepository(inMemory: true),
            transport: transport,
            clock: { TestClock().now },
            automaticSync: false
        )
        try store.createFamily(name: "Test Family", parentName: "Test Parent")
        let parent = try XCTUnwrap(store.selectedMember)
        let child = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
        try store.finishSetup()
        try await store.connect()
        let householdID = try XCTUnwrap(store.household?.id)
        let originalLock = try XCTUnwrap(server.accountMembershipLocks[rawCloudUser])
        let wrongAuthority = AccountMembershipBinding.ownerAuthority(participantID: "other-private-account")
        let conflictingLock = AccountMembershipLock(
            householdID: householdID,
            attemptID: originalLock.attemptID,
            state: .active,
            expiresAt: originalLock.expiresAt,
            claimBinding: originalLock.claimBinding,
            ownerAuthorityBinding: wrongAuthority
        )
        server.accountMembershipLocks[rawCloudUser] = conflictingLock

        do {
            _ = try await store.createChildInvitation(memberID: child.id)
            XCTFail("The owner-authority mismatch must fail before share creation")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .accountMembershipConflict)
            store.recordInvitationErrorBeforePresentation(error)
        }

        let trace = try XCTUnwrap(store.latestInvitationDiagnostics)
        let expectedDigest = SHA256.hash(data: Data(rawCloudUser.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(trace.contains("cloudAccountIdentityKnown=true"))
        XCTAssertTrue(trace.contains("stage=invitationDiagnosticPreamble outcome=started"))
        XCTAssertTrue(trace.contains("stage=invitationDiagnosticIdentityRead outcome=succeeded"))
        XCTAssertTrue(trace.contains("stage=invitationDiagnosticMembershipLockRead outcome=succeeded"))
        XCTAssertTrue(trace.contains("branch=readOnlyPreambleRequiresOwnerReconciliation"))
        XCTAssertTrue(trace.contains("expected.householdMatchesTarget=true"))
        XCTAssertTrue(trace.contains("expected.memberProfilePresent=true"))
        XCTAssertTrue(trace.contains("expected.role=parent"))
        XCTAssertTrue(trace.contains("lock.householdMatchesTarget=true"))
        XCTAssertTrue(trace.contains("lock.state=active"))
        XCTAssertTrue(trace.contains("lock.claimBindingPresent=true"))
        XCTAssertTrue(trace.contains("lock.ownerAuthorityBindingPresent=true"))
        XCTAssertTrue(trace.contains("lock.ownerAuthorityBindingMatchesCurrentAccount=false"))
        XCTAssertTrue(trace.contains("lock.acquisitionNonceRelationship=matches"))
        XCTAssertTrue(trace.contains("compare.lock.ownerAuthorityBinding_eq_currentCloudAccount=false"))
        XCTAssertTrue(trace.contains("comparison.permitsActiveOwnerReuse=false"))
        XCTAssertTrue(trace.contains("branch=validateRetainedAttemptThenAcquire"))
        XCTAssertTrue(trace.contains("firstFailureStage=membershipLockActivate"))
        XCTAssertTrue(trace.contains(
            "firstFailureOperation=CKDatabase.modifyRecords.AccountMembershipLock.activate"
        ))
        XCTAssertTrue(trace.contains("detail=internalErrorBeforeUserFacingConversion"))
        XCTAssertTrue(trace.contains("kind:household,case:accountMembershipConflict"))
        XCTAssertEqual(transport.invitationAccessCreationCalls, 0)
        XCTAssertFalse(trace.contains(rawCloudUser))
        XCTAssertFalse(trace.contains(expectedDigest))
        XCTAssertFalse(trace.contains(householdID.uuidString))
        XCTAssertFalse(trace.contains(parent.id.uuidString))
        XCTAssertFalse(trace.contains(child.id.uuidString))
        XCTAssertFalse(trace.contains(originalLock.attemptID.uuidString))
        XCTAssertFalse(trace.contains(try XCTUnwrap(originalLock.claimBinding)))
        XCTAssertFalse(trace.contains(wrongAuthority))
    }

    func testPruningFailureRetainsReadOnlyPreambleIdentityLockAndComparison() async throws {
        let server = TestCloudServer()
        let diagnostics = FamilyTransitionDiagnostics()
        let rawCloudUser = "private-cloud-user-record-name"
        let transport = TestTransport(
            server: server,
            account: rawCloudUser,
            familyTransitionDiagnostics: diagnostics
        )
        let store = try HouseholdStore(
            repository: HouseholdRepository(inMemory: true),
            transport: transport,
            clock: { TestClock().now },
            automaticSync: false
        )
        try store.createFamily(name: "Test Family", parentName: "Test Parent")
        let parent = try XCTUnwrap(store.selectedMember)
        let child = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
        try store.finishSetup()
        try await store.connect()
        let householdID = try XCTUnwrap(store.household?.id)
        let lock = try XCTUnwrap(server.accountMembershipLocks[rawCloudUser])
        transport.invitationValidationTimeFailures = 1
        transport.invitationValidationTimeError = CKError(.networkFailure)

        do {
            _ = try await store.createChildInvitation(memberID: child.id)
            XCTFail("The pruning validation-time operation must fail")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
            store.recordInvitationErrorBeforePresentation(error)
        }

        let trace = try XCTUnwrap(store.latestInvitationDiagnostics)
        let expectedDigest = SHA256.hash(data: Data(rawCloudUser.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(trace.contains("cloudAccountIdentityKnown=true"))
        XCTAssertTrue(trace.contains("expected.householdMatchesTarget=true"))
        XCTAssertTrue(trace.contains("lock.householdMatchesTarget=true"))
        XCTAssertTrue(trace.contains("lock.state=active"))
        XCTAssertTrue(trace.contains("lock.acquisitionNonceRelationship=matches"))
        XCTAssertTrue(trace.contains("comparison.permitsActiveOwnerReuse=true"))
        XCTAssertTrue(trace.contains("branch=readOnlyPreambleExactActiveOwnerCandidate"))
        XCTAssertTrue(trace.contains("firstFailureStage=validationTimeWrite"))
        XCTAssertTrue(trace.contains(
            "firstFailureOperation=CKDatabase.modifyRecords.InvitationValidationTime"
        ))
        XCTAssertTrue(trace.contains("domain=CKErrorDomain"))
        XCTAssertTrue(trace.contains("code=\(CKError.Code.networkFailure.rawValue)"))
        XCTAssertTrue(trace.contains("detail=internalErrorBeforeUserFacingConversion"))
        XCTAssertEqual(transport.invitationAccessCreationCalls, 0)
        XCTAssertFalse(trace.contains(rawCloudUser))
        XCTAssertFalse(trace.contains(expectedDigest))
        XCTAssertFalse(trace.contains(householdID.uuidString))
        XCTAssertFalse(trace.contains(parent.id.uuidString))
        XCTAssertFalse(trace.contains(child.id.uuidString))
        XCTAssertFalse(trace.contains(lock.attemptID.uuidString))
        XCTAssertFalse(trace.contains(try XCTUnwrap(lock.claimBinding)))
    }

    func testLocalClaimConflictRecordsTypedComparisonBeforeFailureBranch() async throws {
        let server = TestCloudServer()
        let diagnostics = FamilyTransitionDiagnostics()
        let transport = TestTransport(
            server: server,
            account: "owner-account",
            familyTransitionDiagnostics: diagnostics
        )
        let repository = try HouseholdRepository(inMemory: true)
        let store = try HouseholdStore(
            repository: repository,
            transport: transport,
            clock: { TestClock().now },
            automaticSync: false
        )
        try store.createFamily(name: "Test Family", parentName: "Test Parent")
        let child = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
        try store.finishSetup()
        try await store.connect()

        let rawConflictingBinding = "raw-conflicting-local-claim-binding"
        var conflictingSession = store.session
        conflictingSession.accountMembershipClaimBinding = rawConflictingBinding
        try repository.commit(facts: [], session: conflictingSession)
        let reopened = try HouseholdStore(
            repository: repository,
            transport: transport,
            clock: { TestClock().now },
            automaticSync: false
        )

        do {
            _ = try await reopened.createChildInvitation(memberID: child.id)
            XCTFail("The local claim-binding mismatch must fail before share creation")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .accountMembershipConflict)
            reopened.recordInvitationErrorBeforePresentation(error)
        }

        let trace = try XCTUnwrap(reopened.latestInvitationDiagnostics)
        let comparison = try XCTUnwrap(
            trace.range(of: "compare.session.claimBinding_eq_derivedBinding=false")?.lowerBound
        )
        let branch = try XCTUnwrap(trace.range(of: "branch=localClaimBindingConflict")?.lowerBound)
        XCTAssertLessThan(comparison, branch)
        XCTAssertTrue(trace.contains("firstFailureStage=ownerMembershipValidation"))
        XCTAssertTrue(trace.contains(
            "firstFailureOperation=HouseholdStore.reconcileAccountMembershipLock"
        ))
        XCTAssertTrue(trace.contains("detail=internalErrorBeforeUserFacingConversion"))
        XCTAssertEqual(transport.invitationAccessCreationCalls, 0)
        XCTAssertFalse(trace.contains(rawConflictingBinding))
    }

    func testOwnerGuardFailureIsTheFirstCausalStageAfterShareFetch() async throws {
        let server = TestCloudServer()
        let diagnostics = FamilyTransitionDiagnostics()
        let account = "owner-account"
        let transport = TestTransport(
            server: server,
            account: account,
            familyTransitionDiagnostics: diagnostics
        )
        let store = try HouseholdStore(
            repository: HouseholdRepository(inMemory: true),
            transport: transport,
            clock: { TestClock().now },
            automaticSync: false
        )
        try store.createFamily(name: "Test Family", parentName: "Test Parent")
        let child = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
        try store.finishSetup()
        try await store.connect()
        let location = try XCTUnwrap(store.session.location)
        let originalZone = try XCTUnwrap(server.zones[location.zoneName])
        var nonOwnerZone = TestCloudServer.Zone(
            householdID: originalZone.householdID,
            name: originalZone.name,
            owner: "different-owner"
        )
        nonOwnerZone.participants = originalZone.participants.union([account])
        nonOwnerZone.pendingInvitationParticipants = originalZone.pendingInvitationParticipants
        nonOwnerZone.claimedInvitationAccounts = originalZone.claimedInvitationAccounts
        nonOwnerZone.facts = originalZone.facts
        nonOwnerZone.shareExists = true
        server.zones[location.zoneName] = nonOwnerZone

        do {
            _ = try await store.createChildInvitation(memberID: child.id)
            XCTFail("The invitation access owner guard must reject the operation")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .invitationOwnerRequired)
            store.recordInvitationErrorBeforePresentation(error)
        }

        let trace = try XCTUnwrap(store.latestInvitationDiagnostics)
        XCTAssertTrue(trace.contains("stage=shareFetch outcome=succeeded"))
        XCTAssertTrue(trace.contains("stage=invitationAccessOwnerValidation outcome=failed"))
        XCTAssertTrue(trace.contains("firstFailureStage=invitationAccessOwnerValidation"))
        XCTAssertTrue(trace.contains(
            "firstFailureOperation=CloudKitHouseholdTransport.createInvitationAccess.ownerGuard"
        ))
        XCTAssertTrue(trace.contains("kind:household,case:invitationOwnerRequired"))
        XCTAssertEqual(transport.invitationAccessCreationCalls, 1)
    }

    func testAllowListedTraceRecursivelyRendersCloudErrorsWithoutSecretMetadata() throws {
        let diagnostics = FamilyTransitionDiagnostics()
        let householdID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let rawNonce = UUID()
        let rawCloudUser = "raw-cloud-user-record-name"
        let invitationSecret = "INVITATION-SECRET-MUST-NOT-APPEAR"
        let shareURL = "https://icloud.com/share/SECRET-PATH"
        let rawBinding = "raw-private-claim-binding"
        let rawOwnerAuthority = "raw-owner-authority-binding"
        diagnostics.beginInvitation(
            householdID: householdID,
            targetRole: .child,
            localAttemptID: rawNonce,
            localParticipantID: rawCloudUser,
            hasCloudLocation: true
        )
        diagnostics.recordAccountIdentity(participantID: rawCloudUser, stable: true)
        diagnostics.recordMembershipLock(
            AccountMembershipLock(
                householdID: householdID,
                attemptID: rawNonce,
                state: .active,
                expiresAt: .distantFuture,
                claimBinding: rawBinding,
                ownerAuthorityBinding: rawOwnerAuthority
            ),
            expectedOwnerBinding: rawBinding,
            expectedOwnerAuthorityBinding: rawOwnerAuthority,
            localAttemptID: rawNonce
        )
        let nestedRecordID = CKRecord.ID(recordName: invitationSecret)
        let leaf = CKError(.serviceUnavailable, userInfo: [
            CKErrorRetryAfterKey: NSNumber(value: 13),
            NSLocalizedDescriptionKey: shareURL
        ])
        let nested = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [nestedRecordID: leaf],
            NSLocalizedDescriptionKey: invitationSecret
        ])
        let top = CKError(.partialFailure, userInfo: [
            CKErrorRetryAfterKey: NSNumber(value: 5),
            CKPartialErrorsByItemIDKey: [nestedRecordID: nested],
            NSLocalizedDescriptionKey: shareURL
        ])
        diagnostics.record(stage: .participantCreate, outcome: .failed, error: top)
        diagnostics.recordInternalError(top)
        diagnostics.finish(outcome: .failed, error: top)
        diagnostics.recordUserFacingErrorConversion(top)

        let trace = try XCTUnwrap(diagnostics.latestInvitationTrace)
        let expectedDigest = SHA256.hash(data: Data(rawCloudUser.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(trace.contains("traceFormat=EarnedItInvitationIssuance/3"))
        XCTAssertTrue(trace.contains("cloudAccountIdentityKnown=true"))
        XCTAssertTrue(trace.contains("lock.householdMatchesTarget=true"))
        XCTAssertTrue(trace.contains("path=topLevel,domain=CKErrorDomain"))
        XCTAssertTrue(trace.contains("path=topLevel.partial[1],domain=CKErrorDomain"))
        XCTAssertTrue(trace.contains("path=topLevel.partial[1].partial[1],domain=CKErrorDomain"))
        XCTAssertTrue(trace.contains("code=\(CKError.Code.partialFailure.rawValue)"))
        XCTAssertTrue(trace.contains("code=\(CKError.Code.serviceUnavailable.rawValue)"))
        XCTAssertTrue(trace.contains("retryAfterSeconds=13.0"))
        XCTAssertTrue(trace.contains("firstFailureStage=participantCreate"))
        XCTAssertFalse(trace.contains(rawCloudUser))
        XCTAssertFalse(trace.contains(expectedDigest))
        XCTAssertFalse(trace.contains(householdID.uuidString))
        XCTAssertFalse(trace.contains(parentID.uuidString))
        XCTAssertFalse(trace.contains(childID.uuidString))
        XCTAssertFalse(trace.contains(rawNonce.uuidString))
        XCTAssertFalse(trace.contains(rawBinding))
        XCTAssertFalse(trace.contains(rawOwnerAuthority))
        XCTAssertFalse(trace.contains(invitationSecret))
        XCTAssertFalse(trace.contains(shareURL))
    }

    func testLifecycleAuthorityComparisonRequiresExactCreatorAndModifier() {
        let account = "current-owner-account"
        let expectedBinding = AccountMembershipBinding.ownerAuthority(participantID: account)
        let accepted = CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
            recordTypeMatches: true,
            formatVersion: 1,
            rawState: FamilyLifecycleState.active.rawValue,
            creatorParticipantID: account,
            modifierParticipantID: account,
            ownerAuthorityBinding: expectedBinding
        )

        XCTAssertTrue(accepted.isAccepted)
        XCTAssertEqual(accepted.state, .active)
        XCTAssertEqual(accepted.creatorMatchesOwnerAuthority, true)
        XCTAssertEqual(accepted.modifierMatchesOwnerAuthority, true)

        let rejected = [
            CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
                recordTypeMatches: false,
                formatVersion: 1,
                rawState: FamilyLifecycleState.active.rawValue,
                creatorParticipantID: account,
                modifierParticipantID: account,
                ownerAuthorityBinding: expectedBinding
            ),
            CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
                recordTypeMatches: true,
                formatVersion: 2,
                rawState: FamilyLifecycleState.active.rawValue,
                creatorParticipantID: account,
                modifierParticipantID: account,
                ownerAuthorityBinding: expectedBinding
            ),
            CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
                recordTypeMatches: true,
                formatVersion: 1,
                rawState: "unknown-state",
                creatorParticipantID: account,
                modifierParticipantID: account,
                ownerAuthorityBinding: expectedBinding
            ),
            CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
                recordTypeMatches: true,
                formatVersion: 1,
                rawState: FamilyLifecycleState.active.rawValue,
                creatorParticipantID: nil,
                modifierParticipantID: account,
                ownerAuthorityBinding: expectedBinding
            ),
            CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
                recordTypeMatches: true,
                formatVersion: 1,
                rawState: FamilyLifecycleState.active.rawValue,
                creatorParticipantID: "foreign-account",
                modifierParticipantID: account,
                ownerAuthorityBinding: expectedBinding
            ),
            CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
                recordTypeMatches: true,
                formatVersion: 1,
                rawState: FamilyLifecycleState.active.rawValue,
                creatorParticipantID: account,
                modifierParticipantID: nil,
                ownerAuthorityBinding: expectedBinding
            ),
            CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
                recordTypeMatches: true,
                formatVersion: 1,
                rawState: FamilyLifecycleState.active.rawValue,
                creatorParticipantID: account,
                modifierParticipantID: "foreign-account",
                ownerAuthorityBinding: expectedBinding
            )
        ]

        XCTAssertTrue(rejected.allSatisfy { !$0.isAccepted })
    }

    func testLifecycleAuthorityIdentityDiagnosticsCategorizeRecordNameAndZoneRepresentations() throws {
        let expectedRecordName = "raw-current-owner-record-name"
        let ownerAuthorityBinding = AccountMembershipBinding.ownerAuthority(participantID: expectedRecordName)
        let defaultZone = CKRecordZone.ID.default
        let resolvedOwnerZone = CKRecordZone.ID(
            zoneName: defaultZone.zoneName,
            ownerName: expectedRecordName
        )
        let creator = CKRecord.ID(recordName: expectedRecordName, zoneID: defaultZone)
        let modifier = CKRecord.ID(recordName: expectedRecordName, zoneID: resolvedOwnerZone)

        XCTAssertNotEqual(creator, modifier)
        XCTAssertEqual(creator.recordName, modifier.recordName)

        let equivalentNames = CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
            recordTypeMatches: true,
            formatVersion: 1,
            rawState: FamilyLifecycleState.active.rawValue,
            creatorUserRecordID: creator,
            modifierUserRecordID: modifier,
            expectedCurrentUserRecordName: expectedRecordName,
            ownerAuthorityBinding: ownerAuthorityBinding
        )
        let equivalentIdentity = try XCTUnwrap(equivalentNames.identityRepresentation)

        XCTAssertTrue(equivalentNames.isAccepted)
        XCTAssertFalse(equivalentIdentity.expectedCurrentRecordNameIsCurrentUserDefaultName)
        XCTAssertEqual(equivalentIdentity.creatorRecordNameMatchesExpectedCurrentUser, true)
        XCTAssertEqual(equivalentIdentity.creatorRecordNameIsCurrentUserDefaultName, false)
        XCTAssertEqual(equivalentIdentity.modifierRecordNameMatchesExpectedCurrentUser, true)
        XCTAssertEqual(equivalentIdentity.modifierRecordNameIsCurrentUserDefaultName, false)
        XCTAssertEqual(equivalentIdentity.creatorModifierRecordNamesMatch, true)
        XCTAssertEqual(equivalentIdentity.creatorZoneNameIsDefault, true)
        XCTAssertEqual(equivalentIdentity.creatorZoneOwnerIsCurrentUserDefaultName, true)
        XCTAssertEqual(equivalentIdentity.creatorZoneOwnerMatchesExpectedCurrentUser, false)
        XCTAssertEqual(equivalentIdentity.modifierZoneNameIsDefault, true)
        XCTAssertEqual(equivalentIdentity.modifierZoneOwnerIsCurrentUserDefaultName, false)
        XCTAssertEqual(equivalentIdentity.modifierZoneOwnerMatchesExpectedCurrentUser, true)

        let currentUserDefaultID = CKRecord.ID(recordName: CKCurrentUserDefaultName, zoneID: defaultZone)
        let defaultNameSystemIDs = CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
            recordTypeMatches: true,
            formatVersion: 1,
            rawState: FamilyLifecycleState.active.rawValue,
            creatorUserRecordID: currentUserDefaultID,
            modifierUserRecordID: currentUserDefaultID,
            expectedCurrentUserRecordName: expectedRecordName,
            ownerAuthorityBinding: ownerAuthorityBinding
        )
        let defaultNameIdentity = try XCTUnwrap(defaultNameSystemIDs.identityRepresentation)

        XCTAssertTrue(defaultNameSystemIDs.isAccepted)
        XCTAssertEqual(defaultNameSystemIDs.creatorMatchesOwnerAuthority, true)
        XCTAssertEqual(defaultNameSystemIDs.modifierMatchesOwnerAuthority, true)
        XCTAssertEqual(defaultNameIdentity.creatorRecordNameMatchesExpectedCurrentUser, false)
        XCTAssertEqual(defaultNameIdentity.creatorRecordNameIsCurrentUserDefaultName, true)
        XCTAssertEqual(defaultNameIdentity.modifierRecordNameMatchesExpectedCurrentUser, false)
        XCTAssertEqual(defaultNameIdentity.modifierRecordNameIsCurrentUserDefaultName, true)
        XCTAssertEqual(defaultNameIdentity.creatorModifierRecordNamesMatch, true)

        let missingModifier = CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
            recordTypeMatches: true,
            formatVersion: 1,
            rawState: FamilyLifecycleState.active.rawValue,
            creatorUserRecordID: creator,
            modifierUserRecordID: nil,
            expectedCurrentUserRecordName: expectedRecordName,
            ownerAuthorityBinding: ownerAuthorityBinding
        )
        let missingModifierIdentity = try XCTUnwrap(missingModifier.identityRepresentation)

        XCTAssertFalse(missingModifier.isAccepted)
        XCTAssertNil(missingModifierIdentity.modifierRecordNameMatchesExpectedCurrentUser)
        XCTAssertNil(missingModifierIdentity.modifierRecordNameIsCurrentUserDefaultName)
        XCTAssertNil(missingModifierIdentity.creatorModifierRecordNamesMatch)
        XCTAssertNil(missingModifierIdentity.modifierZoneNameIsDefault)
        XCTAssertNil(missingModifierIdentity.modifierZoneOwnerIsCurrentUserDefaultName)
        XCTAssertNil(missingModifierIdentity.modifierZoneOwnerMatchesExpectedCurrentUser)

        let diagnostics = FamilyTransitionDiagnostics()
        diagnostics.beginInvitation(
            householdID: UUID(),
            targetRole: .child,
            localAttemptID: UUID(),
            localParticipantID: expectedRecordName,
            hasCloudLocation: false
        )
        diagnostics.recordLifecycleAuthority(
            attempt: 1,
            phase: .save,
            result: .recordAccepted,
            comparison: defaultNameSystemIDs
        )
        diagnostics.finish(outcome: .failed, error: HouseholdError.accountMembershipConflict)
        diagnostics.recordUserFacingErrorConversion(HouseholdError.accountMembershipConflict)

        let trace = try XCTUnwrap(diagnostics.latestInvitationTrace)
        XCTAssertTrue(trace.contains("lifecycle.creatorMatchesOwnerAuthority=true"))
        XCTAssertTrue(trace.contains("lifecycle.modifierMatchesOwnerAuthority=true"))
        XCTAssertTrue(trace.contains("lifecycle.expectedCurrentRecordNameIsCurrentUserDefaultName=false"))
        XCTAssertTrue(trace.contains("lifecycle.creatorRecordNameMatchesExpectedCurrentUser=false"))
        XCTAssertTrue(trace.contains("lifecycle.creatorRecordNameIsCurrentUserDefaultName=true"))
        XCTAssertTrue(trace.contains("lifecycle.modifierRecordNameMatchesExpectedCurrentUser=false"))
        XCTAssertTrue(trace.contains("lifecycle.modifierRecordNameIsCurrentUserDefaultName=true"))
        XCTAssertTrue(trace.contains("lifecycle.creatorModifierRecordNamesMatch=true"))
        XCTAssertTrue(trace.contains("lifecycle.creatorZoneNameIsDefault=true"))
        XCTAssertTrue(trace.contains("lifecycle.creatorZoneOwnerIsCurrentUserDefaultName=true"))
        XCTAssertTrue(trace.contains("lifecycle.creatorZoneOwnerMatchesExpectedCurrentUser=false"))
        XCTAssertTrue(trace.contains("lifecycle.modifierZoneNameIsDefault=true"))
        XCTAssertTrue(trace.contains("lifecycle.modifierZoneOwnerIsCurrentUserDefaultName=true"))
        XCTAssertTrue(trace.contains("lifecycle.modifierZoneOwnerMatchesExpectedCurrentUser=false"))
        XCTAssertTrue(trace.contains("lifecycle.recordAccepted=true"))
        XCTAssertFalse(trace.contains(expectedRecordName))
        XCTAssertFalse(trace.contains(CKCurrentUserDefaultName))
    }

    func testLifecycleAuthorityIdentityBindsOwnerIndependentlyFromCurrentReader() {
        let expectedRecordName = "current-owner-record-name"
        let ownerAuthorityBinding = AccountMembershipBinding.ownerAuthority(participantID: expectedRecordName)
        let invitedReaderRecordName = "invited-reader-record-name"
        let defaultZone = CKRecordZone.ID.default
        let exactExpected = CKRecord.ID(recordName: expectedRecordName, zoneID: defaultZone)
        let currentUserSentinel = CKRecord.ID(recordName: CKCurrentUserDefaultName, zoneID: defaultZone)
        let malformedSentinelZone = CKRecord.ID(
            recordName: CKCurrentUserDefaultName,
            zoneID: CKRecordZone.ID(
                zoneName: "malformed-zone",
                ownerName: CKCurrentUserDefaultName
            )
        )
        let malformedSentinelOwner = CKRecord.ID(
            recordName: CKCurrentUserDefaultName,
            zoneID: CKRecordZone.ID(
                zoneName: defaultZone.zoneName,
                ownerName: "foreign-owner"
            )
        )
        let foreign = CKRecord.ID(recordName: "foreign-user-record-name", zoneID: defaultZone)

        let acceptedPairs: [(CKRecord.ID, CKRecord.ID)] = [
            (exactExpected, exactExpected),
            (currentUserSentinel, currentUserSentinel),
            (exactExpected, currentUserSentinel),
            (currentUserSentinel, exactExpected)
        ]
        for (creator, modifier) in acceptedPairs {
            let comparison = CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
                recordTypeMatches: true,
                formatVersion: 1,
                rawState: FamilyLifecycleState.active.rawValue,
                creatorUserRecordID: creator,
                modifierUserRecordID: modifier,
                expectedCurrentUserRecordName: expectedRecordName,
                ownerAuthorityBinding: ownerAuthorityBinding
            )

            XCTAssertTrue(comparison.isAccepted)
            XCTAssertEqual(comparison.creatorMatchesOwnerAuthority, true)
            XCTAssertEqual(comparison.modifierMatchesOwnerAuthority, true)
        }

        let ownerIDsObservedByInvitee = CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
            recordTypeMatches: true,
            formatVersion: 1,
            rawState: FamilyLifecycleState.deleted.rawValue,
            creatorUserRecordID: exactExpected,
            modifierUserRecordID: exactExpected,
            expectedCurrentUserRecordName: invitedReaderRecordName,
            ownerAuthorityBinding: ownerAuthorityBinding
        )
        XCTAssertTrue(ownerIDsObservedByInvitee.isAccepted)

        let ownerSentinelObservedByInvitee = CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
            recordTypeMatches: true,
            formatVersion: 1,
            rawState: FamilyLifecycleState.deleted.rawValue,
            creatorUserRecordID: currentUserSentinel,
            modifierUserRecordID: currentUserSentinel,
            expectedCurrentUserRecordName: invitedReaderRecordName,
            ownerAuthorityBinding: ownerAuthorityBinding
        )
        XCTAssertFalse(ownerSentinelObservedByInvitee.isAccepted)

        let rejectedPairs: [(CKRecord.ID?, CKRecord.ID?)] = [
            (nil, currentUserSentinel),
            (currentUserSentinel, nil),
            (malformedSentinelZone, currentUserSentinel),
            (currentUserSentinel, malformedSentinelZone),
            (malformedSentinelOwner, currentUserSentinel),
            (currentUserSentinel, malformedSentinelOwner),
            (foreign, currentUserSentinel),
            (currentUserSentinel, foreign)
        ]
        for (creator, modifier) in rejectedPairs {
            let comparison = CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
                recordTypeMatches: true,
                formatVersion: 1,
                rawState: FamilyLifecycleState.active.rawValue,
                creatorUserRecordID: creator,
                modifierUserRecordID: modifier,
                expectedCurrentUserRecordName: expectedRecordName,
                ownerAuthorityBinding: ownerAuthorityBinding
            )

            XCTAssertFalse(comparison.isAccepted)
        }

        let invalidRecords = [
            CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
                recordTypeMatches: false,
                formatVersion: 1,
                rawState: FamilyLifecycleState.active.rawValue,
                creatorUserRecordID: currentUserSentinel,
                modifierUserRecordID: currentUserSentinel,
                expectedCurrentUserRecordName: expectedRecordName,
                ownerAuthorityBinding: ownerAuthorityBinding
            ),
            CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
                recordTypeMatches: true,
                formatVersion: 2,
                rawState: FamilyLifecycleState.active.rawValue,
                creatorUserRecordID: currentUserSentinel,
                modifierUserRecordID: currentUserSentinel,
                expectedCurrentUserRecordName: expectedRecordName,
                ownerAuthorityBinding: ownerAuthorityBinding
            ),
            CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
                recordTypeMatches: true,
                formatVersion: 1,
                rawState: "unknown-state",
                creatorUserRecordID: currentUserSentinel,
                modifierUserRecordID: currentUserSentinel,
                expectedCurrentUserRecordName: expectedRecordName,
                ownerAuthorityBinding: ownerAuthorityBinding
            )
        ]

        XCTAssertTrue(invalidRecords.allSatisfy { !$0.isAccepted })
    }

    func testLifecycleAuthorityBootstrapUsesAuthoritativeSaveResultWhenVerificationFetchIsMissing() throws {
        let recordID = CKRecord.ID(recordName: "expected-lifecycle-authority")
        let saved = CKRecord(recordType: "FamilyLifecycleAuthority", recordID: recordID)
        let account = "current-owner-account"
        let accepted = CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
            recordTypeMatches: true,
            formatVersion: 1,
            rawState: FamilyLifecycleState.active.rawValue,
            creatorParticipantID: account,
            modifierParticipantID: account,
            ownerAuthorityBinding: AccountMembershipBinding.ownerAuthority(participantID: account)
        )
        let initialFetchError = CKError(.unknownItem)
        let legacyVerificationFetchError = CKError(.unknownItem)

        XCTAssertEqual(CKError.Code.unknownItem.rawValue, 11)
        XCTAssertTrue(CloudKitHouseholdTransport.isRecordMissing(initialFetchError, recordID: recordID))
        XCTAssertTrue(CloudKitHouseholdTransport.shouldRetryLifecycleAuthorityBootstrap(
            legacyVerificationFetchError,
            recordID: recordID
        ))

        let saveResults: [CKRecord.ID: Result<CKRecord, Error>] = [recordID: .success(saved)]
        let savedComparison = try CloudKitHouseholdTransport.familyLifecycleAuthoritySaveComparison(
            recordID: recordID,
            saveResults: saveResults,
            comparison: { returnedRecord in
                XCTAssertEqual(returnedRecord.recordID, recordID)
                return accepted
            }
        )
        let state = try CloudKitHouseholdTransport.confirmFamilyLifecycleAuthoritySave(
            savedComparison,
            requestedState: .active
        )

        XCTAssertEqual(state, .active)
    }

    func testLifecycleAuthoritySaveResultStillRejectsForeignOrMismatchedAuthority() throws {
        let recordID = CKRecord.ID(recordName: "expected-lifecycle-authority")
        let foreignRecordID = CKRecord.ID(recordName: "foreign-lifecycle-authority")
        let foreignSaved = CKRecord(recordType: "FamilyLifecycleAuthority", recordID: foreignRecordID)
        let account = "current-owner-account"
        let ownerAuthorityBinding = AccountMembershipBinding.ownerAuthority(participantID: account)
        let acceptedDeleting = CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
            recordTypeMatches: true,
            formatVersion: 1,
            rawState: FamilyLifecycleState.deleting.rawValue,
            creatorParticipantID: account,
            modifierParticipantID: account,
            ownerAuthorityBinding: ownerAuthorityBinding
        )
        let foreignModifier = CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
            recordTypeMatches: true,
            formatVersion: 1,
            rawState: FamilyLifecycleState.active.rawValue,
            creatorParticipantID: account,
            modifierParticipantID: "foreign-account",
            ownerAuthorityBinding: ownerAuthorityBinding
        )

        XCTAssertThrowsError(try CloudKitHouseholdTransport.familyLifecycleAuthoritySaveComparison(
            recordID: recordID,
            saveResults: [foreignRecordID: .success(foreignSaved)],
            comparison: { _ in acceptedDeleting }
        )) { error in
            XCTAssertEqual(error as? HouseholdError, .malformedData)
        }
        XCTAssertThrowsError(try CloudKitHouseholdTransport.familyLifecycleAuthoritySaveComparison(
            recordID: recordID,
            saveResults: [recordID: .success(foreignSaved)],
            comparison: { _ in acceptedDeleting }
        )) { error in
            XCTAssertEqual(error as? HouseholdError, .accountMembershipConflict)
        }
        XCTAssertThrowsError(try CloudKitHouseholdTransport.confirmFamilyLifecycleAuthoritySave(
            acceptedDeleting,
            requestedState: .active
        )) { error in
            XCTAssertEqual(error as? HouseholdError, .accountMembershipConflict)
        }
        XCTAssertThrowsError(try CloudKitHouseholdTransport.confirmFamilyLifecycleAuthoritySave(
            foreignModifier,
            requestedState: .active
        )) { error in
            XCTAssertEqual(error as? HouseholdError, .accountMembershipConflict)
        }

        let missingSave = CKError(.unknownItem)
        XCTAssertThrowsError(try CloudKitHouseholdTransport.familyLifecycleAuthoritySaveComparison(
            recordID: recordID,
            saveResults: [recordID: .failure(missingSave)],
            comparison: { _ in acceptedDeleting }
        )) { error in
            XCTAssertEqual((error as? CKError)?.code, .unknownItem)
        }
    }

    func testLifecycleAuthorityFailureTraceIncludesLoadBearingComparisonWithoutRawIdentity() async throws {
        let server = TestCloudServer()
        let diagnostics = FamilyTransitionDiagnostics()
        let account = "raw-current-owner-account"
        let foreignModifier = "raw-foreign-modifier-account"
        let transport = TestTransport(
            server: server,
            account: account,
            familyTransitionDiagnostics: diagnostics
        )
        let store = try HouseholdStore(
            repository: HouseholdRepository(inMemory: true),
            transport: transport,
            clock: { TestClock().now },
            automaticSync: false
        )
        try store.createFamily(name: "Test Family", parentName: "Test Parent")
        let child = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
        try store.finishSetup()
        let householdID = try XCTUnwrap(store.household?.id)
        server.lifecycleAuthorities[householdID] = .init(
            state: .active,
            creator: account,
            lastModifier: foreignModifier
        )

        do {
            _ = try await store.createChildInvitation(memberID: child.id)
            XCTFail("A foreign lifecycle modifier must fail before share creation")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .accountMembershipConflict)
            store.recordInvitationErrorBeforePresentation(error)
        }

        let trace = try XCTUnwrap(store.latestInvitationDiagnostics)
        XCTAssertTrue(trace.contains("traceFormat=EarnedItInvitationIssuance/3"))
        XCTAssertTrue(trace.contains("detail=lifecycleAuthorityComparison"))
        XCTAssertTrue(trace.contains("lifecycle.attempt=1"))
        XCTAssertTrue(trace.contains("lifecycle.phase=existingFetch"))
        XCTAssertTrue(trace.contains("lifecycle.result=recordRejected"))
        XCTAssertTrue(trace.contains("lifecycle.recordTypeMatches=true"))
        XCTAssertTrue(trace.contains("lifecycle.formatVersionMatches=true"))
        XCTAssertTrue(trace.contains("lifecycle.state=active"))
        XCTAssertTrue(trace.contains("lifecycle.creatorPresent=true"))
        XCTAssertTrue(trace.contains("lifecycle.creatorMatchesOwnerAuthority=true"))
        XCTAssertTrue(trace.contains("lifecycle.modifierPresent=true"))
        XCTAssertTrue(trace.contains("lifecycle.modifierMatchesOwnerAuthority=false"))
        XCTAssertTrue(trace.contains("lifecycle.recordAccepted=false"))
        XCTAssertTrue(trace.contains("firstFailureStage=lifecycleAuthorityPrepare"))
        XCTAssertEqual(transport.invitationAccessCreationCalls, 0)
        XCTAssertFalse(trace.contains(account))
        XCTAssertFalse(trace.contains(foreignModifier))
    }

    func testLifecycleAuthorityRetryTraceRetainsCaughtCloudErrorsAndExhaustion() throws {
        let diagnostics = FamilyTransitionDiagnostics()
        let householdID = UUID()
        let rawAccount = "raw-owner-account"
        let rawRecordName = "raw-lifecycle-record-name"
        diagnostics.beginInvitation(
            householdID: householdID,
            targetRole: .child,
            localAttemptID: UUID(),
            localParticipantID: rawAccount,
            hasCloudLocation: false
        )
        let recordID = CKRecord.ID(recordName: rawRecordName)
        let missing = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [recordID: CKError(.unknownItem)]
        ])
        for attempt in 1...4 {
            diagnostics.recordLifecycleAuthority(
                attempt: attempt,
                phase: .verificationFetch,
                result: .retryableCloudError,
                error: missing
            )
        }
        diagnostics.recordLifecycleAuthority(
            attempt: 4,
            phase: .terminal,
            result: .retriesExhausted
        )
        diagnostics.record(
            stage: .lifecycleAuthorityPrepare,
            outcome: .failed,
            error: HouseholdError.accountMembershipConflict
        )
        diagnostics.recordInternalError(HouseholdError.accountMembershipConflict)
        diagnostics.finish(outcome: .failed, error: HouseholdError.accountMembershipConflict)
        diagnostics.recordUserFacingErrorConversion(HouseholdError.accountMembershipConflict)

        let trace = try XCTUnwrap(diagnostics.latestInvitationTrace)
        XCTAssertEqual(trace.components(separatedBy: "lifecycle.result=retryableCloudError").count - 1, 4)
        XCTAssertTrue(trace.contains("lifecycle.phase=verificationFetch"))
        XCTAssertTrue(trace.contains("lifecycle.result=retriesExhausted"))
        XCTAssertTrue(trace.contains("code=\(CKError.Code.partialFailure.rawValue)"))
        XCTAssertTrue(trace.contains("code=\(CKError.Code.unknownItem.rawValue)"))
        XCTAssertTrue(trace.contains("kind:household,case:accountMembershipConflict"))
        XCTAssertFalse(trace.contains(rawAccount))
        XCTAssertFalse(trace.contains(rawRecordName))
    }

    func testCopyDiagnosticsStateIsUnavailableBeforeAnyInvitationAttempt() throws {
        let store = try HouseholdStore(
            repository: HouseholdRepository(inMemory: true),
            transport: TestTransport(server: TestCloudServer(), account: "owner"),
            automaticSync: false
        )

        XCTAssertNil(store.latestInvitationDiagnostics)
    }
}

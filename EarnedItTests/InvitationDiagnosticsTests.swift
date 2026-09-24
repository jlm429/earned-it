import CloudKit
import CryptoKit
import XCTest
@testable import EarnedIt

@MainActor
final class InvitationDiagnosticsTests: XCTestCase {
    func testProductionInvitationPathEmitsOrderedMajorStagesWithoutChangingIssuedInvitation() async throws {
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
        let trace = try XCTUnwrap(store.latestInvitationDiagnostics)

        XCTAssertEqual(issued.invitation.memberID, child.id)
        XCTAssertEqual(issued.invitation.role, .child)
        XCTAssertTrue(trace.contains("householdID=\(try XCTUnwrap(store.household).id.uuidString)"))
        XCTAssertTrue(trace.contains("currentParentMemberID=\(parent.id.uuidString)"))
        XCTAssertTrue(trace.contains("targetMemberID=\(child.id.uuidString)"))
        XCTAssertTrue(trace.contains("firstFailureStage=none"))

        let orderedStages = [
            "stage=invitationStart",
            "stage=invitationGeneration outcome=started",
            "stage=zoneConnectionBootstrap outcome=started",
            "stage=participantLookup outcome=started",
            "stage=membershipLockAcquire outcome=started",
            "stage=zoneCreate outcome=started",
            "stage=lifecycleAuthorityPrepare outcome=started",
            "stage=initialFactSynchronization outcome=started",
            "stage=journalFetch outcome=started",
            "stage=ownerMembershipValidation outcome=started",
            "stage=membershipLockRead outcome=started",
            "stage=journalUpload outcome=started",
            "stage=preInvitationSynchronization outcome=started",
            "stage=validationTimeWrite outcome=started",
            "stage=shareFetch outcome=started",
            "stage=shareCreate outcome=started",
            "stage=participantCreate outcome=started",
            "stage=invitationAppend outcome=started",
            "stage=invitationFactUpload outcome=started",
            "stage=completed"
        ]
        let positions = try orderedStages.map { marker in
            try XCTUnwrap(trace.range(of: marker)?.lowerBound, "Missing trace marker: \(marker)")
        }
        XCTAssertEqual(positions, positions.sorted())

        for stage in [
            "invitationGeneration", "zoneConnectionBootstrap", "initialFactSynchronization",
            "preInvitationSynchronization", "ownerMembershipValidation", "lifecycleAuthorityPrepare",
            "membershipLockRead", "journalFetch", "journalUpload", "participantCreate",
            "invitationAppend", "invitationFactUpload"
        ] {
            XCTAssertTrue(trace.contains("stage=\(stage) outcome=started"), stage)
            XCTAssertTrue(trace.contains("stage=\(stage) outcome=succeeded"), stage)
        }
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
        XCTAssertTrue(trace.contains("cloudKitUserRecordNameSHA256=\(expectedDigest)"))
        XCTAssertTrue(trace.contains("expected.householdID=\(householdID.uuidString)"))
        XCTAssertTrue(trace.contains("expected.memberProfileID=\(parent.id.uuidString)"))
        XCTAssertTrue(trace.contains("expected.role=parent"))
        XCTAssertTrue(trace.contains("lock.householdID=\(householdID.uuidString)"))
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
        XCTAssertFalse(trace.contains(originalLock.attemptID.uuidString))
        XCTAssertFalse(trace.contains(try XCTUnwrap(originalLock.claimBinding)))
        XCTAssertFalse(trace.contains(wrongAuthority))
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
            currentParentMemberID: parentID,
            targetMemberID: childID,
            targetRole: .child,
            localAttemptID: rawNonce,
            localParticipantID: rawCloudUser,
            accountGeneration: 7,
            hasCloudLocation: true
        )
        diagnostics.recordAccountIdentity(participantID: rawCloudUser, generation: 7, stable: true)
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
            localAttemptID: rawNonce,
            accountGeneration: 7
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
        XCTAssertTrue(trace.contains("householdID=\(householdID.uuidString)"))
        XCTAssertTrue(trace.contains("currentParentMemberID=\(parentID.uuidString)"))
        XCTAssertTrue(trace.contains("targetMemberID=\(childID.uuidString)"))
        XCTAssertTrue(trace.contains("path=topLevel,domain=CKErrorDomain"))
        XCTAssertTrue(trace.contains("path=topLevel.partial[1],domain=CKErrorDomain"))
        XCTAssertTrue(trace.contains("path=topLevel.partial[1].partial[1],domain=CKErrorDomain"))
        XCTAssertTrue(trace.contains("code=\(CKError.Code.partialFailure.rawValue)"))
        XCTAssertTrue(trace.contains("code=\(CKError.Code.serviceUnavailable.rawValue)"))
        XCTAssertTrue(trace.contains("retryAfterSeconds=13.0"))
        XCTAssertTrue(trace.contains("firstFailureStage=participantCreate"))
        XCTAssertFalse(trace.contains(rawCloudUser))
        XCTAssertFalse(trace.contains(rawNonce.uuidString))
        XCTAssertFalse(trace.contains(rawBinding))
        XCTAssertFalse(trace.contains(rawOwnerAuthority))
        XCTAssertFalse(trace.contains(invitationSecret))
        XCTAssertFalse(trace.contains(shareURL))
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

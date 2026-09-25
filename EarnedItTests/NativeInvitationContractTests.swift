import CloudKit
import XCTest
@testable import EarnedIt

@MainActor
final class NativeInvitationContractTests: XCTestCase {
    func testSigningEntitlementsEnableNativeOneTimeLinks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Configuration/EarnedIt.entitlements"))
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let access = try XCTUnwrap(entitlements["com.apple.developer.icloud-extended-share-access"] as? [String])
        XCTAssertEqual(access, ["InProcessOneTimeLinks"])
    }

    func testNativeFactoryAllowsPrivateReadWriteParticipantConfiguration() {
        let participant = CKShare.Participant.oneTimeURLParticipant()
        XCTAssertEqual(participant.role, .privateUser)
        XCTAssertEqual(participant.acceptanceStatus, .pending)
        XCTAssertNil(participant.userIdentity.lookupInfo)
        participant.permission = .readWrite
        participant.role = .privateUser
        XCTAssertEqual(participant.role, .privateUser)
        XCTAssertEqual(participant.permission, .readWrite)
        XCTAssertFalse(participant.participantID.isEmpty)
        // addParticipant requires a signed or simulator-embedded entitlement.
        // docs/production-invitation-crash/run-native-probe.sh exercises that boundary.
    }

    func testDoubleRejectsMissingOneTimeLinkAccessThenIssuesBoundInvitation() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "owner")
        let family = try TestFamily(transport: transport)
        transport.extendedShareAccess = ["InProcessShareOwnerParticipantInfo"]
        do {
            _ = try await family.store.createChildInvitation(memberID: family.hanna.id)
            XCTFail("Expected missing one-time link access to reject invitation creation")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .invitation)
        }
        let location = try XCTUnwrap(family.store.session.location)
        XCTAssertTrue(server.zones[location.zoneName]!.pendingInvitationParticipants.isEmpty)
        XCTAssertTrue(family.store.snapshot.invitations.isEmpty)

        transport.extendedShareAccess.insert("InProcessOneTimeLinks")
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        XCTAssertEqual(invitation.invitation.memberID, family.hanna.id)
        XCTAssertEqual(invitation.invitation.role, .child)
        XCTAssertEqual(invitation.invitation.householdID, location.householdID)
        XCTAssertTrue(server.zones[location.zoneName]!.pendingInvitationParticipants
            .contains(invitation.invitation.cloudShareParticipantID))
    }

    func testCustomPackageRejectsAcceptedParticipantIdentityMismatch() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let child = TestTransport(server: server, account: "child")
        child.acceptedParticipantIDTransforms = true
        let recipient = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: child,
                                           clock: { family.clock.now }, automaticSync: false)
        do {
            _ = try await recipient.redeemInvitation(invitation.qrPayload)
            XCTFail("Expected the mismatched participant to be rejected")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .invitationNotFound)
        }
        XCTAssertNil(recipient.selectedMember)
        XCTAssertNil(server.zones[invitation.shareURL.lastPathComponent]?
            .facts[invitation.invitation.claimFactID])
    }

    func testRawParticipantBindingRequiresExactAcceptedPrivateReadWriteSlot() {
        let participantID = "one-time-participant"
        XCTAssertTrue(CloudKitHouseholdTransport.invitationParticipantMatches(
            participantID: participantID,
            expectedParticipantID: participantID,
            acceptanceStatusMatches: true,
            permission: .readWrite,
            role: .privateUser
        ))
        XCTAssertFalse(CloudKitHouseholdTransport.invitationParticipantMatches(
            participantID: "",
            expectedParticipantID: "",
            acceptanceStatusMatches: true,
            permission: .readWrite,
            role: .privateUser
        ))
        XCTAssertFalse(CloudKitHouseholdTransport.invitationParticipantMatches(
            participantID: "other-participant",
            expectedParticipantID: participantID,
            acceptanceStatusMatches: true,
            permission: .readWrite,
            role: .privateUser
        ))
        XCTAssertFalse(CloudKitHouseholdTransport.invitationParticipantMatches(
            participantID: participantID,
            expectedParticipantID: participantID,
            acceptanceStatusMatches: false,
            permission: .readWrite,
            role: .privateUser
        ))
        XCTAssertFalse(CloudKitHouseholdTransport.invitationParticipantMatches(
            participantID: participantID,
            expectedParticipantID: participantID,
            acceptanceStatusMatches: true,
            permission: .readOnly,
            role: .privateUser
        ))
        XCTAssertFalse(CloudKitHouseholdTransport.invitationParticipantMatches(
            participantID: participantID,
            expectedParticipantID: participantID,
            acceptanceStatusMatches: true,
            permission: .readWrite,
            role: .publicUser
        ))
    }

    func testDeterministicRecordMissingClassifierAcceptsPerRecordUnknownItemOnly() {
        let recordID = CKRecord.ID(recordName: String(repeating: "a", count: 64))
        let otherRecordID = CKRecord.ID(recordName: String(repeating: "b", count: 64))
        let missing = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [recordID: CKError(.unknownItem)]
        ])
        let unavailable = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [recordID: CKError(.networkFailure)]
        ])

        XCTAssertTrue(CloudKitHouseholdTransport.isRecordMissing(CKError(.unknownItem), recordID: recordID))
        XCTAssertTrue(CloudKitHouseholdTransport.isRecordMissing(missing, recordID: recordID))
        XCTAssertFalse(CloudKitHouseholdTransport.isRecordMissing(missing, recordID: otherRecordID))
        XCTAssertFalse(CloudKitHouseholdTransport.isRecordMissing(unavailable, recordID: recordID))
        XCTAssertFalse(CloudKitHouseholdTransport.isRecordMissing(CKError(.permissionFailure), recordID: recordID))
    }

    func testLifecycleBootstrapRetriesObservedProductionUnknownItemAfterCreate() {
        let recordID = CKRecord.ID(
            recordName: "13015974c1c5f2947a398369546723450d8e94f9798cfb8af108934512b5acd3"
        )
        let error = CKError(.unknownItem, userInfo: [
            NSLocalizedDescriptionKey:
                "Error fetching record \(recordID) from server: Record not found"
        ])

        XCTAssertTrue(
            CloudKitHouseholdTransport.shouldRetryLifecycleAuthorityBootstrap(error, recordID: recordID)
        )
    }
}

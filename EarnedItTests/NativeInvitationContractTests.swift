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

    func testAcceptedOneTimeURLClaimsExactInvitationWhenParticipantIdentityTransforms() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let child = TestTransport(server: server, account: "child")
        child.acceptedParticipantIDTransforms = true
        let recipient = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: child,
                                           clock: { family.clock.now }, automaticSync: false)
        try await recipient.redeemInvitation(invitation.qrPayload)
        let location = try XCTUnwrap(recipient.session.location)
        let hasAccess = try await child.hasInvitationAccess(
            participantID: invitation.invitation.cloudShareParticipantID, in: location
        )
        XCTAssertFalse(hasAccess)
        XCTAssertEqual(recipient.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(recipient.snapshot.invitationClaim(invitation.id)?.cloudParticipantID, "child")
        let other = TestTransport(server: server, account: "other")
        do {
            _ = try await other.accept(url: invitation.shareURL)
            XCTFail("Expected a claimed private link to reject an uninvited account")
        } catch {
            XCTAssertEqual(error as? HouseholdError, .invitationConsumed)
        }
        let accounts = try XCTUnwrap(server.zones[location.zoneName]?.claimedInvitationAccounts)
        XCTAssertEqual(accounts[invitation.invitation.cloudShareParticipantID], "child")
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
}

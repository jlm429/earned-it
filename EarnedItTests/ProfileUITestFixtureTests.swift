#if DEBUG
import XCTest
@testable import EarnedIt

@MainActor
final class ProfileUITestFixtureTests: XCTestCase {
    func testReturningToEachExactMemberReusesCommittedMembership() throws {
        let family = try TestFamily()
        var claimIDs: [UUID: UUID] = [:]
        for member in [family.hanna, family.alek, family.parent,
                       family.hanna, family.alek, family.parent] {
            try ProfileUITestFixture.bindRequestedMember(repository: family.repository, arguments: [
                "--ui-test-store", "--ui-test-bound-member=\(member.displayName.accessibilitySlug)"
            ])
            let store = try HouseholdStore(repository: family.repository,
                                           clock: { family.clock.now }, automaticSync: false)
            let participant = try XCTUnwrap(store.session.cloudParticipantID)
            let membership = try XCTUnwrap(store.snapshot.committedAccountMembership(participantID: participant))
            XCTAssertEqual(membership.member.id, member.id)
            XCTAssertEqual(store.selectedMember?.id, member.id)
            XCTAssertEqual(store.profiles.map(\.id), [member.id])
            XCTAssertNotEqual(store.session.deviceID, family.store.session.deviceID)
            if let claimID = claimIDs[member.id] {
                XCTAssertEqual(membership.invitation.claimFactID, claimID)
                XCTAssertEqual(store.snapshot.invitationClaims.count, 3)
            } else {
                claimIDs[member.id] = membership.invitation.claimFactID
            }
        }
    }
}
#endif

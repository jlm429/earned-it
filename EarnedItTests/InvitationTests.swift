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

        let childInvitation = try await joined!.createChildInvitation(memberID: family.hanna.id)
        XCTAssertEqual(childInvitation.invitation.memberID, family.hanna.id)
        XCTAssertEqual(childInvitation.invitation.role, .child)
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

        await XCTAssertThrowsErrorAsync(
            try await joining.redeemInvitation("2345-6789-AB"),
            expected: .invitationNotFound
        )
        XCTAssertNil(joining.household)
        XCTAssertNil(joining.session.pendingInvitationAcceptance)
        XCTAssertTrue(try repository.facts(householdID: invitation.invitation.householdID).isEmpty)
        XCTAssertFalse(server.zones[invitation.shareURL.lastPathComponent]!.participants.contains("metadata-child"))
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

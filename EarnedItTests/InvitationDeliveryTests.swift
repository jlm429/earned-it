import CloudKit
import XCTest
@testable import EarnedIt

@MainActor
final class InvitationDeliveryTests: XCTestCase {
    func testSharedInvitationUsesSamePackageAsGeneratedQR() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let issued = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let sharedPayload = try XCTUnwrap(issued.shareText.split(separator: "\n").last).description
        XCTAssertEqual(sharedPayload, issued.qrPayload)
        let shared = try XCTUnwrap(InvitationCredential(text: sharedPayload))
        XCTAssertEqual(shared.code, issued.code)
        XCTAssertEqual(shared.shareURL, issued.shareURL)
        XCTAssertEqual(issued.invitationURL.absoluteString, issued.qrPayload)
    }

    func testCodeOnlyBeforeAccessFailsButActualGeneratedQRInitiatesAcceptanceAndClaimsExactChild() async throws {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let issued = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "recipient")
        let recipient = try HouseholdStore(repository: HouseholdRepository(inMemory: true), transport: transport,
                                           clock: { family.clock.now }, automaticSync: false)
        do {
            try await recipient.redeemInvitation(issued.code)
            XCTFail("A code alone cannot discover a share before acceptance")
        } catch { XCTAssertEqual(error as? HouseholdError, .invitationNotFound) }
        XCTAssertNil(recipient.selectedMember)
        var acceptanceCalls = 0
        transport.beforeAccept = {
            acceptanceCalls += 1
            XCTAssertNil(recipient.selectedMember)
            XCTAssertTrue(recipient.profiles.isEmpty)
        }
        try await recipient.redeemInvitation(issued.qrPayload)
        XCTAssertEqual(acceptanceCalls, 1)
        XCTAssertEqual(recipient.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(recipient.profiles.map(\.id), [family.hanna.id])
        XCTAssertEqual(transport.acceptedURLs, [issued.shareURL])
    }

    func testPackagePreservesCompleteNestedNativeURLAndExactFormattedCode() throws {
        let nativeURL = try XCTUnwrap(URL(string: "https://www.icloud.com/share/synthetic-only?token=synthetic&value=A%2BB#synthetic-fragment"))
        let invitation = FamilyInvitation(id: UUID(), householdID: UUID(), claimFactID: UUID(), memberID: UUID(),
                                          role: .child, codeDigest: try XCTUnwrap(InvitationCode.digest("2345-6789-AB")),
                                          createdAt: .now, expiresAt: .distantFuture, createdByMemberID: UUID(),
                                          cloudShareParticipantID: "synthetic-slot", cloudShareURLDigest: nil)
        let issued = IssuedFamilyInvitation(invitation: invitation, code: "2345-6789-AB", shareURL: nativeURL)
        let decoded = try XCTUnwrap(InvitationCredential(text: issued.invitationURL.absoluteString))
        XCTAssertEqual(decoded.code, "2345-6789-AB")
        XCTAssertEqual(decoded.shareURL, nativeURL)
    }

    func testVerificationOpensUnderlyingURLThenWarmCallbackClaimsOriginalCodeOnly() async throws {
        let (family, issued, transport, recipient, _) = try await pendingRecipient()
        var opened: [URL] = []
        transport.invitationLocationError = CKError(.participantMayNeedVerification)
        try await recipient.redeemInvitation(issued.qrPayload) { opened.append($0); return true }
        XCTAssertEqual(opened, [issued.shareURL])
        XCTAssertEqual(recipient.session.pendingInvitationPackage?.codeDigest, InvitationCode.digest(issued.code))
        XCTAssertTrue(recipient.session.pendingInvitationPackage?.needsAppleVerification == true)
        XCTAssertNil(recipient.selectedMember)
        XCTAssertTrue(recipient.profiles.isEmpty)
        XCTAssertTrue(transport.acceptedURLs.isEmpty)

        transport.invitationLocationError = nil
        let location = try await transport.invitationLocation(for: issued.shareURL)
        try await recipient.acceptSystemInvitation(location: location) {
            XCTAssertNil(recipient.selectedMember)
            try await transport.accept(url: issued.shareURL, expected: location)
            XCTAssertNil(recipient.selectedMember)
        }
        XCTAssertEqual(recipient.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(recipient.profiles.map(\.id), [family.hanna.id])
        XCTAssertNil(recipient.session.pendingInvitationPackage)
        XCTAssertEqual(recipient.snapshot.invitationClaim(issued.invitation.id)?.codeDigest, InvitationCode.digest(issued.code))
        XCTAssertThrowsError(try recipient.selectProfile(family.alek.id))
        XCTAssertThrowsError(try recipient.selectProfile(family.parent.id))
    }

    func testCancelledNativeUIHasVisiblePendingStateAndColdRetryPreservesCodeWithoutOpeningOnLaunch() async throws {
        let (family, issued, transport, original, repository) = try await pendingRecipient()
        transport.invitationLocationError = CKError(.participantMayNeedVerification)
        try await original.redeemInvitation(issued.qrPayload) { _ in true }
        // Apple cancellation can return without metadata. Persisted delivery remains retryable.
        let restarted = try HouseholdStore(repository: repository, transport: transport,
                                           clock: { family.clock.now }, automaticSync: false)
        XCTAssertTrue(restarted.hasPendingInvitationPackage)
        var opens = 0
        let completed = try await restarted.continuePendingInvitation(openShareURL: { _ in opens += 1; return true })
        XCTAssertFalse(completed)
        XCTAssertEqual(opens, 0)
        XCTAssertNil(restarted.selectedMember)
        try await restarted.continuePendingInvitation(allowAppleVerification: true, openShareURL: { url in
            XCTAssertEqual(url, issued.shareURL)
            opens += 1
            return true
        })
        XCTAssertEqual(opens, 1)
        transport.invitationLocationError = nil
        let location = try await transport.invitationLocation(for: issued.shareURL)
        try await restarted.acceptSystemInvitation(location: location) {
            try await transport.accept(url: issued.shareURL, expected: location)
        }
        XCTAssertEqual(restarted.selectedMember?.id, family.hanna.id)
        XCTAssertNil(restarted.session.pendingInvitationPackage)
        let local = String(decoding: try JSONEncoder().encode(try repository.session()), as: UTF8.self)
        XCTAssertFalse(local.contains(issued.code))
    }

    func testFailedNativeOpenKeepsSamePackageForRetry() async throws {
        let (_, issued, transport, recipient, _) = try await pendingRecipient()
        transport.invitationLocationError = CKError(.participantMayNeedVerification)
        do {
            try await recipient.redeemInvitation(issued.qrPayload) { _ in false }
            XCTFail("A refused system open must report failure")
        } catch { XCTAssertEqual(error as? HouseholdError, .invitation) }
        XCTAssertTrue(recipient.hasPendingInvitationPackage)
        XCTAssertNil(recipient.selectedMember)
        transport.invitationLocationError = nil
        let completed = try await recipient.continuePendingInvitation()
        XCTAssertTrue(completed)
        XCTAssertNil(recipient.session.pendingInvitationPackage)
    }

    func testMismatchedNativeCallbackNeverAcceptsOtherHouseholdOrReplacesPendingCode() async throws {
        let (family, issued, transport, recipient, _) = try await pendingRecipient()
        transport.invitationLocationError = CKError(.participantMayNeedVerification)
        try await recipient.redeemInvitation(issued.qrPayload) { _ in true }
        transport.invitationLocationError = nil
        let other = try TestFamily(transport: TestTransport(server: transport.server, account: "other-owner"))
        let otherInvitation = try await other.store.createChildInvitation(memberID: other.hanna.id)
        let otherLocation = try await transport.invitationLocation(for: otherInvitation.shareURL)
        var acceptanceCalls = 0
        do {
            try await recipient.acceptSystemInvitation(location: otherLocation) { acceptanceCalls += 1 }
            XCTFail("A callback from another household must be refused")
        } catch { XCTAssertEqual(error as? HouseholdError, .invitationNotFound) }
        XCTAssertEqual(acceptanceCalls, 0)
        XCTAssertEqual(recipient.session.pendingInvitationPackage?.codeDigest, InvitationCode.digest(issued.code))
        XCTAssertNil(recipient.selectedMember)
        let completed = try await recipient.continuePendingInvitation()
        XCTAssertTrue(completed)
        XCTAssertEqual(recipient.selectedMember?.id, family.hanna.id)
    }

    func testPendingPackageRefusesChangedAccountAndDifferentCodeThenRetriesOriginalAccount() async throws {
        let (family, issued, transport, recipient, _) = try await pendingRecipient()
        transport.invitationLocationError = CKError(.participantMayNeedVerification)
        try await recipient.redeemInvitation(issued.qrPayload) { _ in true }
        transport.account = "different-account"
        do {
            try await recipient.continuePendingInvitation()
            XCTFail("Delivery is bound to the original iCloud account")
        } catch { XCTAssertEqual(error as? HouseholdError, .wrongAccount) }
        XCTAssertTrue(transport.acceptedURLs.isEmpty)
        transport.account = "recipient"
        let otherCode = issued.code == "2345-6789-AB" ? "2345-6789-AC" : "2345-6789-AB"
        do {
            try await recipient.redeemInvitation(otherCode)
            XCTFail("Another code cannot replace a pending claim")
        } catch { XCTAssertEqual(error as? HouseholdError, .invitationNotFound) }
        transport.invitationLocationError = nil
        try await recipient.redeemInvitation(issued.code)
        XCTAssertEqual(recipient.selectedMember?.id, family.hanna.id)
    }

    func testAcceptedShareVisibilityLagRetainsLeaseAndExactCodeForColdRetry() async throws {
        let (family, issued, transport, recipient, repository) = try await pendingRecipient()
        transport.fetchError = CKError(.zoneNotFound)
        do {
            try await recipient.redeemInvitation(issued.qrPayload)
            XCTFail("Shared facts are not visible yet")
        } catch { XCTAssertEqual(error as? HouseholdError, .familyStillSyncing) }
        let attempt = try XCTUnwrap(recipient.session.pendingInvitationAcceptance?.accountLockAttemptID)
        XCTAssertTrue(recipient.hasPendingInvitationPackage)
        XCTAssertEqual(transport.leaveAttempts, 0)
        XCTAssertNil(recipient.selectedMember)
        let restarted = try HouseholdStore(repository: repository, transport: transport,
                                           clock: { family.clock.now }, automaticSync: false)
        transport.fetchError = nil
        let completed = try await restarted.continuePendingInvitation()
        XCTAssertTrue(completed)
        XCTAssertEqual(restarted.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(transport.acceptedURLs, [issued.shareURL])
        XCTAssertEqual(transport.server.accountMembershipLocks["recipient"]?.attemptID, attempt)
        XCTAssertEqual(transport.server.accountMembershipLocks["recipient"]?.state, .active)
    }

    func testAcceptanceCancellationAndNetworkFailureRemainRetryableWithoutScheduledCleanupRace() async throws {
        for interruption in [CancellationError() as any Error, CKError(.networkFailure)] {
            let (family, issued, transport, recipient, _) = try await pendingRecipient()
            transport.acceptErrorAfterHook = interruption
            transport.beforeAccept = {
                let delay = try? await recipient.retryScheduledInvitationCleanup()
                XCTAssertNotNil(delay)
                XCTAssertNotNil(recipient.session.pendingInvitationAcceptance)
                XCTAssertNil(recipient.selectedMember)
            }
            do {
                try await recipient.redeemInvitation(issued.qrPayload)
                XCTFail("Acceptance must be interrupted")
            } catch {
                XCTAssertTrue(error is CancellationError || (error as? CKError)?.code == .networkFailure)
            }
            let attempt = try XCTUnwrap(recipient.session.pendingInvitationAcceptance?.accountLockAttemptID)
            XCTAssertTrue(recipient.hasPendingInvitationPackage)
            XCTAssertEqual(transport.leaveAttempts, 0)
            transport.acceptErrorAfterHook = nil
            let completed = try await recipient.continuePendingInvitation()
            XCTAssertTrue(completed)
            XCTAssertEqual(recipient.selectedMember?.id, family.hanna.id)
            XCTAssertEqual(transport.server.accountMembershipLocks["recipient"]?.attemptID, attempt)
        }
    }

    func testExactBoundPackageSurvivesStaleParticipantSlotVisibility() async throws {
        let (family, issued, transport, recipient, _) = try await pendingRecipient()
        transport.invitationAccessVisible = false
        try await recipient.redeemInvitation(issued.qrPayload)
        XCTAssertEqual(recipient.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(recipient.profiles.map(\.id), [family.hanna.id])
        XCTAssertFalse(recipient.hasPendingInvitationPackage)
        XCTAssertEqual(transport.leaveAttempts, 0)
        XCTAssertEqual(transport.acceptedURLs, [issued.shareURL])
    }

    func testCancellationAfterNativeAcceptanceRetriesWithoutReplacingLeaseOrCode() async throws {
        let (family, issued, transport, recipient, _) = try await pendingRecipient()
        var joining: Task<Void, Error>?
        transport.beforeAccept = { joining?.cancel() }
        joining = Task { try await recipient.redeemInvitation(issued.qrPayload) }
        do {
            try await joining?.value
            XCTFail("The cancelled continuation must stop before claiming")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(transport.server.zones[issued.shareURL.lastPathComponent]!.participants.contains("recipient"))
        XCTAssertNil(recipient.selectedMember)
        XCTAssertTrue(recipient.hasPendingInvitationPackage)
        let attempt = try XCTUnwrap(recipient.session.pendingInvitationAcceptance?.accountLockAttemptID)
        transport.beforeAccept = nil
        try await recipient.continuePendingInvitation()
        XCTAssertEqual(recipient.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(transport.server.accountMembershipLocks["recipient"]?.attemptID, attempt)
        XCTAssertEqual(transport.leaveAttempts, 0)
    }

    func testPendingExactCodeSurvivesDiskRepositoryReopenAndSharedURLRedemptionForBothRoles() async throws {
        for role in [UserRole.child, .parent] {
            let server = TestCloudServer()
            let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
            let issued = role == .child
                ? try await family.store.createChildInvitation(memberID: family.hanna.id)
                : try await family.store.createParentInvitation(name: "Invited Parent", avatar: .fox)
            let transport = TestTransport(server: server, account: "recipient")
            let directory = URL.temporaryDirectory.appending(path: "invitation-delivery-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "synthetic-test.store")
            do {
                let repository = try HouseholdRepository(url: url)
                let original = try HouseholdStore(repository: repository, transport: transport,
                                                   clock: { family.clock.now }, automaticSync: false)
                transport.invitationLocationError = CKError(.participantMayNeedVerification)
                try await original.redeemInvitation(issued.invitationURL.absoluteString) { _ in true }
                let local = String(decoding: try JSONEncoder().encode(try repository.session()), as: UTF8.self)
                XCTAssertFalse(local.contains(issued.code))
                XCTAssertTrue(original.hasPendingInvitationPackage)
            }
            let reopened = try HouseholdStore(repository: HouseholdRepository(url: url), transport: transport,
                                               clock: { family.clock.now }, automaticSync: false)
            XCTAssertFalse(reopened.isCheckingAccountMembership)
            XCTAssertEqual(reopened.session.pendingInvitationPackage?.codeDigest, InvitationCode.digest(issued.code))
            transport.invitationLocationError = nil
            try await reopened.continuePendingInvitation()
            XCTAssertEqual(reopened.selectedMember?.id, issued.invitation.memberID)
            XCTAssertEqual(reopened.selectedMember?.role, role)
            XCTAssertEqual(reopened.profiles.map(\.id), [issued.invitation.memberID])
            XCTAssertNil(reopened.session.pendingInvitationPackage)
        }
    }

    func testExpiredNativeContinuationRefusesClaimAndAllowsFreshParentIssuedInvitation() async throws {
        let (family, issued, transport, recipient, _) = try await pendingRecipient()
        transport.invitationLocationError = CKError(.participantMayNeedVerification)
        try await recipient.redeemInvitation(issued.qrPayload) { _ in true }
        transport.invitationLocationError = nil
        family.clock.now = issued.invitation.expiresAt.addingTimeInterval(1)
        let location = try await transport.invitationLocation(for: issued.shareURL)
        do {
            try await recipient.acceptSystemInvitation(location: location) {
                try await transport.accept(url: issued.shareURL, expected: location)
            }
            XCTFail("Native acceptance cannot override code expiry")
        } catch { XCTAssertEqual(error as? HouseholdError, .invitationExpired) }
        XCTAssertNil(recipient.selectedMember)
        XCTAssertNil(recipient.session.pendingInvitationPackage)
        XCTAssertNil(recipient.snapshot.invitationClaim(issued.invitation.id))
        let replacement = try await family.store.createChildInvitation(memberID: family.hanna.id)
        try await recipient.redeemInvitation(replacement.invitationURL.absoluteString)
        XCTAssertEqual(recipient.selectedMember?.id, family.hanna.id)
        XCTAssertNil(recipient.session.pendingInvitationPackage)
    }

    func testVisibilityFailureBetweenIdentificationAndClaimRetainsPackageAndAccessForRetry() async throws {
        let (family, issued, transport, recipient, _) = try await pendingRecipient()
        var fetches = 0
        transport.beforeFetch = {
            fetches += 1
            if fetches == 2 { transport.fetchError = CKError(.zoneNotFound) }
        }
        do {
            try await recipient.redeemInvitation(issued.qrPayload)
            XCTFail("The claim cannot run without visible shared facts")
        } catch { XCTAssertEqual(error as? HouseholdError, .familyStillSyncing) }
        XCTAssertTrue(recipient.hasPendingInvitationPackage)
        XCTAssertEqual(recipient.session.pendingInvitationAcceptance?.phase, .awaitingRedemption)
        XCTAssertNil(recipient.selectedMember)
        XCTAssertEqual(transport.leaveAttempts, 0)
        transport.beforeFetch = nil
        transport.fetchError = nil
        try await recipient.continuePendingInvitation()
        XCTAssertEqual(recipient.selectedMember?.id, family.hanna.id)
        XCTAssertEqual(transport.acceptedURLs, [issued.shareURL])
    }

    func testDefinitiveNativeContinuationClaimRefusalClearsDeliveryAndNeverGrantsProfile() async throws {
        let (_, issued, transport, recipient, repository) = try await pendingRecipient()
        transport.invitationLocationError = CKError(.participantMayNeedVerification)
        try await recipient.redeemInvitation(issued.qrPayload) { _ in true }
        transport.invitationLocationError = nil
        transport.claimError = CKError(.permissionFailure)
        let location = try await transport.invitationLocation(for: issued.shareURL)
        do {
            try await recipient.acceptSystemInvitation(location: location) {
                try await transport.accept(url: issued.shareURL, expected: location)
            }
            XCTFail("A refused atomic claim cannot become a retryable visibility result")
        } catch { XCTAssertEqual((error as? CKError)?.code, .permissionFailure) }
        XCTAssertNil(recipient.selectedMember)
        XCTAssertNil(recipient.session.pendingInvitationPackage)
        XCTAssertNil(recipient.session.pendingInvitationAcceptance)
        XCTAssertEqual(transport.leaveAttempts, 1)
        XCTAssertEqual(recipient.lastJoinReceipt, LastJoinReceipt(
            nativeAcceptance: .yes,
            sharedZoneVisible: .yes,
            claim: .absent,
            lock: .released,
            exactMembership: .no,
            localAttach: .no,
            rootRoute: .unknown,
            failureStage: .claim,
            failureCategory: .cloudKitPermission
        ))
        let restarted = try HouseholdStore(repository: repository, transport: transport,
                                           automaticSync: false)
        XCTAssertEqual(restarted.lastJoinReceipt, recipient.lastJoinReceipt)
    }

    private func pendingRecipient() async throws
        -> (TestFamily, IssuedFamilyInvitation, TestTransport, HouseholdStore, HouseholdRepository) {
        let server = TestCloudServer()
        let family = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let issued = try await family.store.createChildInvitation(memberID: family.hanna.id)
        let transport = TestTransport(server: server, account: "recipient")
        let repository = try HouseholdRepository(inMemory: true)
        let recipient = try HouseholdStore(repository: repository, transport: transport,
                                           clock: { family.clock.now }, automaticSync: false)
        return (family, issued, transport, recipient, repository)
    }
}

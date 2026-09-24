import XCTest
import CloudKit
@testable import EarnedIt

private extension XCTestCase {
    @MainActor
    func XCTAssertThrowsErrorAsync(
        _ expression: @autoclosure () async throws -> Any,
        expected: HouseholdError? = nil,
        expectedCloudKitCode: CKError.Code? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected an error", file: file, line: line)
        } catch {
            if let expected {
                XCTAssertEqual(error as? HouseholdError, expected, file: file, line: line)
            }
            if let expectedCloudKitCode {
                XCTAssertEqual((error as? CKError)?.code, expectedCloudKitCode, file: file, line: line)
            }
        }
    }
}

final class TestAccountLocalDataResetter: AccountLocalDataResetting {
    private(set) var clearCount = 0
    var error: Error?

    func clearNonJournalData() throws {
        clearCount += 1
        if let error { throw error }
    }
}

@MainActor
final class AccountDataResetTests: XCTestCase {
    func testOwnerResetDeletesEveryEarnedItZoneAccountRecordAndLocalFact() async throws {
        let server = TestCloudServer()
        let resetter = TestAccountLocalDataResetter()
        let transport = TestTransport(server: server, account: "owner")
        let repository = try HouseholdRepository(inMemory: true)
        let store = try HouseholdStore(
            repository: repository,
            transport: transport,
            automaticSync: false,
            localDataResetter: resetter
        )
        try store.createFamily(name: "Reset Family", parentName: "Owner")
        let householdID = try XCTUnwrap(store.household?.id)
        _ = try store.saveMember(name: "Child", role: .child, avatar: .star)
        try store.finishSetup()
        try await store.connect()

        let staleIDs = [UUID(), UUID()]
        for id in staleIDs {
            server.zones["EarnedIt-\(id.uuidString)"] = TestCloudServer.Zone(
                householdID: id,
                name: "Stale",
                owner: "owner"
            )
            server.lifecycleAuthorities[id] = .init(state: .deleted, creator: "owner", lastModifier: "owner")
        }
        let unrelatedID = UUID()
        server.zones["Other-\(unrelatedID.uuidString)"] = TestCloudServer.Zone(
            householdID: unrelatedID,
            name: "Unrelated",
            owner: "owner"
        )
        server.zones["EarnedIt-not-a-uuid"] = TestCloudServer.Zone(
            householdID: UUID(),
            name: "Ambiguous",
            owner: "owner"
        )
        server.privateAccountResetRecords["owner"] = [
            .privateRecord(recordType: "AccountMembershipValidationTime", recordName: "validation-1"),
            .privateRecord(recordType: "InvitationValidationTime", recordName: "validation-2")
        ]

        try await store.deleteAllEarnedItData()

        XCTAssertNil(store.household)
        XCTAssertNil(store.session.householdID)
        XCTAssertNil(store.session.accountDataResetProgress)
        XCTAssertTrue(try repository.facts(householdID: householdID).isEmpty)
        XCTAssertNil(server.accountMembershipLocks["owner"])
        XCTAssertTrue(server.lifecycleAuthorities.values.allSatisfy { $0.creator != "owner" })
        XCTAssertTrue(server.privateAccountResetRecords["owner", default: []].isEmpty)
        XCTAssertNil(server.zones["EarnedIt-\(householdID.uuidString)"])
        XCTAssertNil(server.zones["EarnedIt-\(staleIDs[0].uuidString)"])
        XCTAssertNil(server.zones["EarnedIt-\(staleIDs[1].uuidString)"])
        XCTAssertNotNil(server.zones["Other-\(unrelatedID.uuidString)"])
        XCTAssertNotNil(server.zones["EarnedIt-not-a-uuid"])
        XCTAssertEqual(resetter.clearCount, 1)
    }

    func testParticipantResetDeletesOnlyParticipantPrivateStateAndRelinquishesShare() async throws {
        let server = TestCloudServer()
        let owner = try TestFamily(transport: TestTransport(server: server, account: "owner"))
        let invitation = try await owner.store.createChildInvitation(memberID: owner.hanna.id)
        let childResetter = TestAccountLocalDataResetter()
        let childRepository = try HouseholdRepository(inMemory: true)
        let childTransport = TestTransport(server: server, account: "child")
        let child = try HouseholdStore(
            repository: childRepository,
            transport: childTransport,
            clock: { owner.clock.now },
            automaticSync: false,
            localDataResetter: childResetter
        )
        try await child.redeemInvitation(invitation.qrPayload)
        let zoneName = try XCTUnwrap(child.session.location?.zoneName)
        let ownerLock = server.accountMembershipLocks["owner"]

        try await child.deleteAllEarnedItData()

        XCTAssertNil(child.household)
        XCTAssertNil(server.accountMembershipLocks["child"])
        XCTAssertEqual(server.accountMembershipLocks["owner"], ownerLock)
        XCTAssertNotNil(server.zones[zoneName])
        XCTAssertFalse(try XCTUnwrap(server.zones[zoneName]).participants.contains("child"))
        XCTAssertNotNil(server.lifecycleAuthorities[owner.store.household!.id])
        XCTAssertEqual(childResetter.clearCount, 1)
    }

    func testResetDeletesProvisionalActiveAndReleasedMembershipForms() async throws {
        for state in [AccountMembershipLockState.provisional, .active, .released] {
            let server = TestCloudServer()
            let transport = TestTransport(server: server, account: "account")
            let repository = try HouseholdRepository(inMemory: true)
            let store = try HouseholdStore(repository: repository, transport: transport, automaticSync: false)
            server.accountMembershipLocks["account"] = AccountMembershipLock(
                householdID: UUID(),
                attemptID: UUID(),
                state: state,
                expiresAt: state == .active ? .distantFuture : .now,
                claimBinding: state == .provisional ? nil : "historical-binding"
            )

            try await store.deleteAllEarnedItData()

            XCTAssertNil(server.accountMembershipLocks["account"], "State \(state) must be deleted")
            XCTAssertNil(store.session.accountDataResetProgress)
            XCTAssertNil(store.household)
        }
    }

    func testInterruptionPersistsProgressAndOnlineRetryFinishesWithoutEarlyLocalCleanup() async throws {
        let server = TestCloudServer()
        let resetter = TestAccountLocalDataResetter()
        let transport = TestTransport(server: server, account: "owner")
        let repository = try HouseholdRepository(inMemory: true)
        let store = try HouseholdStore(
            repository: repository,
            transport: transport,
            automaticSync: false,
            localDataResetter: resetter
        )
        try store.createFamily(name: "Interrupted", parentName: "Owner")
        _ = try store.saveMember(name: "Child", role: .child, avatar: .star)
        try store.finishSetup()
        try await store.connect()
        transport.accountResetDeletionFailures = 1

        await XCTAssertThrowsErrorAsync(
            try await store.deleteAllEarnedItData(),
            expectedCloudKitCode: .networkFailure
        )

        XCTAssertNotNil(store.household)
        XCTAssertNotNil(store.session.accountDataResetProgress)
        XCTAssertEqual(resetter.clearCount, 0)

        let relaunched = try HouseholdStore(
            repository: repository,
            transport: transport,
            automaticSync: false,
            localDataResetter: resetter
        )
        XCTAssertTrue(relaunched.hasPendingAccountDataReset)
        try await relaunched.deleteAllEarnedItData()

        XCTAssertNil(relaunched.household)
        XCTAssertFalse(relaunched.hasPendingAccountDataReset)
        XCTAssertEqual(resetter.clearCount, 1)
        XCTAssertTrue(server.zones.values.allSatisfy { $0.owner != "owner" })
    }

    func testOfflineDiscoveryFailureRetriesAndMissingTargetsAreIdempotent() async throws {
        let server = TestCloudServer()
        let resetter = TestAccountLocalDataResetter()
        let transport = TestTransport(server: server, account: "account")
        let repository = try HouseholdRepository(inMemory: true)
        let store = try HouseholdStore(
            repository: repository,
            transport: transport,
            automaticSync: false,
            localDataResetter: resetter
        )
        let missingHouseholdID = UUID()
        let missingZoneName = "EarnedIt-\(missingHouseholdID.uuidString)"
        server.zones[missingZoneName] = TestCloudServer.Zone(
            householdID: missingHouseholdID,
            name: "Already Removed",
            owner: "account"
        )
        server.accountMembershipLocks["account"] = AccountMembershipLock(
            householdID: missingHouseholdID,
            attemptID: UUID(),
            state: .released,
            expiresAt: .now,
            claimBinding: "missing"
        )
        transport.accountResetDiscoveryError = CKError(.networkUnavailable)

        await XCTAssertThrowsErrorAsync(
            try await store.deleteAllEarnedItData(),
            expectedCloudKitCode: .networkUnavailable
        )
        XCTAssertTrue(store.hasPendingAccountDataReset)
        XCTAssertEqual(resetter.clearCount, 0)

        transport.accountResetDiscoveryError = nil
        transport.beforeAccountResetDeletion = {
            transport.beforeAccountResetDeletion = nil
            server.zones.removeValue(forKey: missingZoneName)
            server.accountMembershipLocks.removeValue(forKey: "account")
        }
        try await store.deleteAllEarnedItData()
        try await store.deleteAllEarnedItData()

        XCTAssertFalse(store.hasPendingAccountDataReset)
        XCTAssertEqual(resetter.clearCount, 2)
        XCTAssertNil(store.household)
        XCTAssertNil(server.zones[missingZoneName])
        XCTAssertNil(server.accountMembershipLocks["account"])
    }

    func testRepeatedCloudTargetNeverReportsSuccessAndKeepsProgressForRetry() async throws {
        let server = TestCloudServer()
        let resetter = TestAccountLocalDataResetter()
        let transport = TestTransport(server: server, account: "account")
        let repository = try HouseholdRepository(inMemory: true)
        let store = try HouseholdStore(
            repository: repository,
            transport: transport,
            automaticSync: false,
            localDataResetter: resetter
        )
        let lock = AccountMembershipLock(
            householdID: UUID(),
            attemptID: UUID(),
            state: .released,
            expiresAt: .now,
            claimBinding: "reappearing"
        )
        server.accountMembershipLocks["account"] = lock
        transport.afterAccountResetDeletion = {
            server.accountMembershipLocks["account"] = lock
        }

        await XCTAssertThrowsErrorAsync(
            try await store.deleteAllEarnedItData(),
            expected: .cloudUnavailable
        )

        XCTAssertTrue(store.hasPendingAccountDataReset)
        XCTAssertNotNil(server.accountMembershipLocks["account"])
        XCTAssertEqual(resetter.clearCount, 0)
    }

    func testAccountIdentityOrGenerationChangeFailsClosedAndKeepsReceipt() async throws {
        for changeIdentity in [false, true] {
            let server = TestCloudServer()
            let transport = TestTransport(server: server, account: "owner")
            let repository = try HouseholdRepository(inMemory: true)
            let store = try HouseholdStore(repository: repository, transport: transport, automaticSync: false)
            server.accountMembershipLocks["owner"] = AccountMembershipLock(
                householdID: UUID(),
                attemptID: UUID(),
                state: .released,
                expiresAt: .now,
                claimBinding: "released"
            )
            transport.beforeAccountResetDeletion = {
                transport.beforeAccountResetDeletion = nil
                if changeIdentity { transport.account = "other" } else { transport.accountDidChange() }
            }

            await XCTAssertThrowsErrorAsync(
                try await store.deleteAllEarnedItData(),
                expected: .wrongAccount
            )

            XCTAssertTrue(store.hasPendingAccountDataReset)
            XCTAssertNotNil(server.accountMembershipLocks["owner"])
            XCTAssertNil(server.accountMembershipLocks["other"])
        }
    }

    func testOrphanedOfflineChildCanResetRelaunchAndJoinFreshFamilyWithoutResurrection() async throws {
        let server = TestCloudServer()
        let parentResetter = TestAccountLocalDataResetter()
        let parentTransport = TestTransport(server: server, account: "old-owner")
        let parentRepository = try HouseholdRepository(inMemory: true)
        let parent = try HouseholdStore(
            repository: parentRepository,
            transport: parentTransport,
            automaticSync: false,
            localDataResetter: parentResetter
        )
        try parent.createFamily(name: "Old Family", parentName: "Parent")
        let childMember = try parent.saveMember(name: "Child", role: .child, avatar: .star)
        try parent.finishSetup()
        try await parent.connect()
        let oldInvitation = try await parent.createChildInvitation(memberID: childMember.id)

        let childResetter = TestAccountLocalDataResetter()
        let childRepository = try HouseholdRepository(inMemory: true)
        let childTransport = TestTransport(server: server, account: "child")
        var child = try HouseholdStore(
            repository: childRepository,
            transport: childTransport,
            automaticSync: false,
            localDataResetter: childResetter
        )
        try await child.redeemInvitation(oldInvitation.qrPayload)
        let oldHouseholdID = try XCTUnwrap(child.household?.id)

        try await parent.deleteAllEarnedItData()
        XCTAssertNil(server.accountMembershipLocks["old-owner"])
        XCTAssertNotNil(server.accountMembershipLocks["child"])

        await XCTAssertThrowsErrorAsync(try await child.synchronize())
        XCTAssertTrue(child.familyAccessLost)
        XCTAssertNil(server.zones.values.first { $0.householdID == oldHouseholdID })
        XCTAssertNil(server.accountMembershipLocks["old-owner"])

        try await child.deleteAllEarnedItData()
        XCTAssertNil(server.accountMembershipLocks["child"])
        XCTAssertNil(child.household)

        child = try HouseholdStore(
            repository: childRepository,
            transport: childTransport,
            automaticSync: false,
            localDataResetter: childResetter
        )
        try await child.reconcileAccountMembershipLock()
        XCTAssertNil(child.household)
        XCTAssertFalse(child.requiresMembershipRecovery)

        let freshParent = try TestFamily(transport: TestTransport(server: server, account: "new-owner"))
        freshParent.clock.now = .now
        let freshInvitation = try await freshParent.store.createChildInvitation(memberID: freshParent.hanna.id)
        try await child.redeemInvitation(freshInvitation.qrPayload)

        XCTAssertEqual(child.household?.id, freshParent.store.household?.id)
        XCTAssertEqual(child.selectedMember?.id, freshParent.hanna.id)
        XCTAssertEqual(server.zones.count, 1)
        XCTAssertNil(server.zones.values.first { $0.householdID == oldHouseholdID })
    }

    func testRecoveryStateInvokesSameResetCoordinatorAndFreshInstallStaysAtWelcome() async throws {
        let server = TestCloudServer()
        let transport = TestTransport(server: server, account: "child")
        let missingHouseholdID = UUID()
        server.accountMembershipLocks["child"] = AccountMembershipLock(
            householdID: missingHouseholdID,
            attemptID: UUID(),
            state: .active,
            expiresAt: .distantFuture,
            claimBinding: "stale-invitation"
        )
        let repository = try HouseholdRepository(inMemory: true)
        var store = try HouseholdStore(repository: repository, transport: transport, automaticSync: false)
        await XCTAssertThrowsErrorAsync(try await store.reconcileAccountMembershipLock())
        XCTAssertTrue(store.requiresMembershipRecovery)

        try await store.deleteAllEarnedItData()
        XCTAssertNil(server.accountMembershipLocks["child"])
        XCTAssertNil(store.household)

        let freshRepository = try HouseholdRepository(inMemory: true)
        store = try HouseholdStore(repository: freshRepository, transport: transport, automaticSync: false)
        try await store.reconcileAccountMembershipLock()
        XCTAssertNil(store.household)
        XCTAssertFalse(store.requiresMembershipRecovery)

        store = try HouseholdStore(repository: freshRepository, transport: transport, automaticSync: false)
        try await store.reconcileAccountMembershipLock()
        XCTAssertNil(store.household)
        XCTAssertFalse(store.requiresMembershipRecovery)
    }

    func testAppLocalResetterRemovesHistoricalStoresCachesAndUserDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "account-reset-\(UUID())")
        let support = root.appending(path: "Library/Application Support")
        let documents = root.appending(path: "Documents")
        let caches = root.appending(path: "Library/Caches")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let artifacts = [
            support.appending(path: "default.store"),
            URL(fileURLWithPath: support.appending(path: "default.store").path + "-wal"),
            documents.appending(path: "isolated-ui-tests.store"),
            caches.appending(path: "cached-profile")
        ]
        for artifact in artifacts {
            try Data("artifact".utf8).write(to: artifact)
        }
        let suiteName = "AccountDataResetTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set("receipt", forKey: "recovery-receipt")
        let resetter = AppAccountLocalDataResetter(
            applicationSupportDirectory: support,
            documentsDirectory: documents,
            cachesDirectory: caches,
            bundleIdentifier: suiteName,
            userDefaults: defaults
        )

        try resetter.clearNonJournalData()

        XCTAssertTrue(artifacts.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertNil(defaults.object(forKey: "recovery-receipt"))
    }
}

import CloudKit
import XCTest
@testable import EarnedIt

@MainActor
final class FocusedFamilyDeletionRecoveryTests: XCTestCase {
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

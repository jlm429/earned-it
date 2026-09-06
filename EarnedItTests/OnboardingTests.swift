import XCTest
@testable import EarnedIt

@MainActor
final class OnboardingTests: XCTestCase {
    func testFreshSetupPersistsAcrossReopeningWithoutSeeding() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "household-test-\(UUID())")
        let url = directory.appending(path: "family.store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        var store: HouseholdStore? = try HouseholdStore(repository: HouseholdRepository(url: url), clock: { clock.now }, automaticSync: false)
        XCTAssertNil(store?.household)
        XCTAssertTrue(store!.snapshot.members.isEmpty)
        try store!.createFamily(name: "Test Family", parentName: "Test Parent")
        XCTAssertThrowsError(try store!.finishSetup())
        let originalID = store!.household!.id
        store = nil
        store = try HouseholdStore(repository: HouseholdRepository(url: url), clock: { clock.now }, automaticSync: false)
        XCTAssertEqual(store!.household!.id, originalID)
        XCTAssertEqual(store!.snapshot.members.count, 1)
        XCTAssertFalse(store!.household!.isSetupComplete)
        try store!.saveMember(name: "Test Child", role: .child, avatar: .star)
        try store!.finishSetup()
        store = nil
        store = try HouseholdStore(repository: HouseholdRepository(url: url), clock: { clock.now }, automaticSync: false)
        XCTAssertTrue(store!.household!.isSetupComplete)
        XCTAssertEqual(store!.snapshot.members.count, 2)
        XCTAssertEqual(store!.selectedMember?.role, .parent)
    }

    func testNamesValidatedAndStableMemberIdentityOnRetry() throws {
        let family = try TestFamily()
        XCTAssertThrowsError(try family.store.saveMember(name: " ", role: .child, avatar: .cat))
        XCTAssertThrowsError(try family.store.saveMember(name: " hanna ", role: .child, avatar: .cat))
        try family.store.saveMember(id: family.hanna.id, name: "Hanna Updated", role: .child, avatar: .cat)
        try family.store.saveMember(id: family.hanna.id, name: "Hanna Updated", role: .child, avatar: .cat)
        XCTAssertEqual(family.store.snapshot.members.count, 3)
        XCTAssertEqual(family.store.snapshot.member(family.hanna.id)?.avatar, .cat)
    }

    func testConfirmedLocalResetDoesNotTouchOtherStoreFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "reset-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appending(path: "default.store")
        let sentinel = Data("Unrelated old store must remain untouched".utf8)
        try sentinel.write(to: legacy)
        let family = try TestFamily(url: directory.appending(path: "shared-household.store"))
        try family.store.resetLocalData()
        XCTAssertNil(family.store.household)
        XCTAssertTrue(family.store.snapshot.members.isEmpty)
        XCTAssertEqual(try Data(contentsOf: legacy), sentinel)
        let reopened = try HouseholdStore(repository: family.repository, automaticSync: false)
        XCTAssertNil(reopened.household)
    }

    func testSharingAcceptanceCapabilityIsPackagedInTheApp() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CKSharingSupported") as? Bool, true)
    }

    func testInvalidCivilDatesAreRejected() throws {
        XCTAssertNil(CivilDay(rawValue: "2026-02-30"))
        XCTAssertNil(CivilDay(rawValue: "2026-2-1"))
        XCTAssertNil(CivilDay(rawValue: "invalid"))
        XCTAssertNotNil(CivilDay(rawValue: "2028-02-29"))
    }
}

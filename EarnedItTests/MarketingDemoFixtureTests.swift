#if DEBUG && targetEnvironment(simulator)
import XCTest
@testable import EarnedIt

@MainActor
final class MarketingDemoFixtureTests: XCTestCase {
    func testDemoRequiresBothExplicitFlagsAndDoesNotSeedOrdinaryStores() throws {
        for arguments in [[], ["--marketing-demo"], ["--ui-test-store"]] {
            let repository = try HouseholdRepository(inMemory: true)
            let store = try HouseholdStore(repository: repository, automaticSync: false,
                                           activityAlerts: DisabledActivityAlerts())
            try MarketingDemoFixture.prepare(store, arguments: arguments)
            XCTAssertNil(store.household)
            XCTAssertTrue(store.snapshot.orderedFacts.isEmpty)
        }
    }

    func testDemoUsesRealRulesAndRetainsIdentitiesAcrossRelaunch() throws {
        MarketingDemoFixture.now = ISO8601DateFormatter().date(from: "2026-10-05T16:00:00Z")!
        let repository = try HouseholdRepository(inMemory: true)
        let store = try HouseholdStore(repository: repository, clock: { MarketingDemoFixture.now },
                                       automaticSync: false, activityAlerts: DisabledActivityAlerts())
        let arguments = ["--ui-test-store", "--marketing-demo", "--marketing-member=remy-smith"]
        try MarketingDemoFixture.prepare(store, arguments: arguments)
        XCTAssertEqual(store.household?.name, "The Smiths")
        XCTAssertEqual(Set(store.snapshot.members.map(\.displayName)), ["Alex Smith", "Remy Smith", "Piper Smith"])
        let remy = try XCTUnwrap(store.selectedMember)
        XCTAssertEqual(remy.role, .child)
        XCTAssertEqual(store.day.rawValue, "2026-10-14")
        XCTAssertNil(store.session.location)
        XCTAssertTrue(store.snapshot.invitations.isEmpty)
        XCTAssertTrue(store.snapshot.invitationClaims.isEmpty)
        XCTAssertEqual(store.dailyList().count, 4)
        XCTAssertEqual(store.dailyList().filter(\.isFullyComplete).count, 3)
        XCTAssertEqual(MetricsService.streak(childID: remy.id, snapshot: store.snapshot, today: store.today), 9)
        XCTAssertTrue(store.allowanceHistory(for: remy.id).dropFirst().first?.earned == true)
        XCTAssertEqual(store.allowanceWeek(for: remy.id).amount?.minorUnits, 1200)
        let familyID = store.household?.id
        let factIDs = store.snapshot.orderedFacts.map(\.id)
        let relaunched = try HouseholdStore(repository: repository, clock: { MarketingDemoFixture.now },
                                            automaticSync: false, activityAlerts: DisabledActivityAlerts())
        try MarketingDemoFixture.prepare(relaunched, arguments: arguments)
        XCTAssertEqual(relaunched.household?.id, familyID)
        XCTAssertEqual(relaunched.selectedMember?.id, remy.id)
        XCTAssertEqual(relaunched.snapshot.orderedFacts.map(\.id), factIDs)
    }
}
#endif

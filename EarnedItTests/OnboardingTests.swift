import SwiftData
import XCTest
@testable import EarnedIt

@MainActor
final class OnboardingTests: XCTestCase {
    private func container(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([FamilyUser.self, Responsibility.self, DailyRecord.self, ExcusedDay.self, AppSetting.self])
        let configuration = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func settings(_ context: ModelContext) throws -> [AppSetting] {
        try context.fetch(FetchDescriptor<AppSetting>())
    }

    func testFreshStoreRemainsEmptyAcrossDailyPreparation() throws {
        let store = try container()
        let context = store.mainContext
        try DataCoordinator.prepareDailyData(context: context)
        try DataCoordinator.prepareDailyData(context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FamilyUser>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Responsibility>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExcusedDay>()), 0)
        XCTAssertTrue(try settings(context).isEmpty)
        XCTAssertEqual(OnboardingService.disposition(in: try settings(context)), .inProgress)
        XCTAssertEqual(OnboardingService.stage(in: try settings(context)), .welcome)
        XCTAssertNil(WeeklyScoringService.allowanceEarned(days: [], asOf: .now))
    }

    func testCompletionRequiresFamilyButSkipDoesNot() throws {
        let store = try container()
        let context = store.mainContext
        XCTAssertThrowsError(try OnboardingService.finish(context: context))
        try OnboardingService.finish(skipping: true, context: context)
        XCTAssertEqual(OnboardingService.disposition(in: try settings(context)), .skipped)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FamilyUser>()), 0)
        try OnboardingService.restart(resuming: true, context: context)
        let parent = try FamilyUserService.save(id: UUID(), name: "Test Parent", role: .parent, avatar: .sun, context: context)
        XCTAssertThrowsError(try OnboardingService.finish(context: context))
        try FamilyUserService.save(id: UUID(), name: "Test Child", role: .child, avatar: .star, context: context)
        try OnboardingService.finish(context: context)
        try OnboardingService.finish(context: context)
        XCTAssertEqual(OnboardingService.disposition(in: try settings(context)), .completed)
        XCTAssertEqual(SettingsStore.value(for: SettingsStore.selectedUserIDKey, in: try settings(context)), parent.id.uuidString)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FamilyUser>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Responsibility>()), 0)
    }

    func testPartialSkippedAndCompletedSetupSurviveReopeningDiskStore() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "test.store")
        let parentID = UUID()
        do {
            let store = try container(url: url)
            let context = store.mainContext
            try FamilyUserService.save(id: parentID, name: "Test Parent", role: .parent, avatar: .sun, context: context)
            try OnboardingService.move(to: .children, context: context)
        }
        do {
            let store = try container(url: url)
            let context = store.mainContext
            XCTAssertEqual(OnboardingService.stage(in: try settings(context)), .children)
            XCTAssertEqual(OnboardingService.disposition(in: try settings(context)), .inProgress)
            XCTAssertEqual(try context.fetch(FetchDescriptor<FamilyUser>()).first?.id, parentID)
            try OnboardingService.finish(skipping: true, context: context)
        }
        do {
            let store = try container(url: url)
            let context = store.mainContext
            XCTAssertEqual(OnboardingService.disposition(in: try settings(context)), .skipped)
            try OnboardingService.restart(resuming: true, context: context)
            XCTAssertEqual(OnboardingService.stage(in: try settings(context)), .children)
            try FamilyUserService.save(id: UUID(), name: "Test Child", role: .child, avatar: .star, context: context)
            try OnboardingService.finish(context: context)
        }
        do {
            let store = try container(url: url)
            XCTAssertEqual(OnboardingService.disposition(in: try settings(store.mainContext)), .completed)
            XCTAssertEqual(try store.mainContext.fetchCount(FetchDescriptor<FamilyUser>()), 2)
        }
    }

    func testNamesValidatedAndRepeatedSaveUsesStableIdentity() throws {
        let store = try container()
        let context = store.mainContext
        let id = UUID()
        XCTAssertThrowsError(try FamilyUserService.save(id: id, name: " \n ", role: .parent, avatar: .sun, context: context))
        XCTAssertThrowsError(try FamilyUserService.save(id: id, name: String(repeating: "x", count: 51), role: .parent, avatar: .sun, context: context))
        let user = try FamilyUserService.save(id: id, name: " Test Parent ", role: .parent, avatar: .sun, context: context)
        XCTAssertEqual(user.displayName, "Test Parent")
        try FamilyUserService.save(id: id, name: "Test Parent", role: .parent, avatar: .sun, context: context)
        XCTAssertThrowsError(try FamilyUserService.save(id: UUID(), name: " test parent ", role: .parent, avatar: .sun, context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FamilyUser>()), 1)
        try FamilyUserService.save(id: id, name: "Renamed Parent", role: .parent, avatar: .sun, context: context)
        XCTAssertEqual(user.id, id)
        XCTAssertEqual(user.displayName, "Renamed Parent")
    }

    func testPersistedResponsibilityDraftRetrySavesCurrentValuesWithoutDuplicating() throws {
        let store = try container()
        let context = store.mainContext
        context.autosaveEnabled = false
        let parent = try FamilyUserService.save(id: UUID(), name: "Test Parent", role: .parent, avatar: .sun, context: context)
        let firstChild = try FamilyUserService.save(id: UUID(), name: "First Child", role: .child, avatar: .star, context: context)
        let secondChild = try FamilyUserService.save(id: UUID(), name: "Second Child", role: .child, avatar: .fox, context: context)
        let draftID = UUID()
        try DataCoordinator.updateResponsibilityDraft(
            id: draftID, title: "Original title", notes: "Original notes", category: .home,
            actor: parent, assignedChildID: firstChild.id, context: context
        )
        try context.save()
        let original = try XCTUnwrap(context.fetch(FetchDescriptor<Responsibility>()).first)
        let persistentID = original.persistentModelID
        let createdAt = original.createdAt
        context.insert(DailyRecord(responsibilityID: draftID, childID: firstChild.id, day: .now))
        context.rollback()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Responsibility>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyRecord>()), 0)

        try DataCoordinator.updateResponsibilityDraft(
            id: draftID, title: "Revised title", notes: "Revised notes", category: .school,
            actor: parent, assignedChildID: secondChild.id, context: context
        )
        try context.save()
        try DataCoordinator.prepareDailyData(context: context)

        let reloaded = ModelContext(store)
        let drafts = try reloaded.fetch(FetchDescriptor<Responsibility>())
        XCTAssertEqual(drafts.count, 1)
        let saved = try XCTUnwrap(drafts.first)
        XCTAssertEqual(saved.id, draftID)
        XCTAssertEqual(saved.persistentModelID, persistentID)
        XCTAssertEqual(saved.createdAt, createdAt)
        XCTAssertEqual(saved.creatorID, parent.id)
        XCTAssertEqual(saved.creatorRole, .parent)
        XCTAssertTrue(saved.isActive)
        XCTAssertNil(saved.archivedAt)
        XCTAssertEqual(saved.title, "Revised title")
        XCTAssertEqual(saved.notes, "Revised notes")
        XCTAssertEqual(saved.category, .school)
        XCTAssertEqual(saved.assignedChildID, secondChild.id)
        let records = try reloaded.fetch(FetchDescriptor<DailyRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.responsibilityID, draftID)
        XCTAssertEqual(records.first?.childID, secondChild.id)
    }

    func testLegacyCompletedHouseholdIsPreservedAndRestartDoesNotResetIt() throws {
        let store = try container()
        let context = store.mainContext
        // A name previously used by a sample household must never trigger deletion.
        let parent = try FamilyUserService.save(id: UUID(), name: "Mom", role: .parent, avatar: .sun, context: context)
        let child = try FamilyUserService.save(id: UUID(), name: "Remy", role: .child, avatar: .star, context: context)
        let chore = Responsibility(title: "Test chore", category: .home, creatorID: parent.id,
                                   creatorRole: .parent, assignedChildID: child.id)
        context.insert(chore)
        try SettingsStore.set("true", for: SettingsStore.setupCompleteKey, context: context)
        try DataCoordinator.prepareDailyData(context: context)
        XCTAssertEqual(OnboardingService.disposition(in: try settings(context)), .completed)
        try OnboardingService.restart(context: context)
        XCTAssertEqual(OnboardingService.stage(in: try settings(context)), .welcome)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FamilyUser>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Responsibility>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyRecord>()), 1)
        XCTAssertEqual(parent.displayName, "Mom")
    }

    func testExplicitResetReturnsToEmptyWelcome() throws {
        let store = try container()
        let context = store.mainContext
        let parent = try FamilyUserService.save(id: UUID(), name: "Test Parent", role: .parent, avatar: .sun, context: context)
        let child = try FamilyUserService.save(id: UUID(), name: "Test Child", role: .child, avatar: .star, context: context)
        context.insert(Responsibility(title: "Test chore", category: .home, creatorID: parent.id,
                                     creatorRole: .parent, assignedChildID: child.id))
        context.insert(ExcusedDay(childID: child.id, day: .now))
        try OnboardingService.finish(context: context)
        try DataCoordinator.prepareDailyData(context: context)
        try OnboardingService.clearAll(context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FamilyUser>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Responsibility>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExcusedDay>()), 0)
        XCTAssertTrue(try settings(context).isEmpty)
        XCTAssertEqual(OnboardingService.disposition(in: try settings(context)), .inProgress)
    }
}

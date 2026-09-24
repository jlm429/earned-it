import SwiftUI

@main
struct EarnedItApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: HouseholdStore?
    private let startupError: String?

    init() {
        do {
            let url: URL
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            let readOnlyPreflight = arguments.contains("--owner-transition-preflight")
                || arguments.contains("--child-recovery-preflight")
            let isUITest = arguments.contains("--ui-test-store")
            if isUITest {
                url = URL.documentsDirectory.appending(path: "shared-household-ui-tests.store")
            } else {
                url = URL.applicationSupportDirectory.appending(path: "shared-household-v1.store")
            }
            #else
            url = URL.applicationSupportDirectory.appending(path: "shared-household-v1.store")
            #endif
            let repository = try HouseholdRepository(url: url)
            #if DEBUG
            if !readOnlyPreflight && isUITest && arguments.contains("--ui-test-reset") {
                try repository.clearLocalData()
            }
            if !readOnlyPreflight && isUITest && arguments.contains("--ui-test-pending-invitation") {
                var session = try repository.session()
                session.pendingInvitationPackage = PendingInvitationPackage(
                    codeDigest: InvitationCode.digest("2345-6789-AB")!,
                    shareURL: URL(string: "https://www.icloud.com/share/synthetic-only")!,
                    cloudParticipantID: "synthetic-ui-test-account", needsAppleVerification: true)
                try repository.commit(facts: [], session: session)
            }
            if !readOnlyPreflight && isUITest && arguments.contains("--ui-test-last-join-receipt") {
                var session = try repository.session()
                session.lastJoinReceipt = LastJoinReceipt(
                    nativeAcceptance: .yes,
                    sharedZoneVisible: .yes,
                    claim: .absent,
                    lock: .released,
                    exactMembership: .no,
                    localAttach: .no,
                    rootRoute: .onboarding,
                    failureStage: .claim,
                    failureCategory: .cloudKitPermission
                )
                try repository.commit(facts: [], session: session)
            }
            if !readOnlyPreflight && isUITest && arguments.contains("--ui-test-family-deletion-notice") {
                var session = try repository.session()
                session.familyDeletionNoticeState = .pending
                try repository.commit(facts: [], session: session)
            }
            #endif
            let transport: (any HouseholdTransport)?
            #if targetEnvironment(simulator)
            // Unsigned simulator builds cannot use the CloudKit container. Tests inject a transport explicitly.
            transport = nil
            #else
            transport = CloudKitHouseholdTransport()
            #endif
            #if DEBUG
            let resetBoundary: (any AccountDataResetCloudBoundary)? = isUITest
                && arguments.contains("--ui-test-account-reset")
                ? UITestAccountDataResetCloudBoundary() : nil
            let initialStore = try HouseholdStore(repository: repository, transport: transport,
                clock: { WeeklyUITestFixture.enabled ? WeeklyUITestFixture.now : .now },
                automaticSync: !readOnlyPreflight, performLocalMigrations: !readOnlyPreflight,
                localDataResetter: AppAccountLocalDataResetter(activeStoreURL: url),
                accountDataResetCloudBoundary: resetBoundary)
            if !readOnlyPreflight { try WeeklyUITestFixture.prepare(initialStore) }
            if !readOnlyPreflight && isUITest
                && arguments.contains("--ui-test-stale-owner-membership") {
                initialStore.prepareStaleOwnerMembershipRecoveryUITest()
            }
            if !readOnlyPreflight && isUITest
                && arguments.contains("--ui-test-membership-recovery-progress") {
                initialStore.prepareMembershipRecoveryProgressUITest()
            }
            #else
            let initialStore = try HouseholdStore(
                repository: repository,
                transport: transport,
                localDataResetter: AppAccountLocalDataResetter(activeStoreURL: url)
            )
            #endif
            _store = State(initialValue: initialStore)
            startupError = nil
        } catch {
            startupError = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            if let store {
                RootView().environment(store)
            } else {
                ContentUnavailableView("Unable to Open Family Data", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(startupError ?? "Your stored data has been kept. Try reopening the app."))
            }
        }
    }
}

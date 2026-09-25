import CloudKit
import SwiftUI

@main
struct EarnedItApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: HouseholdStore?
    private let startupError: String?
    private let startupResetCoordinator: AccountDataResetCoordinator?
    private let reopenStore: (() throws -> HouseholdStore)?

    init() {
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
        let arguments: [String] = []
        let readOnlyPreflight = false
        let isUITest = false
        url = URL.applicationSupportDirectory.appending(path: "shared-household-v1.store")
        #endif

        let transport: (any HouseholdTransport)?
        #if targetEnvironment(simulator)
        transport = nil
        #else
        transport = CloudKitHouseholdTransport()
        #endif
        #if DEBUG
        let resetBoundary: (any AccountDataResetCloudBoundary)? = isUITest
            && arguments.contains("--ui-test-account-reset")
            ? UITestAccountDataResetCloudBoundary() : nil
        #else
        let resetBoundary: (any AccountDataResetCloudBoundary)? = nil
        #endif
        let journal = FileAccountDataResetJournal(storeURL: url)
        let localDataResetter = AppAccountLocalDataResetter(activeStoreURL: url)

        let makeStore: (Bool) throws -> HouseholdStore = { simulateStartupFailure in
            #if DEBUG
            if simulateStartupFailure && arguments.contains("--ui-test-startup-failure") {
                throw HouseholdError.malformedData
            }
            if !readOnlyPreflight && isUITest && arguments.contains("--ui-test-reset") {
                try journal.clear()
            }
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
            #if DEBUG
            let initialStore = try HouseholdStore(repository: repository, transport: transport,
                clock: { WeeklyUITestFixture.enabled ? WeeklyUITestFixture.now : .now },
                automaticSync: !readOnlyPreflight, performLocalMigrations: !readOnlyPreflight,
                localDataResetter: localDataResetter,
                accountDataResetCloudBoundary: resetBoundary,
                accountDataResetJournal: journal)
            if !readOnlyPreflight { try WeeklyUITestFixture.prepare(initialStore) }
            if !readOnlyPreflight && isUITest
                && arguments.contains("--ui-test-stale-owner-membership") {
                initialStore.prepareStaleOwnerMembershipRecoveryUITest()
            }
            if !readOnlyPreflight && isUITest
                && arguments.contains("--ui-test-membership-recovery-progress") {
                initialStore.prepareMembershipRecoveryProgressUITest()
            }
            if !readOnlyPreflight && isUITest
                && arguments.contains("--ui-test-family-access-lost") {
                if initialStore.household == nil {
                    try initialStore.createFamily(name: "Orphaned Family", parentName: "Parent")
                    let child = try initialStore.saveMember(name: "Child", role: .child, avatar: .star)
                    try initialStore.finishSetup()
                    try initialStore.selectProfile(child.id)
                }
                try initialStore.prepareFamilyAccessLostUITest()
            }
            if !readOnlyPreflight && isUITest
                && arguments.contains("--ui-test-invitation-actions") {
                try initialStore.prepareInvitationActionsUITest()
            }
            #else
            let initialStore = try HouseholdStore(
                repository: repository,
                transport: transport,
                localDataResetter: localDataResetter,
                accountDataResetJournal: journal
            )
            #endif
            return initialStore
        }

        do {
            _store = State(initialValue: try makeStore(true))
            startupError = nil
            startupResetCoordinator = nil
            reopenStore = nil
        } catch {
            _store = State(initialValue: nil)
            startupError = error.localizedDescription
            if let cloudBoundary = resetBoundary ?? transport {
                startupResetCoordinator = AccountDataResetCoordinator(
                    transport: cloudBoundary,
                    localBoundary: StartupFailureAccountDataResetLocalBoundary(
                        localDataResetter: localDataResetter,
                        journal: journal
                    )
                )
            } else {
                startupResetCoordinator = nil
            }
            reopenStore = { try makeStore(false) }
        }
    }

    var body: some Scene {
        WindowGroup {
            if let store {
                RootView().environment(store)
            } else if let startupError, let reopenStore {
                StartupFailureRecoveryView(
                    startupError: startupError,
                    resetCoordinator: startupResetCoordinator,
                    reopenStore: reopenStore,
                    didRecover: { store = $0 }
                )
            }
        }
    }
}

private struct StartupFailureRecoveryView: View {
    let startupError: String
    let resetCoordinator: AccountDataResetCoordinator?
    let reopenStore: () throws -> HouseholdStore
    let didRecover: (HouseholdStore) -> Void
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            ContentUnavailableView(
                "Unable to Open Family Data",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text("Your stored data has been kept. Try opening it again, or permanently delete this iCloud account's Earned It data and local app data.")
            )
            VStack(spacing: 16) {
                Button("Try Reconnecting") {
                    do { didRecover(try reopenStore()) }
                    catch { errorMessage = error.localizedDescription }
                }
                .disabled(isDeleting)
                .accessibilityIdentifier("retry-open-family-data")
                ConfirmedDeleteAllEarnedItDataButton(
                    isDeleting: isDeleting,
                    action: deleteAllData,
                    onError: { errorMessage = $0.localizedDescription }
                )
                if isDeleting { ProgressView("Deleting data…") }
                Text(startupError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .accessibilityIdentifier("startup-failure-recovery")
        .alert("Unable to Delete Data", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            resetCoordinator?.accountDidChange()
        }
    }

    @MainActor
    private func deleteAllData() async throws {
        guard let resetCoordinator else { throw HouseholdError.cloudUnavailable }
        isDeleting = true
        ShareAcceptance.shared.pending = nil
        defer {
            ShareAcceptance.shared.pending = nil
            isDeleting = false
        }
        try await resetCoordinator.run { _ in }
        ShareAcceptance.shared.pending = nil
        didRecover(try reopenStore())
    }
}

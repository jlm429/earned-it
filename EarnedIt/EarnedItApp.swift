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
            let isUITest = ProcessInfo.processInfo.arguments.contains("--ui-test-store")
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
            if isUITest && ProcessInfo.processInfo.arguments.contains("--ui-test-reset") {
                try repository.clearLocalData()
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
            let initialStore = try HouseholdStore(repository: repository, transport: transport,
                clock: { WeeklyUITestFixture.enabled ? WeeklyUITestFixture.now : .now })
            try WeeklyUITestFixture.prepare(initialStore)
            #else
            let initialStore = try HouseholdStore(repository: repository, transport: transport)
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

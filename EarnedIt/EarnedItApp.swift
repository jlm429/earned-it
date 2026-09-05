import SwiftData
import SwiftUI

@main
struct EarnedItApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            let schema = Schema([
                FamilyUser.self,
                Responsibility.self,
                DailyRecord.self,
                ExcusedDay.self,
                AppSetting.self
            ])
            let configuration: ModelConfiguration
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-store") {
                let url = URL.documentsDirectory.appending(path: "isolated-ui-tests.store")
                configuration = ModelConfiguration(schema: schema, url: url)
            } else {
                configuration = ModelConfiguration(schema: schema)
            }
            #else
            configuration = ModelConfiguration(schema: schema)
            #endif
            try FileManager.default.createDirectory(
                at: configuration.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-store")
                && ProcessInfo.processInfo.arguments.contains("--ui-test-reset") {
                try OnboardingService.clearAll(context: modelContainer.mainContext)
            }
            #endif
        } catch {
            fatalError("Unable to create local data store: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }
}

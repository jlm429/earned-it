import SwiftData
import SwiftUI

@main
struct EarnedItApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: FamilyUser.self,
                Responsibility.self,
                DailyRecord.self,
                ExcusedDay.self,
                AppSetting.self
            )
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

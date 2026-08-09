import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FamilyUser.createdAt) private var users: [FamilyUser]
    @Query private var settings: [AppSetting]

    @State private var isPreparing = true
    @State private var preparationError: String?

    private var setupComplete: Bool {
        SettingsStore.bool(for: SettingsStore.setupCompleteKey, in: settings)
    }

    private var selectedUser: FamilyUser? {
        guard let rawID = SettingsStore.value(for: SettingsStore.selectedUserIDKey, in: settings),
              let id = UUID(uuidString: rawID) else { return nil }
        return users.first { $0.id == id }
    }

    var body: some View {
        Group {
            if isPreparing {
                ProgressView("Preparing Allowance Tracker")
                    .accessibilityIdentifier("launch-progress")
            } else if !setupComplete {
                SetupView()
            } else if let selectedUser {
                MainRoleView(user: selectedUser)
            } else {
                UserSelectionView()
            }
        }
        .task {
            guard isPreparing else { return }
            do {
                if ProcessInfo.processInfo.arguments.contains("--reset-sample-data") {
                    try SampleDataService.seed(context: modelContext)
                } else {
                    try DataCoordinator.prepareDailyData(context: modelContext)
                }
            } catch {
                preparationError = error.localizedDescription
            }
            isPreparing = false
        }
        .alert("Local Data Error", isPresented: Binding(
            get: { preparationError != nil },
            set: { if !$0 { preparationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(preparationError ?? "Please try again.")
        }
    }
}

import SwiftData
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \FamilyUser.createdAt) private var users: [FamilyUser]
    @Query private var settings: [AppSetting]

    @State private var isPreparing = true
    @State private var preparationError: String?
    @State private var today = Date.now

    private var setupComplete: Bool {
        OnboardingService.disposition(in: settings) != .inProgress
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
                MainRoleView(user: selectedUser, today: today)
            } else {
                UserSelectionView()
            }
        }
        .task {
            prepareForLaunch()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !isPreparing else { return }
            refreshDailyData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            guard !isPreparing else { return }
            refreshDailyData()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            guard !isPreparing else { return }
            refreshDailyData()
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

    private func prepareForLaunch() {
        guard isPreparing else { return }
        do {
            try DataCoordinator.prepareDailyData(context: modelContext, today: today)
        } catch {
            preparationError = error.localizedDescription
        }
        isPreparing = false
    }

    private func refreshDailyData() {
        let now = Date.now
        today = now
        do {
            try DataCoordinator.prepareDailyData(context: modelContext, today: now)
        } catch {
            preparationError = error.localizedDescription
        }
    }
}

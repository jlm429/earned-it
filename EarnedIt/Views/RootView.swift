import CloudKit
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var invitations = ShareAcceptance.shared

    var body: some View {
        @Bindable var store = store
        Group {
            if store.household == nil || store.household?.isSetupComplete == false {
                SetupView()
            } else if let member = store.selectedMember {
                MainRoleView(user: member, today: store.today)
            } else {
                UserSelectionView()
            }
        }
        #if DEBUG
        .preferredColorScheme(WeeklyUITestFixture.enabled && ProcessInfo.processInfo.arguments.contains("--ui-test-dark") ? .dark : nil)
        #endif
        .environment(\.calendar, store.calendar)
        .environment(\.timeZone, store.calendar.timeZone)
        .task { store.refreshDate(); await acceptInvitation() }
        .task(id: "\(scenePhase)-\(store.nextHouseholdMidnight.timeIntervalSince1970)-\(store.midnightTimerRevision)") {
            guard scenePhase == .active else { return }
            let delay = max(0, store.nextHouseholdMidnight.timeIntervalSince(store.today))
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            store.refreshDate()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.refreshDate() }
        }
        .onChange(of: invitations.pending) { _, _ in Task { await acceptInvitation() } }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in store.refreshDate() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in store.refreshDate() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in store.significantTimeChanged() }
        .alert("Unable to Update", isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "Please try again.")
        }
    }

    private func acceptInvitation() async {
        guard let metadata = invitations.pending else { return }
        invitations.pending = nil
        await store.accept(metadata: metadata)
    }
}

import CloudKit
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var invitations = ShareAcceptance.shared
    @State private var cloudAccountRevision = 0

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
        .task {
            store.refreshDate()
            do {
                try await store.reconcileAccountMembershipLock()
            }
            catch { store.errorMessage = error.localizedDescription }
            await acceptInvitation()
        }
        .task(id: "\(scenePhase)-\(store.pendingInvitationCleanupID ?? "none")-\(cloudAccountRevision)") {
            guard scenePhase == .active, store.pendingInvitationCleanupID != nil else { return }
            do {
                var retryDelay = try await store.retryScheduledInvitationCleanup()
                while true {
                    let delay: TimeInterval
                    if let retryDelay {
                        delay = retryDelay
                    } else if let scheduledDelay = try await store.pendingInvitationCleanupDelay() {
                        delay = scheduledDelay
                    } else {
                        return
                    }
                    try await ContinuousClock().sleep(for: .seconds(delay))
                    retryDelay = try await store.retryScheduledInvitationCleanup()
                }
            } catch is CancellationError {
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            store.cloudAccountDidChange()
            cloudAccountRevision &+= 1
            store.refreshDate()
        }
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

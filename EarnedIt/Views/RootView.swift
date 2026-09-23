import CloudKit
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var invitations = ShareAcceptance.shared
    @State private var cloudAccountRevision = 0
    @State private var diagnosticPreflightFinished = false
    @State private var diagnosticPreflightAvailable = false

    var body: some View {
        @Bindable var store = store
        Group {
            if readOnlyPreflightMode {
                ContentUnavailableView {
                    Label(diagnosticPreflightFinished ? "Snapshot Captured" : "Capturing Before-State",
                          systemImage: diagnosticPreflightFinished ? "checkmark.circle" : "waveform.path.ecg")
                } description: {
                    Text(diagnosticPreflightFinished
                         ? diagnosticPreflightAvailable
                            ? "The privacy-safe \(childRecoveryPreflightMode ? "child recovery" : "family transition") snapshot is available in the diagnostic log."
                            : "No matching local family was available for this read-only snapshot."
                         : "Earned It is reading \(childRecoveryPreflightMode ? "child recovery" : "family transition") state without synchronizing or changing iCloud data.")
                }
                .accessibilityIdentifier(childRecoveryPreflightMode
                    ? "child-recovery-preflight" : "owner-transition-preflight")
            } else if store.hasPendingInvitationPackage {
                ContentUnavailableView {
                    Label("Finish Joining Your Family", systemImage: "person.crop.circle.badge.checkmark")
                } description: {
                    Text("Follow any Apple confirmation to connect to your family. Earned It keeps this invitation so you can finish without entering the code again.")
                } actions: {
                    if store.isJoiningInvitation {
                        ProgressView("Connecting to your family…")
                    } else {
                        Button("Continue Joining") {
                            Task {
                                do { try await store.continuePendingInvitation(allowAppleVerification: true) }
                                catch { store.errorMessage = error.localizedDescription }
                            }
                        }
                        .accessibilityIdentifier("continue-invitation")
                    }
                }
                .accessibilityIdentifier("pending-invitation-screen")
                .onAppear { store.recordJoinRootRoute(.pendingInvitation) }
            } else if store.isCheckingAccountMembership && store.household == nil {
                ProgressView("Reconnecting to your family…")
                    .accessibilityIdentifier("membership-recovery-progress")
                    .onAppear { store.recordJoinRootRoute(.membershipRecovery) }
            } else if store.requiresMembershipRecovery && store.household == nil {
                ContentUnavailableView {
                    Label("Reconnect to Your Family", systemImage: "icloud.and.arrow.down")
                } description: {
                    Text("Your iCloud membership has been kept. Reconnect to your existing family to continue with your approved profile.")
                } actions: {
                    Button("Try Reconnecting") {
                        Task {
                            do { try await store.reconcileAccountMembershipLock() }
                            catch { store.errorMessage = error.localizedDescription }
                        }
                    }
                    .accessibilityIdentifier("retry-membership-recovery")
                }
                .accessibilityIdentifier("membership-recovery-required")
                .onAppear { store.recordJoinRootRoute(.membershipRecovery) }
            } else if store.familyAccessLost && store.household != nil {
                ContentUnavailableView {
                    Label("Family Access Needs Attention", systemImage: "person.3.fill")
                } description: {
                    Text("This device cannot currently access the family in iCloud. Check access to retry. Your saved family stays on this device.")
                } actions: {
                    if store.canFinishDeletingFamily {
                        Button("Finish Deleting Family", role: .destructive) {
                            Task {
                                do { try await store.deleteFamily() }
                                catch { store.errorMessage = error.localizedDescription }
                            }
                        }
                        .accessibilityIdentifier("retry-delete-family")
                    }
                    Button("Check Family Access") {
                        Task {
                            do { try await store.synchronize() }
                            catch { store.errorMessage = error.localizedDescription }
                        }
                    }
                    if store.canRemoveUnavailableFamilyFromDevice {
                        Button("Remove From This Device", role: .destructive) {
                            store.perform { try store.removeUnavailableFamilyFromDevice() }
                        }
                        .accessibilityIdentifier("remove-unavailable-family")
                    }
                }
                .accessibilityIdentifier("family-access-ended")
            } else if store.household == nil || store.household?.isSetupComplete == false {
                SetupView()
                    .onAppear { store.recordJoinRootRoute(.onboarding) }
            } else if let member = store.selectedMember {
                MainRoleView(user: member, today: store.today)
                    .onAppear { store.recordJoinRootRoute(.member) }
            } else {
                UserSelectionView()
                    .onAppear { store.recordJoinRootRoute(.profileSelection) }
            }
        }
        #if DEBUG
        .preferredColorScheme(WeeklyUITestFixture.enabled && ProcessInfo.processInfo.arguments.contains("--ui-test-dark") ? .dark : nil)
        #endif
        .environment(\.calendar, store.calendar)
        .environment(\.timeZone, store.calendar.timeZone)
        .task(id: store.session.deviceID) {
            if readOnlyPreflightMode {
                if childRecoveryPreflightMode {
                    diagnosticPreflightAvailable = await store.collectChildRecoveryPreflight() != nil
                } else {
                    diagnosticPreflightAvailable = await store.collectOwnerTransitionPreflight() != nil
                }
                diagnosticPreflightFinished = true
                return
            }
            store.refreshDate()
            if store.hasPendingInvitationPackage {
                do { try await store.continuePendingInvitation() }
                catch { store.errorMessage = error.localizedDescription }
                await acceptInvitation()
                return
            }
            do {
                try await store.reconcileAccountMembershipLock()
            }
            catch { store.errorMessage = error.localizedDescription }
            await acceptInvitation()
        }
        .task(id: "\(scenePhase)-\(store.pendingInvitationCleanupID ?? "none")-\(cloudAccountRevision)") {
            guard !readOnlyPreflightMode, scenePhase == .active,
                  store.pendingInvitationCleanupID != nil else { return }
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
            guard !readOnlyPreflightMode, scenePhase == .active else { return }
            let delay = max(0, store.nextHouseholdMidnight.timeIntervalSince(store.today))
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            store.refreshDate()
        }
        .onChange(of: scenePhase) { _, phase in
            if !readOnlyPreflightMode, phase == .active {
                store.refreshDate()
                Task {
                    await acceptInvitation()
                    if store.hasPendingInvitationPackage {
                        do { try await store.continuePendingInvitation() }
                        catch { store.errorMessage = error.localizedDescription }
                    }
                }
            }
        }
        .onOpenURL { url in
            guard !readOnlyPreflightMode, url.scheme == "earnedit-invitation" else { return }
            Task {
                do { try await store.redeemInvitation(url.absoluteString) }
                catch { store.errorMessage = error.localizedDescription }
            }
        }
        .onChange(of: invitations.pending) { _, _ in
            guard !readOnlyPreflightMode else { return }
            Task { await acceptInvitation() }
        }
        .onChange(of: store.isJoiningInvitation) { _, joining in
            if !readOnlyPreflightMode, !joining { Task { await acceptInvitation() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            guard !readOnlyPreflightMode else { return }
            store.cloudAccountDidChange()
            cloudAccountRevision &+= 1
            store.refreshDate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            guard !readOnlyPreflightMode else { return }
            store.refreshDate()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            guard !readOnlyPreflightMode else { return }
            store.significantTimeChanged()
        }
        .alert("Unable to Update", isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "Please try again.")
        }
        .alert("Family data was deleted", isPresented: Binding(
            get: { store.hasFamilyDeletionNotice },
            set: { presented in
                if !presented { store.perform { try store.dismissFamilyDeletionNotice() } }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This family was permanently deleted. You can create or join another family.")
        }
    }

    private func acceptInvitation() async {
        guard !readOnlyPreflightMode, !store.isJoiningInvitation,
              let metadata = invitations.pending else { return }
        invitations.pending = nil
        await store.accept(metadata: metadata)
    }

    private var ownerTransitionPreflightMode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--owner-transition-preflight")
        #else
        false
        #endif
    }

    private var childRecoveryPreflightMode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--child-recovery-preflight")
        #else
        false
        #endif
    }

    private var readOnlyPreflightMode: Bool {
        ownerTransitionPreflightMode || childRecoveryPreflightMode
    }
}

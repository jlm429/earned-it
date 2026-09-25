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
    @State private var confirmsStaleOwnerRelease = false

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
            } else if store.hasPendingAccountDataReset {
                ScrollableUnavailableView(
                    title: "Deleting Earned It Data",
                    systemImage: "trash.circle",
                    description: "Cloud cleanup must finish before local family data is removed. Keep this device online, or retry when your connection returns."
                ) {
                    if store.isDeletingAllEarnedItData {
                        ProgressView("Deleting data…")
                    } else {
                        Button("Retry Deletion", role: .destructive) {
                            Task {
                                do { try await store.deleteAllEarnedItData() }
                                catch { store.errorMessage = error.localizedDescription }
                            }
                        }
                        .accessibilityIdentifier("retry-delete-all-earned-it-data")
                    }
                }
                .accessibilityIdentifier("account-data-reset-progress")
            } else if store.hasPendingInvitationPackage || store.hasPendingInvitationAcceptance {
                ScrollableUnavailableView(
                    title: "Finish Joining Your Family",
                    systemImage: "person.crop.circle.badge.checkmark",
                    description: store.hasPendingInvitationPackage
                        ? "Follow any Apple confirmation to connect to your family. Earned It keeps this invitation so you can finish without entering the code again."
                        : "Earned It keeps this invitation attempt so you can finish joining without starting another family."
                ) {
                    if store.isJoiningInvitation {
                        ProgressView("Connecting to your family…")
                    } else {
                        Button("Continue Joining") {
                            Task {
                                do {
                                    if store.hasPendingInvitationPackage {
                                        try await store.continuePendingInvitation(allowAppleVerification: true)
                                    } else {
                                        try await store.retryInvitationCleanup()
                                    }
                                }
                                catch { store.errorMessage = error.localizedDescription }
                            }
                        }
                        .accessibilityIdentifier("continue-invitation")
                    }
                    DeleteAllEarnedItDataButton()
                }
                .accessibilityIdentifier("pending-invitation-screen")
                .onAppear { store.recordJoinRootRoute(.pendingInvitation) }
            } else if store.isCheckingAccountMembership && store.household == nil {
                ScrollableUnavailableView(
                    title: "Reconnecting to Your Family",
                    systemImage: "icloud.and.arrow.down",
                    description: "Earned It is checking this iCloud account's family membership. You can retry or permanently delete this account's Earned It data."
                ) {
                    ProgressView("Reconnecting to your family…")
                    Button("Try Reconnecting") {
                        Task {
                            do { try await store.retryAccountMembershipRecovery() }
                            catch { store.errorMessage = error.localizedDescription }
                        }
                    }
                    .accessibilityIdentifier("retry-membership-recovery-progress")
                    DeleteAllEarnedItDataButton()
                }
                .accessibilityIdentifier("membership-recovery-progress")
                .onAppear { store.recordJoinRootRoute(.membershipRecovery) }
            } else if store.requiresMembershipRecovery && store.canReleaseStaleOwnerMembership
                && store.household == nil {
                ScrollableUnavailableView(
                    title: "Your Family Is Not Available",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: "Earned It found this iCloud account's owning-parent membership, but its family is unavailable. Try reconnecting, or permanently delete this account's Earned It data and return to Welcome."
                ) {
                    Button("Try Reconnecting") {
                        Task {
                            do { try await store.retryAccountMembershipRecovery() }
                            catch { store.errorMessage = error.localizedDescription }
                        }
                    }
                    .accessibilityIdentifier("retry-owner-membership-recovery")
                    Button("Release My Membership", role: .destructive) {
                        confirmsStaleOwnerRelease = true
                    }
                    .accessibilityIdentifier("release-stale-owner-membership")
                    DeleteAllEarnedItDataButton()
                }
                .accessibilityIdentifier("owner-membership-recovery-required")
                .onAppear { store.recordJoinRootRoute(.membershipRecovery) }
            } else if store.requiresMembershipRecovery && store.household == nil {
                ScrollableUnavailableView(
                    title: "Reconnect to Your Family",
                    systemImage: "icloud.and.arrow.down",
                    description: "Your iCloud membership has been kept. Reconnect to your existing family to continue with your approved profile."
                ) {
                    Button("Try Reconnecting") {
                        Task {
                            do { try await store.retryAccountMembershipRecovery() }
                            catch { store.errorMessage = error.localizedDescription }
                        }
                    }
                    .accessibilityIdentifier("retry-membership-recovery")
                    DeleteAllEarnedItDataButton()
                }
                .accessibilityIdentifier("membership-recovery-required")
                .onAppear { store.recordJoinRootRoute(.membershipRecovery) }
            } else if store.familyAccessLost && store.household != nil {
                ScrollableUnavailableView(
                    title: "Family Access Needs Attention",
                    systemImage: "person.3.fill",
                    description: "This device cannot currently access the family in iCloud. Try reconnecting. Your saved family stays on this device."
                ) {
                    if store.canFinishDeletingFamily {
                        Button("Finish Deleting Family", role: .destructive) {
                            Task {
                                do { try await store.deleteFamily() }
                                catch { store.errorMessage = error.localizedDescription }
                            }
                        }
                        .accessibilityIdentifier("retry-delete-family")
                    }
                    Button("Try Reconnecting") {
                        Task {
                            do { try await store.synchronize() }
                            catch { store.errorMessage = error.localizedDescription }
                        }
                    }
                    .accessibilityIdentifier("retry-family-access")
                    DeleteAllEarnedItDataButton()
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
                    .id(store.session.deviceID)
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
            if membershipRecoveryProgressUITestMode { return }
            if store.hasPendingAccountDataReset {
                do { try await store.deleteAllEarnedItData() }
                catch { store.errorMessage = error.localizedDescription }
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
                try await store.reconcileAccountMembershipLockAutomatically()
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
            guard !readOnlyPreflightMode, !store.hasPendingAccountDataReset,
                  !store.isDeletingAllEarnedItData,
                  url.scheme == "earnedit-invitation" else { return }
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
        .confirmationDialog("Release This Membership?", isPresented: $confirmsStaleOwnerRelease,
                            titleVisibility: .visible) {
            Button("Release My Membership", role: .destructive) {
                Task {
                    do { try await store.releaseStaleOwnerMembership() }
                    catch { store.errorMessage = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This releases only this iCloud account's stale Earned It membership. It does not delete family data or change anyone else's access.")
        }
    }

    private func acceptInvitation() async {
        guard !readOnlyPreflightMode else { return }
        if store.hasPendingAccountDataReset || store.isDeletingAllEarnedItData {
            invitations.pending = nil
            return
        }
        guard !store.isJoiningInvitation, let metadata = invitations.pending else { return }
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

    private var membershipRecoveryProgressUITestMode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-test-membership-recovery-progress")
        #else
        false
        #endif
    }
}

private struct ScrollableUnavailableView<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: String
    let actions: Actions

    init(
        title: String,
        systemImage: String,
        description: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        Image(systemName: systemImage)
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(.title.bold())
                        Text(description)
                            .foregroundStyle(.secondary)
                    }
                    actions
                }
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

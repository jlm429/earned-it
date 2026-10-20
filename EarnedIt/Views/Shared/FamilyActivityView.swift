import SwiftUI
import UIKit

struct FamilyActivityView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    static func items(from activity: [FamilyActivity]) -> [FamilyActivity] {
        let pending = activity.filter { $0.punt?.status == .pending || $0.swap?.status == .pending }
        let other = activity.filter { $0.punt?.status != .pending && $0.swap?.status != .pending }
        return pending + other
    }

    var body: some View {
        let items = Self.items(from: store.activity)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if items.isEmpty {
                        ContentUnavailableView("You're all caught up", systemImage: "bubble.left.and.bubble.right",
                                               description: Text("New chore requests and family updates will appear here."))
                    }
                    ForEach(items.filter { $0.punt?.status == .pending || $0.swap?.status == .pending }) { activityCard($0) }
                    ActivityAlertSettings()
                    ForEach(items.filter { $0.punt?.status != .pending && $0.swap?.status != .pending }) { activityCard($0) }
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(AppTheme.canvas)
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await store.refresh() }
            .task(id: scenePhase) {
                if scenePhase == .active { await store.processActivityAlerts() }
            }
            .accessibilityIdentifier("family-activity")
        }
        .tint(AppTheme.accent)
    }

    private func activityCard(_ item: FamilyActivity) -> some View {
        SectionCard(tint: item.punt?.status == .pending || item.swap?.status == .pending ? AppTheme.info : nil) {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title).font(.headline).fixedSize()
                        unreadLabel(item).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        unreadLabel(item)
                    }
                }
                Text(item.detail).font(.subheadline)
                if let swap = item.swap {
                    SwapSummary(swap: swap)
                    swapActions(swap)
                }
                if let punt = item.punt {
                    Text("Made before Swap Turns. This request changes only one turn.")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    Label(statusText(punt), systemImage: punt.status == .pending ? "clock" : "person.2")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(punt.status == .accepted ? AppTheme.success : AppTheme.info)
                    puntActions(punt)
                }
                if !store.isActivityRead(item) {
                    Button("Mark Read") { store.perform { try store.markActivityRead(item) } }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("read-activity-\(item.id)")
                }
            }
        }
    }

    @ViewBuilder
    private func unreadLabel(_ item: FamilyActivity) -> some View {
        if !store.isActivityRead(item) {
            Label("New", systemImage: "circle.fill")
                .font(.caption).foregroundStyle(AppTheme.accent)
        }
    }

    private func statusText(_ punt: ProjectedPunt) -> String {
        switch punt.status {
        case .pending: "Pending approval. Responsibility has not changed."
        case .accepted: "Accepted. Today's responsibility transferred."
        case .declined: "Declined. The original child keeps this turn."
        case .cancelled: "Cancelled. The original child keeps this turn."
        case .expired: "No longer available. Check today's chore list."
        }
    }

    @ViewBuilder
    private func puntActions(_ punt: ProjectedPunt) -> some View {
        if punt.status == .pending, let actor = store.selectedMember {
            VStack(alignment: .leading, spacing: 8) {
                if actor.id == punt.request.recipientID {
                    Button("Accept Earlier Turn Request") { decide(punt, kind: .accepted) }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44)
                        .foregroundStyle(AppTheme.surface)
                        .accessibilityIdentifier("accept-punt")
                    Button("Decline Earlier Turn Request") { decide(punt, kind: .declined) }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                        .accessibilityIdentifier("decline-punt")
                } else if actor.id == punt.request.requesterID {
                    Button("Cancel Request", role: .cancel) { decide(punt, kind: .cancelled) }
                        .frame(minHeight: 44).accessibilityIdentifier("cancel-punt")
                }
            }
            .disabled(store.cloudIsReadOnly || store.cloudAccessBlocked)
        }
    }

    @ViewBuilder
    private func swapActions(_ swap: ProjectedSwap) -> some View {
        if swap.status == .pending, let actor = store.selectedMember, actor.role == .child {
            VStack(alignment: .leading, spacing: 8) {
                if actor.id == swap.request.recipientID {
                    Button("Accept Swap") { store.perform { try store.decideSwap(requestFactID: swap.id, kind: .accepted) } }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44)
                        .foregroundStyle(AppTheme.surface).accessibilityIdentifier("accept-swap")
                    Button("No Thanks") { store.perform { try store.decideSwap(requestFactID: swap.id, kind: .declined) } }
                        .buttonStyle(.bordered).frame(minHeight: 44).accessibilityIdentifier("decline-swap")
                } else if actor.id == swap.request.requesterID {
                    Button("Cancel Swap", role: .cancel) {
                        store.perform { try store.decideSwap(requestFactID: swap.id, kind: .cancelled) }
                    }.frame(minHeight: 44).accessibilityIdentifier("cancel-swap")
                }
            }.disabled(store.cloudIsReadOnly || store.cloudAccessBlocked)
        }
    }

    private func decide(_ punt: ProjectedPunt, kind: PuntDecisionKind) {
        store.perform { try store.decidePunt(requestFactID: punt.id, kind: kind) }
    }
}

private struct ActivityAlertSettings: View {
    @Environment(HouseholdStore.self) private var store
    @State private var isUpdating = false

    var body: some View {
        SectionCard(tint: AppTheme.info) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    Label("Notifications", systemImage: "bell.badge").fixedSize()
                    Text("Notifications").fixedSize(horizontal: false, vertical: true)
                }
                .font(.headline).accessibilityAddTraits(.isHeader)
                Toggle("Earned It alerts", isOn: Binding(
                    get: { store.activityAlertsEnabled },
                    set: { enabled in
                        isUpdating = true
                        Task {
                            await store.setActivityAlertsEnabled(enabled)
                            isUpdating = false
                        }
                    }
                ))
                .toggleStyle(.switch)
                .frame(minHeight: 44)
                .disabled(isUpdating)
                .accessibilityHint("Controls notifications and the app icon badge on this device. Activity and swap requests stay available.")
                .accessibilityIdentifier("activity-alerts-toggle")
                Text(store.activityAlertsEnabled ? "Your preference: On" : "Your preference: Off")
                    .font(.subheadline).accessibilityIdentifier("activity-alerts-preference")
                switch store.activityAlertPermission {
                case .notDetermined:
                    Label("iOS permission: Not requested", systemImage: "questionmark.circle")
                        .font(.subheadline).accessibilityIdentifier("activity-alerts-undetermined")
                case .denied:
                    Label("iOS permission: Not allowed", systemImage: "bell.slash")
                        .font(.subheadline).accessibilityIdentifier("activity-alerts-denied")
                    Text("Allow notifications in iOS Settings to receive alerts when your preference is on.")
                        .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent).frame(minHeight: 44)
                    .foregroundStyle(AppTheme.surface)
                    .accessibilityIdentifier("activity-alerts-settings")
                case .allowed:
                    Label("iOS permission: Allowed", systemImage: "checkmark.circle")
                        .font(.subheadline).accessibilityIdentifier("activity-alerts-allowed")
                }
                Text("Chore requests and family updates stay in Activity, even when alerts are off or you're offline.")
                    .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                if !BackgroundActivityDelivery.isEnabled {
                    Text("Open or refresh Earned It to receive family updates.")
                        .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
    }
}

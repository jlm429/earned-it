import SwiftUI
import UIKit

struct FamilyActivityView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var items: [FamilyActivity] {
        let pending = store.activity.filter { $0.punt?.status == .pending }
        let other = store.activity.filter { $0.punt?.status != .pending }
        return pending + other.prefix(50)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SectionCard(tint: AppTheme.info) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Stay in the loop", systemImage: "bell")
                                .font(.headline)
                            Text("Chore requests and family updates stay here, even when alerts are off or you're offline.")
                                .font(.subheadline)
                            if !BackgroundActivityDelivery.isEnabled {
                                Text("Open or refresh Earned It to receive family updates.")
                                    .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                            }
                            switch store.activityAlertPermission {
                            case .notDetermined:
                                Button("Enable Alerts") { Task { await store.requestActivityAlertPermission() } }
                                    .frame(minHeight: 44).accessibilityIdentifier("enable-activity-alerts")
                            case .denied:
                                Text("Alerts are off. You can enable them in iOS Settings.")
                                    .font(.footnote).accessibilityIdentifier("activity-alerts-denied")
                                Button("Open iOS Settings") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                }.frame(minHeight: 44)
                            case .allowed:
                                Label("Alerts enabled", systemImage: "checkmark.circle")
                                    .foregroundStyle(AppTheme.success)
                            }
                        }
                    }
                    if items.isEmpty {
                        ContentUnavailableView("You're all caught up", systemImage: "bubble.left.and.bubble.right",
                                               description: Text("New chore requests and family updates will appear here."))
                    }
                    ForEach(items) { item in
                        SectionCard(tint: item.punt?.status == .pending ? AppTheme.info : nil) {
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
                                if let punt = item.punt {
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
            .refreshable { do { try await store.synchronize() } catch { store.errorMessage = error.localizedDescription } }
            .task { await store.processActivityAlerts() }
            .accessibilityIdentifier("family-activity")
        }
        .tint(AppTheme.accent)
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
                    Button("Accept Punt") { decide(punt, kind: .accepted) }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44)
                        .foregroundStyle(AppTheme.surface)
                        .accessibilityIdentifier("accept-punt")
                    Button("Decline Punt") { decide(punt, kind: .declined) }
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

    private func decide(_ punt: ProjectedPunt, kind: PuntDecisionKind) {
        store.perform { try store.decidePunt(requestFactID: punt.id, kind: kind) }
    }
}

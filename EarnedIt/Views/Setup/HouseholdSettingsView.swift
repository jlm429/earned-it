import SwiftUI

struct HouseholdSettingsView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section("Family dates") {
                LabeledContent("Time zone", value: store.household?.timeZoneID ?? "Not set")
                Text("Lists and history always use this family timezone, even when a device travels.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("This Device") {
                SyncStatusView()
                Text(store.session.location == nil
                     ? "This family is saved only on this device. Invite a family member from Manage Family to begin sharing."
                     : "Disconnect removes this family from this device. Other family devices keep their data, and you can reconnect later.")
                Button(store.session.location == nil ? "Delete All Local Data" : "Disconnect This Device", role: .destructive) {
                    confirmingReset = true
                }
                .accessibilityIdentifier("clear-all-data")
            }
        }
        .refreshable { await refreshFamily() }
        .navigationTitle("Settings")
        .alert("Remove local family data?", isPresented: $confirmingReset) {
            Button("Remove Local Data", role: .destructive) { store.perform { try store.resetLocalData() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.session.location == nil
                 ? "This deletes the family saved on this device. This cannot be undone."
                 : "Other family devices keep their data. Any waiting changes must finish syncing first. You can reconnect later.")
        }
    }

    private func refreshFamily() async {
        do { try await store.synchronize() }
        catch { store.errorMessage = error.localizedDescription }
    }
}

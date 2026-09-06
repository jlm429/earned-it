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
            Section("This installation") {
                SyncStatusView()
                Text(store.session.location == nil
                     ? "This family is saved on this device. Connect iCloud from Family & Sharing to invite others."
                     : "Disconnect removes synced local data unless rejected changes need it as evidence. Reconnect to the same family to review retained changes. iCloud and other devices keep their data.")
                Button(store.session.location == nil ? "Delete All Local Data" : "Disconnect This Installation", role: .destructive) {
                    confirmingReset = true
                }
                .accessibilityIdentifier("clear-all-data")
            }
        }
        .navigationTitle("Settings")
        .alert("Remove local family data?", isPresented: $confirmingReset) {
            Button("Remove Local Data", role: .destructive) { store.perform { try store.resetLocalData() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.session.location == nil
                 ? "This deletes the family saved on this installation. This cannot be undone."
                 : "iCloud and other installations keep their data. Sync pending changes first. You can reconnect later.")
        }
    }
}

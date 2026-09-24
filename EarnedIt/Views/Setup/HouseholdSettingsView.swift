import SwiftUI

struct HouseholdSettingsView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var confirmingReset = false
    @State private var familyName = ""

    var body: some View {
        Form {
            if store.selectedMember?.role == .parent {
                Section("Family") {
                    TextField("Family name", text: $familyName)
                        .textContentType(.organizationName)
                        .accessibilityIdentifier("family-name")
                    Button("Save Family Name") { renameFamily() }
                        .disabled(familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || familyName.trimmingCharacters(in: .whitespacesAndNewlines)
                                == store.household?.name)
                        .accessibilityIdentifier("save-family-name")
                }
            }
            if store.household != nil {
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
                    if store.selectedMember?.role == .parent {
                        Button(store.session.location == nil ? "Delete All Local Data" : "Disconnect This Device", role: .destructive) {
                            confirmingReset = true
                        }
                        .disabled(store.isDeletingAllEarnedItData || store.session.pendingFamilyDeletion == true)
                        .accessibilityIdentifier("clear-all-data")
                    }
                }
            }
            Section("Delete All Data") {
                Text("This removes every Earned It family you own, your membership in shared families, account records, and local app data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                DeleteAllEarnedItDataButton()
                if store.isDeletingAllEarnedItData {
                    ProgressView("Deleting data…")
                }
            }
            Section("About") {
                LegalLinksView()
            }
        }
        .onAppear { familyName = store.household?.name ?? "" }
        .onChange(of: store.household?.name) { _, name in
            if let name { familyName = name }
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

    private func renameFamily() {
        store.perform { try store.renameFamily(familyName) }
        familyName = store.household?.name ?? familyName
    }
}

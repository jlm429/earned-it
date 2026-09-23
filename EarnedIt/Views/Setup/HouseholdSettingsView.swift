import SwiftUI

struct HouseholdSettingsView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var confirmingReset = false
    @State private var confirmingFamilyDeletion = false
    @State private var confirmingPermanentDeletion = false
    @State private var deletingFamily = false
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
                .disabled(deletingFamily || store.session.pendingFamilyDeletion == true)
                .accessibilityIdentifier("clear-all-data")
            }
            if store.canDeleteFamily {
                Section {
                    Text("Deleting the app or disconnecting this device does not delete your family from iCloud.")
                    Button("Delete Family and Cloud Data", role: .destructive) {
                        confirmingFamilyDeletion = true
                    }
                    .disabled(deletingFamily)
                    .accessibilityIdentifier("delete-family")
                    if deletingFamily { ProgressView("Deleting family…") }
                } header: {
                    Text("Delete Family")
                } footer: {
                    Text("Only the family creator can permanently delete the family for everyone.")
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
        .alert("Delete Family and Cloud Data?", isPresented: $confirmingFamilyDeletion) {
            Button("Continue", role: .destructive) { confirmingPermanentDeletion = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the family and its Earned It data from iCloud. Invited family members will lose access. This cannot be undone. Deleting the app alone does not do this.")
        }
        .alert("Permanently delete \"\(store.household?.name ?? "this family")\"?",
               isPresented: $confirmingPermanentDeletion) {
            Button("Delete Family", role: .destructive) { deleteFamily() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All family chores, history, invitations, and access will be permanently removed from iCloud.")
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

    private func deleteFamily() {
        deletingFamily = true
        Task {
            defer { deletingFamily = false }
            do { try await store.deleteFamily() }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}

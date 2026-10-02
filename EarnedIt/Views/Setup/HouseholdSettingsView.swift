import SwiftUI

struct HouseholdSettingsView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var confirmingDeletion = false
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
                         : "Family changes synchronize through the invited household in iCloud.")
                }
            }
            if store.canDeleteAllFamilyData {
                Section("Delete All Data") {
                    Text("Permanently deletes this entire family for everyone, including chores, profiles, completion history, invitations, memberships, cloud shares, and local data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Delete All Data", role: .destructive) {
                        confirmingDeletion = true
                    }
                    .disabled(deletingFamily || store.isDeletingAllEarnedItData
                        || store.session.pendingFamilyDeletion == true)
                    .accessibilityIdentifier("delete-all-data")
                    if deletingFamily { ProgressView("Deleting all data…") }
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
        .alert("Delete All Data?", isPresented: $confirmingDeletion) {
            Button("Delete All Data", role: .destructive) { deleteAllData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the entire family for everyone. All chores, profiles, completion history, invitations, memberships, cloud shares, and local data will be removed. This cannot be undone.")
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

    private func deleteAllData() {
        deletingFamily = true
        Task {
            defer { deletingFamily = false }
            do { try await store.deleteAllFamilyData() }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}

import SwiftUI

struct DeleteAllEarnedItDataButton: View {
    @Environment(HouseholdStore.self) private var store
    @State private var confirmingDeletion = false
    var title = "Delete All Earned It Data"

    var body: some View {
        Button(title, role: .destructive) {
            confirmingDeletion = true
        }
        .disabled(store.isDeletingAllEarnedItData)
        .accessibilityIdentifier("delete-all-earned-it-data")
        .alert("Delete All Earned It Data?", isPresented: $confirmingDeletion) {
            Button("Delete All Earned It Data", role: .destructive) {
                Task {
                    do { try await store.deleteAllEarnedItData() }
                    catch { store.errorMessage = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your Earned It family data, membership, invitations, and local app data from iCloud and this device. This cannot be undone.")
        }
    }
}

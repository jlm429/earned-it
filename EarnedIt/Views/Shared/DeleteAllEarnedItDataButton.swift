import SwiftUI

struct DeleteAllEarnedItDataButton: View {
    @Environment(HouseholdStore.self) private var store
    var title = "Delete All Earned It Data"

    var body: some View {
        ConfirmedDeleteAllEarnedItDataButton(
            title: title,
            isDeleting: store.isDeletingAllEarnedItData,
            action: { try await store.deleteAllEarnedItData() },
            onError: { store.errorMessage = $0.localizedDescription }
        )
    }
}

struct ConfirmedDeleteAllEarnedItDataButton: View {
    var title = "Delete All Earned It Data"
    let isDeleting: Bool
    let action: @MainActor () async throws -> Void
    let onError: @MainActor (Error) -> Void
    @State private var confirmingDeletion = false

    var body: some View {
        Button(title, role: .destructive) {
            confirmingDeletion = true
        }
        .disabled(isDeleting)
        .accessibilityIdentifier("delete-all-earned-it-data")
        .alert("Delete All Earned It Data?", isPresented: $confirmingDeletion) {
            Button("Delete All Earned It Data", role: .destructive) {
                Task {
                    do { try await action() }
                    catch { onError(error) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your Earned It family data, membership, invitations, and local app data from iCloud and this device. This cannot be undone.")
        }
    }
}

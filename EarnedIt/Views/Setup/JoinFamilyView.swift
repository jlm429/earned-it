import SwiftUI

struct JoinFamilyView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var invitation = ""
    @State private var families: [CloudFamily] = []
    @State private var busy = false
    @State private var searched = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Have an invitation?") {
                    Text("Open the iCloud invitation a parent sent you, or paste its link below. This connects to the existing family.")
                    TextField("iCloud invitation link", text: $invitation)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("invitation-link")
                    Button("Accept Invitation") {
                        run {
                            guard let url = URL(string: invitation.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw HouseholdError.invitation }
                            try await store.join(url: url)
                            dismiss()
                        }
                    }
                    .disabled(busy || invitation.isEmpty)
                    .accessibilityIdentifier("accept-invitation")
                }
                Section("Already connected to iCloud?") {
                    Button("Find Connected Families") {
                        run { families = try await store.discoverFamilies(); searched = true }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("find-families")
                    ForEach(families) { family in
                        Button(family.name) {
                            run { try await store.joinExisting(family.location); dismiss() }
                        }
                        .disabled(busy)
                    }
                    if searched && families.isEmpty {
                        Text("No connected families found. Ask a parent for an invitation.").foregroundStyle(.secondary)
                    }
                }
                if busy { ProgressView("Connecting to iCloud…") }
            }
            .navigationTitle("Join Existing Family")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Unable to Connect", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { errorMessage = error.localizedDescription }
        }
    }
}

import SwiftUI

struct FamilyUserFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HouseholdStore.self) private var store
    let role: UserRole
    let existing: FamilyMember?
    @State private var draftID = UUID()
    @State private var displayName: String
    @State private var avatar: AvatarOption
    @State private var errorMessage: String?

    init(role: UserRole, existing: FamilyMember? = nil) {
        self.role = role
        self.existing = existing
        _displayName = State(initialValue: existing?.displayName ?? "")
        _avatar = State(initialValue: existing?.avatar ?? (role == .parent ? .sun : .star))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(role.title) {
                    TextField("Display name", text: $displayName).textContentType(.name)
                        .accessibilityIdentifier("family-display-name")
                    Picker("Avatar", selection: $avatar) {
                        ForEach(AvatarOption.allCases) { option in Text(option.rawValue).tag(option) }
                    }
                    .pickerStyle(.inline)
                }
                Section {
                    Text(store.household?.isSetupComplete == true && existing == nil
                         ? "New members join the lists tomorrow. Today’s expectations and history stay intact."
                         : "Members can have a profile before they have a device. Cancel discards this unsaved form.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(existing == nil ? "Add \(role.title)" : "Edit Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try store.saveMember(id: existing?.id ?? draftID, name: displayName, role: role, avatar: avatar)
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || displayName.count > 50)
                    .accessibilityIdentifier("save-family-user")
                }
            }
            .alert("Unable to Save", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
        }
    }
}

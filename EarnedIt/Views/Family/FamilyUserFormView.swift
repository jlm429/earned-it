import SwiftData
import SwiftUI

struct FamilyUserFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let role: UserRole
    let existing: FamilyUser?

    @State private var draftID = UUID()
    @State private var displayName: String
    @State private var avatar: AvatarOption
    @State private var errorMessage: String?

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(role: UserRole, existing: FamilyUser? = nil) {
        self.role = role
        self.existing = existing
        _displayName = State(initialValue: existing?.displayName ?? "")
        _avatar = State(initialValue: existing?.avatar ?? (role == .parent ? .sun : .star))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(role.title) {
                    TextField("Display name", text: $displayName)
                        .textContentType(.name)
                        .accessibilityIdentifier("family-display-name")
                    if existing == nil {
                        Picker("Avatar", selection: $avatar) {
                            ForEach(AvatarOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.inline)
                        .accessibilityIdentifier("family-avatar")
                    }
                }
                Section {
                    Text("Use 1 to 50 characters. Saved family members stay on this device. Cancel discards this unsaved form.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(existing == nil ? "Add \(role.title)" : "Edit Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedName.isEmpty || trimmedName.count > 50)
                        .accessibilityIdentifier("save-family-user")
                }
            }
            .alert("Unable to Save", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
        }
    }

    private func save() {
        guard !trimmedName.isEmpty, trimmedName.count <= 50 else { return }
        do {
            try FamilyUserService.save(
                id: existing?.id ?? draftID,
                name: trimmedName,
                role: role,
                avatar: avatar,
                context: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

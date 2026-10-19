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
    @State private var savedChild: FamilyMember?

    init(role: UserRole, existing: FamilyMember? = nil) {
        self.role = role
        self.existing = existing
        _displayName = State(initialValue: existing?.displayName ?? "")
        _avatar = State(initialValue: existing?.avatar ?? (role == .parent ? .sun : .star))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let savedChild {
                    ChildConnectionStep(child: savedChild)
                } else {
                    memberForm
                }
            }
            .navigationTitle(savedChild == nil ? (existing == nil ? "Add \(role.title)" : "Edit Member") : "Connect a Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if savedChild == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            do {
                                let member = try store.saveMember(id: existing?.id ?? draftID, name: displayName, role: role, avatar: avatar)
                                if existing == nil && role == .child { savedChild = member }
                                else { dismiss() }
                            } catch { errorMessage = error.localizedDescription }
                        }
                        .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || displayName.count > 50)
                        .accessibilityIdentifier("save-family-user")
                    }
                }
            }
            .alert("Unable to Save", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
        }
    }

    private var memberForm: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Text(avatar.rawValue).font(.system(size: 44))
                        .frame(width: 72, height: 72)
                        .background(AppTheme.inset, in: RoundedRectangle(cornerRadius: 24))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName.isEmpty ? "Someone special" : displayName)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(role.title).foregroundStyle(AppTheme.secondaryText)
                    }
                }.padding(.vertical, 8)
            }
            Section(role.title) {
                TextField("Display name", text: $displayName).textContentType(.name)
                    .accessibilityIdentifier("family-display-name")
                Picker("Avatar", selection: $avatar) {
                    ForEach(AvatarOption.allCases) { option in Text(option.rawValue).tag(option) }
                }
                .pickerStyle(.inline)
            }
            Section {
                Text(existing == nil && role == .child
                     ? "New children join applicable all-children chores today. Earlier dates and existing completions stay intact."
                     : store.household?.isSetupComplete == true && existing == nil
                        ? "New parents can use their profiles from tomorrow."
                        : "Members can have a profile before they have a device. Cancel discards this unsaved form.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .themedListBackground()
    }
}

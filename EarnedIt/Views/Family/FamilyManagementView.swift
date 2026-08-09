import SwiftData
import SwiftUI

struct FamilyManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FamilyUser.createdAt) private var users: [FamilyUser]
    @Query private var responsibilities: [Responsibility]

    let parent: FamilyUser

    @State private var presentedForm: PresentedUserForm?
    @State private var removalMessage: String?
    @State private var errorMessage: String?

    private var parents: [FamilyUser] {
        users.filter { $0.role == .parent }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
    private var children: [FamilyUser] {
        users.filter { $0.role == .child }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        List {
            Section("Parents") {
                ForEach(parents) { user in
                    userRow(user)
                }
            }

            Section("Children") {
                ForEach(children) { user in
                    userRow(user)
                }
            }

            Section {
                Text("A user can be removed only when no active responsibility is assigned to or created by that person. Historical records remain local. The last parent cannot be removed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Family Management")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add Parent", systemImage: "person.badge.plus") {
                        presentedForm = .new(.parent)
                    }
                    Button("Add Child", systemImage: "figure.child.and.lock.open") {
                        presentedForm = .new(.child)
                    }
                } label: {
                    Label("Add Family Member", systemImage: "plus")
                }
                .accessibilityIdentifier("add-family-member")
            }
        }
        .sheet(item: $presentedForm) { presentation in
            FamilyUserFormView(role: presentation.role, existing: presentation.user)
        }
        .alert("Cannot Remove User", isPresented: Binding(
            get: { removalMessage != nil },
            set: { if !$0 { removalMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalMessage ?? "This user is still needed.")
        }
        .alert("Unable to Update", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .accessibilityIdentifier("family-management-screen")
    }

    private func userRow(_ user: FamilyUser) -> some View {
        HStack(spacing: 12) {
            AvatarView(user: user, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.headline)
                Text(user.role.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Edit Name", systemImage: "pencil") {
                    presentedForm = .edit(user)
                }
                Button("Remove", systemImage: "trash", role: .destructive) {
                    remove(user)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Manage \(user.displayName)")
            .accessibilityIdentifier("manage-user-\(user.displayName.accessibilitySlug)")
        }
        .padding(.vertical, 4)
    }

    private func remove(_ user: FamilyUser) {
        guard user.id != parent.id else {
            removalMessage = "Switch to another parent before removing the currently selected parent."
            return
        }
        guard PermissionService.canRemoveUser(user, allUsers: users, responsibilities: responsibilities) else {
            removalMessage = "Archive or reassign every active responsibility connected to this user first. At least one parent must remain."
            return
        }
        do {
            modelContext.delete(user)
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum PresentedUserForm: Identifiable {
    case new(UserRole)
    case edit(FamilyUser)

    var id: String {
        switch self {
        case .new(let role): "new-\(role.rawValue)"
        case .edit(let user): user.id.uuidString
        }
    }

    var role: UserRole {
        switch self {
        case .new(let role): role
        case .edit(let user): user.role
        }
    }

    var user: FamilyUser? {
        if case .edit(let user) = self { return user }
        return nil
    }
}

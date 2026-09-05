import SwiftData
import SwiftUI

struct UserSelectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FamilyUser.createdAt) private var users: [FamilyUser]

    @State private var addingParent = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    private var displayUsers: [FamilyUser] {
        users.sorted {
            if $0.role != $1.role { return $0.role == .parent }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 6) {
                        Text("Who’s using Earned It?")
                            .font(.title.bold())
                            .multilineTextAlignment(.center)
                        Text("Allowance Tracker")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(displayUsers) { user in
                            Button {
                                select(user)
                            } label: {
                                VStack(spacing: 10) {
                                    AvatarView(user: user, size: 72)
                                    Text(user.displayName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.center)
                                    Text(user.role.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(18)
                                .frame(maxWidth: .infinity, minHeight: 154)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Continue as \(user.displayName), \(user.role.title)")
                            .accessibilityIdentifier("user-card-\(user.displayName.accessibilitySlug)")
                        }
                    }

                    if users.isEmpty {
                        ContentUnavailableView("No family members yet", systemImage: "person.2",
                            description: Text("Add a parent to start managing your family, or resume setup in Settings."))
                    }
                    if !users.contains(where: { $0.role == .parent }) {
                        Button("Add Parent") { addingParent = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("add-parent")
                    }
                    NavigationLink {
                        HouseholdSettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("household-settings")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .sheet(isPresented: $addingParent) {
                FamilyUserFormView(role: .parent)
            }
            .alert("Unable to Update Data", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
        }
    }

    private func select(_ user: FamilyUser) {
        do {
            try DataCoordinator.prepareDailyData(context: modelContext)
            try SettingsStore.set(user.id.uuidString, for: SettingsStore.selectedUserIDKey, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

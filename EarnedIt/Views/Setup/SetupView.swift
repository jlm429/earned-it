import SwiftUI

struct SetupView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var creatingFamily = false
    @State private var joiningFamily = false
    @State private var addingChild = false
    @State private var familyName = ""
    @State private var parentName = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if store.household == nil {
                    Section {
                        VStack(alignment: .leading, spacing: 18) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 44, weight: .medium))
                                .foregroundStyle(AppTheme.heroSecondary)
                                .accessibilityHidden(true)
                            Text("Earned It")
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                .foregroundStyle(AppTheme.heroText)
                            Text("Little things.\nLasting habits.")
                                .font(.system(.title, design: .rounded, weight: .semibold))
                                .foregroundStyle(AppTheme.heroText)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("A calmer chore routine. A shared sense of progress. A little pride in a job well done.")
                                .foregroundStyle(AppTheme.heroSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HeroSurface())
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                    if creatingFamily {
                        Section {
                            TextField("Family name", text: $familyName)
                                .accessibilityIdentifier("family-name")
                            TextField("Your name", text: $parentName)
                                .textContentType(.name)
                                .accessibilityIdentifier("parent-name")
                            Text("You’ll start as a parent. Add children next, even if they don’t have a device.")
                                .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                            Button("Create Family") {
                                do { try store.createFamily(name: familyName, parentName: parentName) }
                                catch { errorMessage = error.localizedDescription }
                            }
                            .disabled(familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("save-family")
                            Button("Cancel", role: .cancel) { creatingFamily = false }
                        } header: { Text("Create your family") } footer: {
                            Text("Family dates use \(TimeZone.current.identifier). This stays the same when a device travels.")
                        }
                    } else {
                        Section("How would you like to begin?") {
                            Button { creatingFamily = true } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Create a New Family")
                                        Text("I’m the first parent setting up this family")
                                            .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                                    }
                                } icon: { Image(systemName: "house.fill") }
                            }
                                .accessibilityIdentifier("create-family")
                            Button { joiningFamily = true } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Join an Existing Family")
                                        Text("I have a parent-issued invitation")
                                            .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                                    }
                                } icon: { Image(systemName: "person.2.badge.key") }
                            }
                                .accessibilityIdentifier("join-family")
                        }
                    }
                    Section {
                        Label("One shared family. Each child joins with an invitation for their own profile.",
                              systemImage: "lock.shield")
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    Section("About") {
                        LegalLinksView()
                    }
                } else {
                    Section("Your family") {
                        Label("A good start, together", systemImage: "sparkles")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(AppTheme.accent)
                        Text(store.household?.name ?? "Family").font(.headline)
                        ForEach(store.snapshot.members) { member in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 12) {
                                    AvatarView(user: member, size: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(member.displayName).font(.headline)
                                        Text(member.role.title).font(.caption).foregroundStyle(AppTheme.secondaryText)
                                    }
                                }
                                .accessibilityIdentifier("setup-user-\(member.displayName.accessibilitySlug)")
                                if member.role == .child { ChildConnectionRow(child: member) }
                            }
                        }
                        Button("Add Child") { addingChild = true }
                            .accessibilityIdentifier("setup-add-child")
                    }
                    Section("Add your first chores") {
                        Text("You can add a few repeating chores now or do this later.")
                        NavigationLink("Add Chores") { WeekdayListsView() }
                            .disabled(store.children.isEmpty)
                            .accessibilityIdentifier("setup-weekday-lists")
                    }
                    Section("Progress & allowance") {
                        Text("Each child earns credit for their own required chores. Parents can set a weekly allowance amount after setup.")
                    }
                    Section {
                        Button("Finish Setup") { store.perform { try store.finishSetup() } }
                            .disabled(store.children.isEmpty)
                            .accessibilityIdentifier("finish-setup")
                    } footer: {
                        Text("Children marked Not connected yet can join later from Manage Family. Their chores are ready now.")
                    }
                    Section("About") {
                        LegalLinksView()
                    }
                }
            }
            .themedListBackground()
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(store.household == nil ? "Welcome" : "Family Setup")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        HouseholdSettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("welcome-settings")
                }
            }
            .sheet(isPresented: $joiningFamily) { JoinFamilyView() }
            .sheet(isPresented: $addingChild) { FamilyUserFormView(role: .child) }
            .alert("Unable to Create Family", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
            .accessibilityIdentifier("setup-screen")
        }
    }
}

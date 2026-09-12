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
                        Text("Earned It").font(.largeTitle.bold())
                        Text("One family. The right view for everyone.")
                            .font(.title3)
                        Text("Parents manage the shared week. Children see and complete only the work connected to their invited profile.")
                            .foregroundStyle(.secondary)
                    }
                    if creatingFamily {
                        Section {
                            TextField("Family name", text: $familyName)
                                .accessibilityIdentifier("family-name")
                            TextField("Your name", text: $parentName)
                                .textContentType(.name)
                                .accessibilityIdentifier("parent-name")
                            Text("You’ll start as a parent. Add children next, even if they don’t have a device.")
                                .font(.footnote).foregroundStyle(.secondary)
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
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: "house.fill") }
                            }
                                .accessibilityIdentifier("create-family")
                            Button { joiningFamily = true } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Join an Existing Family")
                                        Text("I have a parent-issued invitation")
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: "person.2.badge.key") }
                            }
                                .accessibilityIdentifier("join-family")
                        }
                    }
                    Section {
                        Label("Joining never creates a second copy of a family or lets a device choose its own authority.",
                              systemImage: "lock.shield")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Your family") {
                        Text(store.household?.name ?? "Family").font(.title2.bold())
                        ForEach(store.snapshot.members) { member in
                            Label("\(member.displayName) · \(member.role.title)", systemImage: "checkmark.circle")
                                .accessibilityIdentifier("setup-user-\(member.displayName.accessibilitySlug)")
                        }
                        Button("Add Child") { addingChild = true }
                            .accessibilityIdentifier("setup-add-child")
                    }
                    Section("One shared list for each weekday") {
                        Text("Choose who is needed for each chore. Each weekday’s list repeats; completions belong only to that date.")
                        NavigationLink("Configure Weekday Lists") { WeekdayListsView() }
                            .disabled(store.children.isEmpty)
                            .accessibilityIdentifier("setup-weekday-lists")
                        Text("You can add chores later.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Progress & allowance") {
                        Text("Each child earns credit for their own work. Required chores count toward their week. Any-one chores are optional contributions, so another child’s work never counts as yours.")
                        Text("Every required item must be accounted for to earn allowance after Sunday. Excused days are left out. Parents can set a weekly amount for each child. This tracks eligibility, never payments.")
                    }
                    Section {
                        Button("Start Our Week") { store.perform { try store.finishSetup() } }
                            .disabled(store.children.isEmpty)
                            .accessibilityIdentifier("finish-setup")
                    } footer: {
                        Text("Saved members and chores stay if you close the app. Parents can invite devices from Family & Sharing.")
                    }
                }
            }
            .navigationTitle(store.household == nil ? "Welcome" : "Family Setup")
            .sheet(isPresented: $joiningFamily) { JoinFamilyView() }
            .sheet(isPresented: $addingChild) { FamilyUserFormView(role: .child) }
            .alert("Unable to Create Family", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
            .accessibilityIdentifier("setup-screen")
        }
    }
}

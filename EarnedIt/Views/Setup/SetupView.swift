import SwiftData
import SwiftUI

struct SetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FamilyUser.createdAt) private var users: [FamilyUser]
    @Query private var settings: [AppSetting]
    @Query private var responsibilities: [Responsibility]
    @State private var addingRole: UserRole?
    @State private var addingChore = false
    @State private var confirmingSkip = false
    @State private var errorMessage: String?

    private var stage: SetupStage { OnboardingService.stage(in: settings) }
    private var parent: FamilyUser? { users.first { $0.role == .parent } }
    private var children: [FamilyUser] { users.filter { $0.role == .child } }
    private var canContinue: Bool {
        switch stage {
        case .parent: parent != nil
        case .children, .guide: parent != nil && !children.isEmpty
        default: true
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Step \((SetupStage.allCases.firstIndex(of: stage) ?? 0) + 1) of 5")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    stageContent
                }
                Section {
                    Button(stage == .guide ? "Finish Setup" : "Continue") { advance() }
                        .disabled(!canContinue)
                        .accessibilityIdentifier("setup-continue")
                    if stage != .welcome {
                        Button("Back") { move(-1) }
                            .accessibilityIdentifier("setup-back")
                    }
                    Button("Skip Setup for Now") { confirmingSkip = true }
                        .accessibilityIdentifier("setup-skip")
                } footer: {
                    Text("Saved people and chores are kept when you go back or leave setup. You can resume from Settings after switching users.")
                }
            }
            .navigationTitle(stage.title)
            .sheet(item: $addingRole) { role in
                FamilyUserFormView(role: role)
            }
            .sheet(isPresented: $addingChore) {
                if let parent {
                    ResponsibilityFormView(actor: parent, children: children)
                }
            }
            .alert("Skip setup for now?", isPresented: $confirmingSkip) {
                Button("Skip Setup") { perform { try OnboardingService.finish(skipping: true, context: modelContext) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saved data stays. Resume setup later in Settings.")
            }
            .alert("Unable to Save", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
            .accessibilityIdentifier("setup-screen")
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch stage {
        case .welcome:
            Text("Earned It")
                .font(.largeTitle.bold())
            Text("Build daily habits together and see weekly progress toward allowance. Everything stays on this device.")
            Text("Add a parent and at least one child to finish setup. Chores are optional and can be added later.")
        case .parent:
            Text("A parent manages the family, assigns chores, and reviews progress. Profiles are shared on this device without passwords.")
            savedUsers(users.filter { $0.role == .parent })
            Button("Add Parent") { addingRole = .parent }
                .accessibilityIdentifier("setup-add-parent")
        case .children:
            Text("Add one or more children. Each child has their own daily list and weekly progress.")
            savedUsers(children)
            Button("Add Child") { addingRole = .child }
                .accessibilityIdentifier("setup-add-child")
        case .chores:
            Text("Optional: add a chore and choose its child. Active responsibilities are expected each day. Parents can edit or archive them from a child’s dashboard.")
            ForEach(responsibilities.filter(\.isActive)) { item in
                VStack(alignment: .leading) {
                    Text(item.title)
                    Text(users.first { $0.id == item.assignedChildID }?.displayName ?? "Child unavailable")
                        .foregroundStyle(.secondary)
                }
            }
            Button("Add Chore") { addingChore = true }
                .disabled(parent == nil || children.isEmpty)
                .accessibilityIdentifier("setup-add-chore")
            Text("Allowance follows the existing Monday to Sunday rule: at least 85% of expected items accounted for earns allowance after the week ends. Agree on the amount together outside the app.")
            Text("Continue without adding chores to set them up later.")
                .foregroundStyle(.secondary)
        case .guide:
            Label("Children complete their daily list", systemImage: "checkmark.circle")
                .font(.headline)
            Text("Switch User to open a child’s profile. Children mark today’s items Done or Not Needed Today; both count equally. They can also add and manage their own chores.")
            Label("Parents review progress", systemImage: "person.crop.circle.badge.checkmark")
                .font(.headline)
            Text("Open a child from the parent dashboard to review or correct daily entries and excuse a day. Completion counts immediately; there is no separate approval queue.")
            Label("The week determines allowance", systemImage: "calendar")
                .font(.headline)
            Text("Unmarked items become Missed after the day ends. Excused days and days with no chores are neutral. Weekly Summary shows progress; children see the allowance result after the week ends.")
        }
    }

    private func savedUsers(_ people: [FamilyUser]) -> some View {
        ForEach(people) { user in
            Label(user.displayName, systemImage: "checkmark.circle")
                .accessibilityLabel("Saved \(user.role.title): \(user.displayName)")
                .accessibilityIdentifier("setup-user-\(user.displayName.accessibilitySlug)")
        }
    }

    private func advance() {
        if stage == .guide {
            perform { try OnboardingService.finish(context: modelContext) }
        } else {
            move(1)
        }
    }

    private func move(_ offset: Int) {
        let stages = SetupStage.allCases
        guard let index = stages.firstIndex(of: stage), stages.indices.contains(index + offset) else { return }
        perform { try OnboardingService.move(to: stages[index + offset], context: modelContext) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

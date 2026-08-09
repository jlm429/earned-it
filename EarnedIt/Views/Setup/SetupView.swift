import SwiftData
import SwiftUI

struct SetupView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var drafts = [
        SetupUserDraft(role: .parent, avatar: .sun),
        SetupUserDraft(role: .child, avatar: .star)
    ]
    @State private var errorMessage: String?

    private var canFinish: Bool {
        drafts.contains { $0.role == .parent && !$0.trimmedName.isEmpty }
            && drafts.contains { $0.role == .child && !$0.trimmedName.isEmpty }
            && drafts.allSatisfy { !$0.trimmedName.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Earned It")
                            .font(.largeTitle.bold())
                        Text("Allowance Tracker")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("Set up the people who will use this iPhone. Everything stays on this device.")
                            .font(.body)
                            .padding(.top, 4)
                    }
                    .padding(.vertical, 8)
                }

                Section("Your Family") {
                    ForEach($drafts) { $draft in
                        SetupUserRow(draft: $draft)
                    }
                    .onDelete { offsets in
                        drafts.remove(atOffsets: offsets)
                    }

                    HStack {
                        Button {
                            drafts.append(SetupUserDraft(role: .parent, avatar: .sun))
                        } label: {
                            Label("Add Parent", systemImage: "person.badge.plus")
                        }
                        Spacer()
                        Button {
                            drafts.append(SetupUserDraft(role: .child, avatar: .star))
                        } label: {
                            Label("Add Child", systemImage: "figure.child.and.lock.open")
                        }
                    }
                }

                Section {
                    Button("Finish Family Setup") {
                        finishSetup()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(!canFinish)
                    .accessibilityIdentifier("finish-setup")
                } footer: {
                    Text("You can add or update family members later from a parent dashboard.")
                }

                Section("Development Only") {
                    Button("Load Generic Sample Data") {
                        loadSampleData()
                    }
                    .accessibilityIdentifier("load-sample-data")
                    Text("Replaces local data with Parent, Child One, and Child Two. Sample data is never loaded automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Welcome")
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

    private func finishSetup() {
        guard canFinish else { return }
        do {
            for draft in drafts {
                modelContext.insert(FamilyUser(
                    id: draft.id,
                    displayName: draft.trimmedName,
                    role: draft.role,
                    avatar: draft.avatar
                ))
            }
            try modelContext.save()
            try SettingsStore.set("normal", for: SettingsStore.dataModeKey, context: modelContext)
            try SettingsStore.set("true", for: SettingsStore.setupCompleteKey, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSampleData() {
        do {
            try SampleDataService.seed(context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SetupUserDraft: Identifiable {
    let id = UUID()
    var name = ""
    var role: UserRole
    var avatar: AvatarOption

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct SetupUserRow: View {
    @Binding var draft: SetupUserDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(draft.avatar.rawValue)
                    .font(.title)
                    .accessibilityHidden(true)
                TextField("Display name", text: $draft.name)
                    .textContentType(.name)
                    .accessibilityIdentifier("setup-name-\(draft.id.uuidString)")
            }
            HStack {
                Picker("Role", selection: $draft.role) {
                    ForEach(UserRole.allCases) { role in
                        Text(role.title).tag(role)
                    }
                }
                Picker("Avatar", selection: $draft.avatar) {
                    ForEach(AvatarOption.allCases) { avatar in
                        Text(avatar.rawValue).tag(avatar)
                    }
                }
                .accessibilityLabel("Avatar")
            }
        }
        .padding(.vertical, 4)
    }
}

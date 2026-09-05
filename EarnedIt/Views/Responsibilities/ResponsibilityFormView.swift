import SwiftData
import SwiftUI

struct ResponsibilityFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let actor: FamilyUser
    let children: [FamilyUser]
    let existing: Responsibility?

    @State private var title: String
    @State private var notes: String
    @State private var category: ResponsibilityCategory
    @State private var assignedChildID: UUID
    @State private var errorMessage: String?
    @State private var draftID = UUID()

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var availableChildren: [FamilyUser] {
        actor.role == .child ? children.filter { $0.id == actor.id } : children
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty
            && trimmedTitle.count <= 80
            && notes.count <= 300
            && availableChildren.contains { $0.id == assignedChildID }
    }

    init(actor: FamilyUser, children: [FamilyUser], preferredChildID: UUID? = nil, existing: Responsibility? = nil) {
        self.actor = actor
        self.children = children
        self.existing = existing
        _title = State(initialValue: existing?.title ?? "")
        _notes = State(initialValue: existing?.notes ?? "")
        _category = State(initialValue: existing?.category ?? .home)
        let initialChild = existing?.assignedChildID
            ?? preferredChildID
            ?? (actor.role == .child ? actor.id : children.first?.id)
            ?? UUID()
        _assignedChildID = State(initialValue: initialChild)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Responsibility") {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("responsibility-title")
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("responsibility-notes")
                    Picker("Category", selection: $category) {
                        ForEach(ResponsibilityCategory.allCases) { category in
                            Label(category.rawValue, systemImage: category.symbolName)
                                .tag(category)
                        }
                    }
                    .accessibilityIdentifier("responsibility-category")
                }

                Section("Assigned Child") {
                    if availableChildren.isEmpty {
                        Text("Add a child in Family Management before assigning a chore.")
                    } else if existing != nil && actor.role == .parent {
                        Picker("Child", selection: $assignedChildID) {
                            ForEach(availableChildren) { child in
                                Text(child.displayName).tag(child.id)
                            }
                        }
                        .accessibilityIdentifier("assigned-child")
                        Text("Reassignment starts a new responsibility and keeps the previous child’s history.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if actor.role == .child {
                        LabeledContent("Child", value: actor.displayName)
                    } else {
                        Picker("Child", selection: $assignedChildID) {
                            ForEach(availableChildren) { child in
                                Text(child.displayName).tag(child.id)
                            }
                        }
                        .accessibilityIdentifier("assigned-child")
                    }
                }

                if trimmedTitle.count > 80 || notes.count > 300 {
                    Section {
                        Text("Use up to 80 characters for the title and 300 for notes.")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Responsibility" : "Edit Responsibility")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("cancel-responsibility")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("save-responsibility")
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
        guard canSave, PermissionService.canAssign(user: actor, childID: assignedChildID) else { return }
        do {
            var didReassign = false
            if let existing {
                guard PermissionService.canManageDefinition(user: actor, responsibility: existing) else { return }
                let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if existing.assignedChildID != assignedChildID {
                    try DataCoordinator.reassign(
                        existing,
                        to: assignedChildID,
                        actor: actor,
                        title: trimmedTitle,
                        notes: trimmedNotes,
                        category: category,
                        context: modelContext
                    )
                    didReassign = true
                } else {
                    existing.title = trimmedTitle
                    existing.notes = trimmedNotes
                    existing.category = category
                }
            } else {
                let saved = try modelContext.fetch(FetchDescriptor<Responsibility>())
                if !saved.contains(where: { $0.id == draftID }) {
                    modelContext.insert(Responsibility(
                        id: draftID,
                        title: trimmedTitle,
                        notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                        category: category,
                        creatorID: actor.id,
                        creatorRole: actor.role,
                        assignedChildID: assignedChildID
                    ))
                }
            }
            if !didReassign {
                try modelContext.save()
                try DataCoordinator.prepareDailyData(context: modelContext)
            }
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

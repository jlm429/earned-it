import SwiftUI

struct ResponsibilityFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HouseholdStore.self) private var store
    let existing: ChoreRevision?
    @State private var choreID: UUID
    @State private var weekday: Weekday
    @State private var title: String
    @State private var notes: String
    @State private var category: ResponsibilityCategory
    @State private var mode: RequirementMode
    @State private var memberIDs: Set<UUID>
    @State private var errorMessage: String?

    init(weekday: Weekday, existing: ChoreRevision? = nil) {
        self.existing = existing
        _choreID = State(initialValue: existing?.choreID ?? UUID())
        _weekday = State(initialValue: existing?.weekday ?? weekday)
        _title = State(initialValue: existing?.title ?? "")
        _notes = State(initialValue: existing?.notes ?? "")
        _category = State(initialValue: existing?.category ?? .home)
        _mode = State(initialValue: existing?.mode ?? .all)
        _memberIDs = State(initialValue: Set(existing?.memberIDs ?? []))
    }

    private var eligibleChildren: [FamilyMember] { store.eligibleChildren(choreID: choreID) }
    private var eligibleIDs: Set<UUID> { Set(eligibleChildren.map(\.id)) }
    private var selectedIDs: Set<UUID> { memberIDs.intersection(eligibleIDs) }
    private var displayedModes: [RequirementMode] {
        RequirementMode.assignmentChoices.contains(mode)
            ? RequirementMode.assignmentChoices : [mode] + RequirementMode.assignmentChoices
    }
    private var selectedChildrenInTurnOrder: [FamilyMember] {
        let byID = Dictionary(uniqueKeysWithValues: eligibleChildren.map { ($0.id, $0) })
        let existingOrder = existing?.memberIDs.compactMap { selectedIDs.contains($0) ? byID[$0] : nil } ?? []
        let existingIDs = Set(existingOrder.map(\.id))
        return existingOrder + eligibleChildren.filter { selectedIDs.contains($0.id) && !existingIDs.contains($0.id) }
    }
    private var canSaveAssignment: Bool {
        switch mode {
        case .all: !eligibleChildren.isEmpty
        case .particular: selectedIDs.count == 1
        case .alternating, .multiple: selectedIDs.count >= 2
        case .anyOne: !selectedIDs.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Chore") {
                    TextField("Title", text: $title).accessibilityIdentifier("responsibility-title")
                    TextField("Notes (optional)", text: $notes, axis: .vertical).lineLimit(2...5)
                    Picker("Weekday", selection: $weekday) {
                        ForEach(Weekday.allCases) { day in Text(day.title).tag(day) }
                    }.accessibilityIdentifier("chore-weekday")
                    Picker("Category", selection: $category) {
                        ForEach(ResponsibilityCategory.allCases) { category in
                            Label(category.rawValue, systemImage: category.symbolName).tag(category)
                        }
                    }
                }
                Section("Who is needed?") {
                    Picker("Requirement", selection: $mode) {
                        ForEach(displayedModes) { mode in Text(mode.title).tag(mode) }
                    }.accessibilityIdentifier("chore-requirement")
                    if mode == .all {
                        Text("Every child on this family’s list for that date completes it independently.")
                    } else {
                        ForEach(eligibleChildren) { member in
                            Toggle(member.displayName, isOn: Binding(
                                get: { memberIDs.contains(member.id) },
                                set: {
                                    if $0 {
                                        if mode == .particular { memberIDs = [member.id] } else { memberIDs.insert(member.id) }
                                    } else { memberIDs.remove(member.id) }
                                }
                            ))
                            .accessibilityIdentifier("eligible-\(member.displayName.accessibilitySlug)")
                        }
                    }
                    if mode == .alternating {
                        Text(alternatingHelp)
                            .font(.footnote).foregroundStyle(.primary.opacity(0.7))
                            .accessibilityIdentifier("alternating-turn-order")
                    } else if mode == .anyOne {
                        Text("Any eligible child can finish this chore. Only their own contribution earns credit; others receive no credit or penalty.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text(existing == nil
                         ? "Repeats on \(weekday.title)s, starting today. Each date starts with no completions."
                         : "Changes start tomorrow. Today’s assignment and all dated completions are kept.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(existing == nil ? "New Chore" : "Edit Chore")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: mode) { _, mode in
                if mode == .particular {
                    memberIDs = selectedChildrenInTurnOrder.first.map { Set([$0.id]) } ?? []
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("cancel-responsibility")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try store.saveChore(choreID: choreID, weekday: weekday, title: title, notes: notes,
                                                category: category, mode: mode, memberIDs: Array(selectedIDs))
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 80
                              || notes.count > 300 || !canSaveAssignment)
                    .accessibilityIdentifier("save-responsibility")
                }
            }
            .alert("Unable to Save", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
        }
    }

    private var alternatingHelp: String {
        let names = selectedChildrenInTurnOrder.map(\.displayName)
        if names.count < 2 { return "Choose at least two children. One child owns each date." }
        return "Turn order: \(names.joined(separator: ", ")). It advances with each scheduled date, even when a turn is not completed."
    }
}

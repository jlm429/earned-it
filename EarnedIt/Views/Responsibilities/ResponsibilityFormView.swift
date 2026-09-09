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
    @State private var selectedMode: RequirementMode?
    @State private var memberIDs: Set<UUID>
    @State private var errorMessage: String?

    init(weekday: Weekday, existing: ChoreRevision? = nil) {
        self.existing = existing
        _choreID = State(initialValue: existing?.choreID ?? UUID())
        _weekday = State(initialValue: existing?.weekday ?? weekday)
        _title = State(initialValue: existing?.title ?? "")
        _notes = State(initialValue: existing?.notes ?? "")
        _category = State(initialValue: existing?.category ?? .home)
        let initialMode = existing?.mode ?? .all
        _selectedMode = State(initialValue: RequirementMode.assignmentChoices.contains(initialMode) ? initialMode : nil)
        _memberIDs = State(initialValue: Set(existing?.memberIDs ?? []))
    }

    private var eligibleChildren: [FamilyMember] { store.eligibleChildren(choreID: choreID) }
    private var eligibleIDs: Set<UUID> { Set(eligibleChildren.map(\.id)) }
    private var selectedIDs: Set<UUID> { memberIDs.intersection(eligibleIDs) }
    private var legacyConfiguration: ChoreRevision? {
        guard selectedMode == nil else { return nil }
        let assignmentDay = store.choreAssignmentDay(choreID: choreID)
        let configuration = store.snapshot.configuration(choreID: choreID, on: assignmentDay) ?? existing
        guard let configuration, !RequirementMode.assignmentChoices.contains(configuration.mode) else { return nil }
        return configuration
    }
    private var selectedChildrenInTurnOrder: [FamilyMember] {
        store.orderedEligibleChildren(choreID: choreID, selectedMemberIDs: selectedIDs)
    }
    private var canSaveAssignment: Bool {
        guard let selectedMode else { return legacyConfiguration != nil }
        switch selectedMode {
        case .all: return !eligibleChildren.isEmpty
        case .particular: return selectedIDs.count == 1
        case .alternating, .multiple: return selectedIDs.count >= 2
        case .anyOne: return !selectedIDs.isEmpty
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
                    if let legacyConfiguration {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current compatibility assignment").font(.subheadline.weight(.semibold))
                            Text(legacyAssignmentSummary(legacyConfiguration)).font(.footnote)
                            Text("Choose a requirement below to convert this assignment.").font(.footnote)
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("legacy-assignment-context")
                    }
                    Picker("Requirement", selection: $selectedMode) {
                        ForEach(RequirementMode.assignmentChoices) { mode in
                            Text(mode.title).tag(Optional(mode))
                        }
                    }.accessibilityIdentifier("chore-requirement")
                    if selectedMode == .all {
                        Text("Every child on this family’s list for that date completes it independently.")
                    } else if let selectedMode {
                        ForEach(eligibleChildren) { member in
                            Toggle(member.displayName, isOn: Binding(
                                get: { memberIDs.contains(member.id) },
                                set: {
                                    if $0 {
                                        if selectedMode == .particular { memberIDs = [member.id] } else { memberIDs.insert(member.id) }
                                    } else { memberIDs.remove(member.id) }
                                }
                            ))
                            .accessibilityIdentifier("eligible-\(member.displayName.accessibilitySlug)")
                        }
                    }
                    if selectedMode == .alternating {
                        Text(alternatingHelp)
                            .font(.footnote).foregroundStyle(.primary.opacity(0.7))
                            .accessibilityIdentifier("alternating-turn-order")
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
            .onChange(of: selectedMode) { _, mode in
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
                            let assignment = try assignmentToSave()
                            try store.saveChore(choreID: choreID, weekday: weekday, title: title, notes: notes,
                                                category: category, mode: assignment.mode,
                                                memberIDs: assignment.memberIDs)
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

    private func assignmentToSave() throws -> (mode: RequirementMode, memberIDs: [UUID]) {
        if let selectedMode { return (selectedMode, Array(selectedIDs)) }
        guard let legacyConfiguration else { throw HouseholdError.invalidAssignment }
        return (legacyConfiguration.mode, legacyConfiguration.memberIDs)
    }

    private func legacyAssignmentSummary(_ configuration: ChoreRevision) -> String {
        let names = configuration.memberIDs.compactMap { store.snapshot.member($0)?.displayName }
        return names.isEmpty ? configuration.mode.title
            : "\(configuration.mode.title): \(names.joined(separator: ", "))"
    }
}

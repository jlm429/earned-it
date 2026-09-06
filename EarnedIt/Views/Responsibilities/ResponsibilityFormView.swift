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
                        ForEach(RequirementMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }.accessibilityIdentifier("chore-requirement")
                    if mode == .all {
                        Text("Every child on this family’s list for that date completes it independently.")
                    } else {
                        ForEach(store.eligibleChildren(choreID: choreID)) { member in
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
                    if mode == .anyOne {
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
                if mode == .particular { memberIDs = Set(memberIDs.prefix(1)) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("cancel-responsibility")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try store.saveChore(choreID: choreID, weekday: weekday, title: title, notes: notes,
                                                category: category, mode: mode, memberIDs: Array(memberIDs))
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 80 || notes.count > 300)
                    .accessibilityIdentifier("save-responsibility")
                }
            }
            .alert("Unable to Save", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
        }
    }
}

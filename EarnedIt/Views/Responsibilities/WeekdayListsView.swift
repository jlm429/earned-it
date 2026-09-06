import SwiftUI

struct WeekdayListsView: View {
    @Environment(HouseholdStore.self) private var store
    var body: some View {
        List {
            Section {
                ForEach(store.household?.weekdayLists ?? []) { list in
                    NavigationLink(list.weekday.title) { WeekdayConfigurationView(weekday: list.weekday) }
                        .accessibilityIdentifier("weekday-\(list.weekday.rawValue)")
                }
            } footer: {
                Text("One shared recurring list per weekday. Completions are kept by date and person.")
            }
        }
        .navigationTitle("Weekday Lists")
        .accessibilityIdentifier("weekday-lists")
    }
}

private struct WeekdayConfigurationView: View {
    @Environment(HouseholdStore.self) private var store
    let weekday: Weekday
    @State private var addingChore = false
    @State private var editing: ChoreRevision?
    @State private var archiving: ChoreRevision?

    private var chores: [ChoreRevision] {
        Set(store.snapshot.revisions.map(\.choreID)).compactMap {
            store.snapshot.configuration(choreID: $0, on: store.tomorrow)
        }.filter { $0.weekday == weekday && !$0.isArchived }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                ForEach(chores) { chore in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(chore.title).font(.headline)
                        Text(chore.mode.title).font(.subheadline).foregroundStyle(.secondary)
                        if chore.effectiveDay > store.day {
                            Text("Starts tomorrow").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Edit") { editing = chore }.buttonStyle(.bordered)
                            Button("Archive", role: .destructive) { archiving = chore }.buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if chores.isEmpty { Text("No chores configured yet.").foregroundStyle(.secondary) }
                Button("Add Chore", systemImage: "plus") { addingChore = true }
                    .accessibilityIdentifier("add-responsibility")
            } footer: {
                Text("This list repeats every \(weekday.title). Edits and archives apply from tomorrow, preserving today’s history.")
            }
        }
        .navigationTitle(weekday.title)
        .sheet(isPresented: $addingChore) { ResponsibilityFormView(weekday: weekday) }
        .sheet(item: $editing) { chore in ResponsibilityFormView(weekday: weekday, existing: chore) }
        .alert("Archive this chore?", isPresented: Binding(
            get: { archiving != nil }, set: { if !$0 { archiving = nil } }
        )) {
            Button("Archive from Tomorrow", role: .destructive) {
                if let chore = archiving { store.perform { try store.archiveChore(chore.choreID) } }
                archiving = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Today’s list and past completions stay available.") }
    }
}

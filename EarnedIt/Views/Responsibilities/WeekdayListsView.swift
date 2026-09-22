import SwiftUI

struct WeekdayListsView: View {
    @Environment(HouseholdStore.self) private var store
    var body: some View {
        List {
            Section {
                NavigationLink("As Needed Chores") { AsNeededConfigurationView() }
                    .accessibilityIdentifier("as-needed-chores")
            } header: {
                Text("As Needed")
            } footer: {
                Text("Make these chores available only when your family needs them.")
            }
            Section {
                ForEach(store.household?.weekdayLists ?? []) { list in
                    NavigationLink(list.weekday.title) { WeekdayConfigurationView(weekday: list.weekday) }
                        .accessibilityIdentifier("weekday-\(list.weekday.rawValue)")
                }
            } header: {
                Text("Scheduled")
            } footer: {
                Text("One shared recurring list per weekday. Completions are kept by date and person.")
            }
        }
        .navigationTitle("Chores")
        .accessibilityIdentifier("weekday-lists")
    }
}

private struct AsNeededConfigurationView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var addingChore = false
    @State private var editing: ChoreRevision?
    @State private var deleting: ChoreRevision?

    private var chores: [ChoreRevision] {
        Set(store.snapshot.revisions.map(\.choreID)).compactMap {
            store.snapshot.configuration(choreID: $0, on: store.tomorrow)
        }.filter { $0.schedulingMode == .asNeeded && !$0.isArchived
            && !store.snapshot.isChoreDeleted($0.choreID, on: store.day) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func todayOccurrence(_ chore: ChoreRevision) -> DailyChore? {
        store.dailyList().first { $0.id == chore.choreID && $0.isAsNeededOccurrence }
    }

    private func hasEligibleChildrenToday(_ chore: ChoreRevision) -> Bool {
        !ChoreRules.eligibleMembers(for: chore, on: store.day, snapshot: store.snapshot).isEmpty
    }

    var body: some View {
        List {
            Section {
                ForEach(chores) { chore in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(chore.title).font(.headline)
                        Text(chore.mode.title).font(.subheadline).foregroundStyle(.secondary)
                        if chore.effectiveDay > store.day {
                            Text("Starts tomorrow").font(.caption).foregroundStyle(.secondary)
                        }
                        if let occurrence = todayOccurrence(chore) {
                            let owner = occurrence.turnOwner?.displayName
                            Label(occurrence.isFullyComplete
                                  ? "Completed Today\(owner.map { " by \($0)" } ?? "")"
                                  : "Available Today\(owner.map { " for \($0)" } ?? "")",
                                  systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                        } else {
                            if chore.mode == .alternating,
                               let next = store.nextAlternatingOwner(choreID: chore.choreID) {
                                Label("Whose Turn: \(next.displayName)", systemImage: "person.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .accessibilityIdentifier("next-turn-\(chore.title.accessibilitySlug)")
                            }
                            Button("Make Available", systemImage: "plus.circle") {
                                store.perform { try store.activateAsNeededChore(choreID: chore.choreID) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(chore.effectiveDay > store.day || !hasEligibleChildrenToday(chore))
                            .accessibilityIdentifier("make-available-\(chore.title.accessibilitySlug)")
                            if chore.mode == .alternating,
                               let next = store.nextAlternatingOwner(choreID: chore.choreID) {
                                Button("Skip \(next.displayName)", systemImage: "arrow.right.circle") {
                                    store.perform { try store.skipNextAlternatingChild(choreID: chore.choreID) }
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("skip-next-\(chore.title.accessibilitySlug)")
                            }
                        }
                        if !hasEligibleChildrenToday(chore) {
                            Text("No eligible children today").font(.caption).foregroundStyle(.secondary)
                        }
                        Menu {
                            Button("Edit") { editing = chore }.buttonStyle(.bordered)
                            Button("Delete Chore", role: .destructive) { deleting = chore }.buttonStyle(.bordered)
                        } label: {
                            Label("Manage Chore", systemImage: "ellipsis.circle")
                        }
                    }
                    .padding(.vertical, 4)
                }
                if chores.isEmpty { Text("No as-needed chores yet.").foregroundStyle(.secondary) }
                Button("Add As Needed Chore", systemImage: "plus") { addingChore = true }
                    .accessibilityIdentifier("add-as-needed-chore")
            } footer: {
                Text("An available chore appears with today’s chores and closes when its required work is complete. You can make it available again on a later day.")
            }
        }
        .navigationTitle("As Needed")
        .sheet(isPresented: $addingChore) { ResponsibilityFormView(weekday: .monday, schedulingMode: .asNeeded) }
        .sheet(item: $editing) { chore in ResponsibilityFormView(weekday: chore.weekday, existing: chore) }
        .alert(deleting.map { "Delete \"\($0.title)\"?" } ?? "Delete Chore?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let chore = deleting { store.perform { try store.deleteChore(chore.choreID) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This will remove it from the family’s chore lists.") }
    }
}

private struct WeekdayConfigurationView: View {
    @Environment(HouseholdStore.self) private var store
    let weekday: Weekday
    @State private var addingChore = false
    @State private var editing: ChoreRevision?
    @State private var deleting: ChoreRevision?

    private var chores: [ChoreRevision] {
        Set(store.snapshot.revisions.map(\.choreID)).compactMap {
            store.snapshot.configuration(choreID: $0, on: store.tomorrow)
        }.filter { $0.schedulingMode == .scheduled && $0.weekday == weekday && !$0.isArchived
            && !store.snapshot.isChoreDeleted($0.choreID, on: store.day) }
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
                            Button("Delete Chore", role: .destructive) { deleting = chore }.buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if chores.isEmpty { Text("No chores configured yet.").foregroundStyle(.secondary) }
                Button("Add Chore", systemImage: "plus") { addingChore = true }
                    .accessibilityIdentifier("add-responsibility")
            } footer: {
                Text("This list repeats every \(weekday.title). Edits start tomorrow. Deleted chores leave current lists immediately.")
            }
        }
        .navigationTitle(weekday.title)
        .sheet(isPresented: $addingChore) { ResponsibilityFormView(weekday: weekday) }
        .sheet(item: $editing) { chore in ResponsibilityFormView(weekday: weekday, existing: chore) }
        .alert(deleting.map { "Delete \"\($0.title)\"?" } ?? "Delete Chore?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let chore = deleting { store.perform { try store.deleteChore(chore.choreID) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This will remove it from the family’s chore lists.") }
    }
}

import SwiftUI

struct WeekdayListsView: View {
    @Environment(HouseholdStore.self) private var store
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Find your family's rhythm", systemImage: "calendar")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                    Text("A few small habits, shared through the week.")
                        .foregroundStyle(AppTheme.secondaryText)
                }.padding(.vertical, 8)
            }
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
                    NavigationLink { WeekdayConfigurationView(weekday: list.weekday) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "calendar")
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 36, height: 36)
                                .background(AppTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityHidden(true)
                            Text(list.weekday.title).font(.headline)
                        }.padding(.vertical, 4)
                    }
                        .accessibilityIdentifier("weekday-\(list.weekday.rawValue)")
                }
            } header: {
                Text("Scheduled")
            } footer: {
                Text("One shared recurring list per weekday. Completions are kept by date and person.")
            }
        }
        .themedListBackground()
        .navigationTitle("Chores")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("weekday-lists")
    }
}

private struct AsNeededConfigurationView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var addingChore = false
    @State private var editing: ChoreRevision?
    @State private var deleting: ChoreRevision?
    @State private var updatingChoreID: UUID?
    @State private var withdrawing: DailyChore?

    private var chores: [ChoreRevision] {
        Set(store.snapshot.revisions.map(\.choreID)).compactMap {
            store.snapshot.configuration(choreID: $0, on: store.tomorrow)
        }.filter { $0.schedulingMode == .asNeeded && !$0.isArchived
            && !store.snapshot.isChoreDeleted($0.choreID, on: store.day) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func todayOccurrences(_ chore: ChoreRevision) -> [DailyChore] {
        store.dailyList().filter { $0.choreID == chore.choreID && $0.isAsNeededOccurrence }
    }

    private func openOccurrence(_ chore: ChoreRevision) -> DailyChore? {
        guard let projected = store.snapshot.asNeededProjection(
            choreID: chore.choreID, through: store.day
        ).openOccurrence else { return nil }
        return store.dailyList(on: projected.day.date(in: store.calendar)).first {
            $0.occurrenceID == projected.id
        }
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
                        let occurrences = todayOccurrences(chore)
                        let completedCount = occurrences.filter { $0.asNeededStatus == .completed }.count
                        if completedCount > 0 {
                            Label("Completed \(completedCount) \(completedCount == 1 ? "time" : "times") today",
                                  systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        if let occurrence = openOccurrence(chore) {
                            let owner = occurrence.turnOwner?.displayName
                            let openDay = occurrence.day.date(in: store.calendar).formatted(
                                date: .abbreviated, time: .omitted
                            )
                            let availability = occurrence.day == store.day ? "Available Now"
                                : "Available since \(openDay)"
                            Label("\(availability)\(owner.map { " for \($0)" } ?? "")",
                                  systemImage: "circle.dotted")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.blue)
                            Button("Withdraw Availability", systemImage: "xmark.circle") {
                                withdrawing = occurrence
                            }
                            .buttonStyle(.bordered)
                            .disabled(!occurrence.completedMembers.isEmpty || updatingChoreID != nil)
                            .accessibilityIdentifier("withdraw-availability-\(chore.title.accessibilitySlug)")
                            if !occurrence.completedMembers.isEmpty {
                                Text("Correct completed contributions before withdrawing.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            if chore.mode == .alternating,
                               let next = store.nextAlternatingOwner(choreID: chore.choreID) {
                                Label("Whose Turn: \(next.displayName)", systemImage: "person.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .accessibilityIdentifier("next-turn-\(chore.title.accessibilitySlug)")
                            }
                            Button(completedCount > 0 ? "Make Available Again" : "Make Available",
                                   systemImage: "plus.circle") {
                                guard updatingChoreID == nil else { return }
                                updatingChoreID = chore.choreID
                                Task {
                                    defer { updatingChoreID = nil }
                                    do { try await store.makeAsNeededChoreAvailable(choreID: chore.choreID) }
                                    catch { store.errorMessage = error.localizedDescription }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(updatingChoreID != nil || chore.effectiveDay > store.day
                                      || !hasEligibleChildrenToday(chore))
                            .accessibilityIdentifier("make-available-\(chore.title.accessibilitySlug)")
                            if chore.mode == .alternating,
                               let next = store.nextAlternatingOwner(choreID: chore.choreID),
                               Set(ChoreRules.eligibleMembers(for: chore, on: store.day,
                                                             snapshot: store.snapshot).map(\.id)).count > 1 {
                                Button("Skip \(next.displayName)", systemImage: "arrow.right.circle") {
                                    guard updatingChoreID == nil else { return }
                                    updatingChoreID = chore.choreID
                                    Task {
                                        defer { updatingChoreID = nil }
                                        do {
                                            try await store.skipNextAlternatingChildAfterRefreshing(
                                                choreID: chore.choreID
                                            )
                                        } catch { store.errorMessage = error.localizedDescription }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(updatingChoreID != nil)
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
                Text("Each availability is kept separately. Completion advances an alternating turn, withdrawal keeps it, and Skip uses one turn without credit.")
            }
        }
        .themedListBackground()
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
        } message: {
            Text("Deletion is immediate and cannot be undone. Already resolved history and allowance results are preserved.")
        }
        .confirmationDialog("Withdraw this availability?", isPresented: Binding(
            get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } }
        ), titleVisibility: .visible) {
            Button("Withdraw Availability", role: .destructive) {
                guard let occurrence = withdrawing, let occurrenceID = occurrence.occurrenceID else { return }
                updatingChoreID = occurrence.choreID
                Task {
                    defer { updatingChoreID = nil; withdrawing = nil }
                    do {
                        try await store.withdrawAsNeededOccurrenceAfterRefreshing(
                            choreID: occurrence.choreID, occurrenceID: occurrenceID
                        )
                    } catch { store.errorMessage = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This records no completion and keeps the current alternating turn.")
        }
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
        .themedListBackground()
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
        } message: {
            Text("Deletion is immediate and cannot be undone. Already resolved history and allowance results are preserved.")
        }
    }
}

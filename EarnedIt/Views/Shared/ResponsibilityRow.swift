import SwiftUI

struct ResponsibilityRow: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let chore: DailyChore
    let actor: FamilyMember
    @State private var pendingRemoval: FamilyMember?
    @State private var pendingState: DailyStateKind = .unmarked

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: chore.configuration.category.symbolName)
                        .foregroundStyle(.secondary).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chore.configuration.title).font(.headline)
                        Text(chore.requiredMembers.isEmpty ? RequirementMode.anyOne.title : "Required: " + chore.requiredMembers.map(\.displayName).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Label(completionLabel, systemImage: chore.isFullyComplete ? "checkmark.circle.fill" : "circle.dotted")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("full-status-\(chore.configuration.title.accessibilitySlug)")
                if !chore.configuration.notes.isEmpty {
                    Text(chore.configuration.notes).font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(chore.eligibleMembers) { member in
                    memberRow(member)
                }
                if chore.eligibleMembers.isEmpty {
                    Text("No eligible children for this date.").font(.subheadline).foregroundStyle(.secondary)
                } else if chore.requiredMembers.isEmpty && !chore.isFullyComplete {
                    Text("One eligible child is needed.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("chore-\(chore.configuration.title.accessibilitySlug)")
        .alert("Remove this contribution?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("Remove Contribution", role: .destructive) {
                if let member = pendingRemoval { update(member, state: pendingState) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only \(pendingRemoval?.displayName ?? "this member")’s entry for this date will change. Other members’ entries are kept.")
        }
    }

    private var completionLabel: String {
        if chore.isFullyComplete {
            return chore.notNeededMembers.isEmpty ? "Complete" : "Accounted for"
        }
        return chore.requiredMembers.isEmpty ? "One person still needed" : "\(chore.remainingMembers.count) still needed"
    }

    private func memberRow(_ member: FamilyMember) -> some View {
        let state = chore.state(for: member.id)
        let canChange = actor.role == .parent || actor.id == member.id
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(member.id == actor.id ? "\(member.displayName) (you)" : member.displayName)
                    .font(.subheadline.weight(.medium))
                if chore.requiredMembers.isEmpty && !state.isAccountedFor && chore.isFullyComplete {
                    Text("Someone else helped").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            if canChange && chore.day <= chore.today {
                Menu {
                    ForEach(DailyStateKind.allCases.filter { PermissionService.canSetState(actor: actor, target: member.id, chore: chore, state: $0) }) { option in
                        Button(option.rawValue, systemImage: option.symbolName) {
                            if state.isAccountedFor && !option.isAccountedFor {
                                pendingState = option
                                pendingRemoval = member
                            } else { update(member, state: option) }
                        }
                    }
                } label: {
                    Label(state == .unmarked ? "Mark" : state.rawValue, systemImage: state.symbolName)
                        .font(.subheadline).foregroundStyle(.primary)
                        .padding(.vertical, 8)
                }
                .accessibilityLabel("\(member.displayName), \(chore.configuration.title), \(state.rawValue)")
                .accessibilityIdentifier("state-\(chore.configuration.title.accessibilitySlug)-\(member.displayName.accessibilitySlug)")
            } else {
                Label(state.rawValue, systemImage: state.symbolName)
                    .font(.subheadline).foregroundStyle(.primary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func update(_ member: FamilyMember, state: DailyStateKind) {
        store.perform {
            try store.setCompletion(choreID: chore.id, memberID: member.id,
                                    date: chore.day.date(in: store.calendar), state: state)
        }
    }
}

struct SharedDailyList: View {
    @Environment(HouseholdStore.self) private var store
    let actor: FamilyMember
    let date: Date

    private var chores: [DailyChore] {
        ChoreRules.visibleList(store.dailyList(on: date), to: actor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.calendar.isDate(date, inSameDayAs: store.today) ? "Today’s Chores" : "Chores for This Day").font(.title2.bold())
            if chores.isEmpty {
                ContentUnavailableView("Nothing expected", systemImage: "checkmark.circle",
                    description: Text(actor.role == .parent ? "Configure a shared weekday list to get started." : "Enjoy your day. Your family’s list has nothing for you here."))
            } else {
                ForEach(chores) { chore in ResponsibilityRow(chore: chore, actor: actor) }
            }
        }
    }
}

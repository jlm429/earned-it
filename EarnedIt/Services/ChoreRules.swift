import Foundation

struct DailyChore: Identifiable, Equatable {
    let configuration: ChoreRevision
    let day: CivilDay
    let eligibleMembers: [FamilyMember]
    let contributions: [DatedCompletion]
    let today: CivilDay

    var id: UUID { configuration.choreID }
    var requiredMembers: [FamilyMember] { configuration.mode == .anyOne ? [] : eligibleMembers }
    var requiredCompletionCount: Int { configuration.mode == .anyOne ? min(1, eligibleMembers.count) : requiredMembers.count }
    var completedMembers: [FamilyMember] { eligibleMembers.filter { state(for: $0.id) == .done } }
    var notNeededMembers: [FamilyMember] { eligibleMembers.filter { state(for: $0.id) == .notNeeded } }
    var accountedMembers: [FamilyMember] { eligibleMembers.filter { state(for: $0.id).isAccountedFor } }
    var isFullyComplete: Bool {
        guard !eligibleMembers.isEmpty else { return false }
        if configuration.mode == .anyOne {
            return !completedMembers.isEmpty || accountedMembers.count == eligibleMembers.count
        }
        return remainingMembers.isEmpty
    }
    var remainingMembers: [FamilyMember] {
        if configuration.mode == .anyOne && !completedMembers.isEmpty { return [] }
        return eligibleMembers.filter { !state(for: $0.id).isAccountedFor }
    }

    func state(for memberID: UUID) -> DailyStateKind {
        let state = contributions.first { $0.memberID == memberID }?.state ?? .unmarked
        return state == .unmarked && day < today ? .missed : state
    }

    func creditState(for memberID: UUID) -> DailyStateKind? {
        guard eligibleMembers.contains(where: { $0.id == memberID }) else { return nil }
        let state = state(for: memberID)
        // Any-one chores are optional contributions, never another child's credit or penalty.
        if configuration.mode == .anyOne && !state.isAccountedFor { return nil }
        return state
    }
}

enum ChoreRules {
    static func visibleList(_ chores: [DailyChore], to member: FamilyMember) -> [DailyChore] {
        member.role == .parent ? chores : chores.filter { $0.eligibleMembers.contains { $0.id == member.id } }
    }

    static func eligibleMembers(for revision: ChoreRevision, on day: CivilDay, snapshot: HouseholdSnapshot) -> [FamilyMember] {
        snapshot.members.filter {
            $0.role == .child && $0.isActive(on: day)
                && (revision.mode == .all || revision.memberIDs.contains($0.id))
        }
    }

    static func dailyList(snapshot: HouseholdSnapshot, day: CivilDay, today: CivilDay) -> [DailyChore] {
        guard let household = snapshot.household else { return [] }
        let weekday = household.calendar.component(.weekday, from: day.date(in: household.calendar))
        let choreIDs = Set(snapshot.revisions.map(\.choreID))
        return choreIDs.compactMap { choreID -> DailyChore? in
            guard let revision = snapshot.configuration(choreID: choreID, on: day) else { return nil }
            let contributions = snapshot.completions.filter { $0.choreID == choreID && $0.day == day }
            let recorded = contributions.filter { $0.state.isAccountedFor }
            guard (!revision.isArchived && revision.weekday.rawValue == weekday) || !recorded.isEmpty else { return nil }
            var members = eligibleMembers(for: revision, on: day, snapshot: snapshot)
            // A recorded assignment survives conflicting offline edits or later membership revisions.
            let recordedIDs = Set(recorded.flatMap(\.eligibleMemberIDs))
            members += snapshot.members.filter { recordedIDs.contains($0.id) && !members.contains($0) }
            return DailyChore(configuration: revision, day: day, eligibleMembers: members,
                              contributions: contributions, today: today)
        }.sorted { $0.configuration.title.localizedStandardCompare($1.configuration.title) == .orderedAscending }
    }
}

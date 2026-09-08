import Foundation

struct HistoricalContribution: Identifiable, Equatable {
    let member: FamilyMember
    let state: DailyStateKind

    var id: UUID { member.id }
}

struct ResolvedOccurrence: Equatable {
    let winningRevision: ChoreRevision
    let scheduledOwner: FamilyMember?
    let activeContributions: [DatedCompletion]
    let displacedHistoricalContributions: [HistoricalContribution]
}

struct DailyChore: Identifiable, Equatable {
    let configuration: ChoreRevision
    let day: CivilDay
    let eligibleMembers: [FamilyMember]
    let requiredMemberIDs: Set<UUID>
    let turnOwnerID: UUID?
    let contributions: [DatedCompletion]
    let historicalContributions: [HistoricalContribution]
    let today: CivilDay

    var id: UUID { configuration.choreID }
    var requiredMembers: [FamilyMember] { eligibleMembers.filter { requiredMemberIDs.contains($0.id) } }
    var turnOwner: FamilyMember? { turnOwnerID.flatMap { id in eligibleMembers.first { $0.id == id } } }
    var requiredCompletionCount: Int { requiredMembers.isEmpty ? min(1, eligibleMembers.count) : requiredMembers.count }
    var completedMembers: [FamilyMember] { eligibleMembers.filter { state(for: $0.id) == .done } }
    var notNeededMembers: [FamilyMember] { eligibleMembers.filter { state(for: $0.id) == .notNeeded } }
    var accountedMembers: [FamilyMember] { eligibleMembers.filter { state(for: $0.id).isAccountedFor } }
    var isFullyComplete: Bool {
        guard !eligibleMembers.isEmpty else { return false }
        if requiredMembers.isEmpty {
            return !completedMembers.isEmpty || accountedMembers.count == eligibleMembers.count
        }
        return remainingMembers.isEmpty
    }
    var remainingMembers: [FamilyMember] {
        if requiredMembers.isEmpty && !completedMembers.isEmpty { return [] }
        let expected = requiredMembers.isEmpty ? eligibleMembers : requiredMembers
        return expected.filter { !state(for: $0.id).isAccountedFor }
    }

    func state(for memberID: UUID) -> DailyStateKind {
        let state = contributions.first { $0.memberID == memberID }?.state ?? .unmarked
        return state == .unmarked && day < today ? .missed : state
    }

    func creditState(for memberID: UUID) -> DailyStateKind? {
        guard eligibleMembers.contains(where: { $0.id == memberID }) else { return nil }
        let state = state(for: memberID)
        // Any-one chores are optional contributions, never another child's credit or penalty.
        if !requiredMemberIDs.contains(memberID) && !state.isAccountedFor { return nil }
        return state
    }

    func turnLabel(for actor: FamilyMember) -> String? {
        guard configuration.mode == .alternating else { return nil }
        guard let turnOwner else { return "No eligible child this turn" }
        return actor.role == .child && actor.id == turnOwner.id ? "Your turn" : "\(turnOwner.displayName)’s turn"
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
            let recorded = snapshot.recordedAssignments.filter { $0.choreID == choreID && $0.day == day }
            guard (!revision.isArchived && revision.weekday.rawValue == weekday) || !recorded.isEmpty else { return nil }
            let scheduled = !revision.isArchived && revision.weekday.rawValue == weekday
            let scheduledMembers = scheduled ? eligibleMembers(for: revision, on: day, snapshot: snapshot) : []
            let occurrence = resolveOccurrence(revision: revision, scheduledMembers: scheduledMembers,
                                               choreID: choreID, day: day, snapshot: snapshot,
                                               calendar: household.calendar)
            var members = revision.mode == .alternating
                ? occurrence.scheduledOwner.map { [$0] } ?? [] : scheduledMembers
            var requiredIDs = Set(revision.mode != .anyOne ? members.map(\.id) : [])
            if !scheduled || revision.mode != .alternating {
                let restorable = recorded.filter { $0.mode != .anyOne && $0.mode != .alternating }
                requiredIDs.formUnion(restorable.flatMap(\.eligibleMemberIDs))
                // A recorded assignment survives conflicting offline edits or later membership revisions.
                let recordedIDs = Set(restorable.flatMap(\.eligibleMemberIDs))
                members += snapshot.members.filter { recordedIDs.contains($0.id) && !members.contains($0) }
            }
            return DailyChore(configuration: occurrence.winningRevision, day: day, eligibleMembers: members,
                              requiredMemberIDs: requiredIDs, turnOwnerID: occurrence.scheduledOwner?.id,
                              contributions: occurrence.activeContributions,
                              historicalContributions: occurrence.displacedHistoricalContributions,
                              today: today)
        }.sorted { $0.configuration.title.localizedStandardCompare($1.configuration.title) == .orderedAscending }
    }

    private static func resolveOccurrence(revision: ChoreRevision, scheduledMembers: [FamilyMember],
                                          choreID: UUID, day: CivilDay, snapshot: HouseholdSnapshot,
                                          calendar: Calendar) -> ResolvedOccurrence {
        var owner: FamilyMember?
        if revision.mode == .alternating, !scheduledMembers.isEmpty {
            let activeByID = Dictionary(uniqueKeysWithValues: scheduledMembers.map { ($0.id, $0) })
            let participants = revision.memberIDs.compactMap { activeByID[$0] }
            if !participants.isEmpty {
                let index = alternatingOccurrenceIndex(choreID: choreID, before: day,
                                                       snapshot: snapshot, calendar: calendar)
                owner = participants[index % participants.count]
            }
        }
        func isActive(_ contribution: DatedCompletion) -> Bool {
            if revision.mode == .alternating {
                return contribution.mode == .alternating
                    && contribution.revisionID == revision.id && contribution.memberID == owner?.id
            }
            return contribution.mode != .alternating
        }
        let active: [DatedCompletion]
        if revision.mode == .alternating {
            active = snapshot.recordedAssignments.last {
                $0.choreID == choreID && $0.day == day && isActive($0)
            }.map { [$0] } ?? []
        } else {
            active = snapshot.completions.filter {
                $0.choreID == choreID && $0.day == day && isActive($0)
            }
        }
        var historicalByMemberID: [UUID: DatedCompletion] = [:]
        for contribution in snapshot.recordedAssignments where contribution.choreID == choreID
            && contribution.day == day && contribution.mode == .alternating && !isActive(contribution) {
            historicalByMemberID[contribution.memberID] = contribution
        }
        let historical = snapshot.members.compactMap { member in
            historicalByMemberID[member.id].map { HistoricalContribution(member: member, state: $0.state) }
        }
        return ResolvedOccurrence(winningRevision: revision, scheduledOwner: owner,
                                  activeContributions: active,
                                  displacedHistoricalContributions: historical)
    }

    /// Counts scheduled alternating dates before this date. Edits do not reset the sequence.
    private static func alternatingOccurrenceIndex(choreID: UUID, before day: CivilDay,
                                                   snapshot: HouseholdSnapshot, calendar: Calendar) -> Int {
        var revisionsByDay: [CivilDay: ChoreRevision] = [:]
        for revision in snapshot.revisions where revision.choreID == choreID && revision.effectiveDay < day {
            revisionsByDay[revision.effectiveDay] = revision
        }
        let timeline = revisionsByDay.values.sorted { $0.effectiveDay < $1.effectiveDay }
        return timeline.enumerated().reduce(into: 0) { count, entry in
            let (index, revision) = entry
            guard revision.mode == .alternating, !revision.isArchived else { return }
            let end = min(timeline.indices.contains(index + 1) ? timeline[index + 1].effectiveDay : day, day)
            count += occurrenceCount(weekday: revision.weekday, from: revision.effectiveDay,
                                     before: end, calendar: calendar)
        }
    }

    private static func occurrenceCount(weekday: Weekday, from start: CivilDay,
                                        before end: CivilDay, calendar: Calendar) -> Int {
        guard start < end else { return 0 }
        let startDate = start.date(in: calendar)
        let currentWeekday = calendar.component(.weekday, from: startDate)
        let offset = (weekday.rawValue - currentWeekday + 7) % 7
        guard let first = calendar.date(byAdding: .day, value: offset, to: startDate),
              first < end.date(in: calendar) else { return 0 }
        let days = calendar.dateComponents([.day], from: first, to: end.date(in: calendar)).day ?? 0
        return (days + 6) / 7
    }
}

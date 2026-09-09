import Foundation

struct HistoricalContribution: Identifiable, Equatable {
    struct ID: Hashable {
        let revisionID: UUID
        let memberID: UUID
    }

    let revisionID: UUID
    let member: FamilyMember
    let state: DailyStateKind

    var id: ID { ID(revisionID: revisionID, memberID: member.id) }
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
            if revision.mode != .alternating {
                let restorable = occurrence.activeContributions.filter { $0.mode != .anyOne }
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
            owner = alternatingOwner(choreID: choreID, on: day, snapshot: snapshot, calendar: calendar)
        }
        func isActive(_ contribution: DatedCompletion) -> Bool {
            guard contribution.revisionID == revision.id else { return false }
            if revision.mode == .alternating {
                return contribution.mode == .alternating
                    && contribution.memberID == owner?.id
            }
            return contribution.mode != .alternating
        }
        let active: [DatedCompletion]
        if revision.mode == .alternating {
            active = snapshot.recordedAssignments.last {
                $0.choreID == choreID && $0.day == day && isActive($0)
            }.map { [$0] } ?? []
        } else {
            var activeByMemberID: [UUID: DatedCompletion] = [:]
            for contribution in snapshot.recordedAssignments where contribution.choreID == choreID
                && contribution.day == day && isActive(contribution) {
                activeByMemberID[contribution.memberID] = contribution
            }
            active = activeByMemberID.values.sorted { $0.key < $1.key }
        }
        var historicalByAssignment: [HistoricalContribution.ID: DatedCompletion] = [:]
        var historicalOrder: [HistoricalContribution.ID] = []
        for contribution in snapshot.recordedAssignments where contribution.choreID == choreID
            && contribution.day == day && !isActive(contribution) {
            let id = HistoricalContribution.ID(revisionID: contribution.revisionID,
                                               memberID: contribution.memberID)
            if historicalByAssignment[id] == nil { historicalOrder.append(id) }
            historicalByAssignment[id] = contribution
        }
        let membersByID = Dictionary(uniqueKeysWithValues: snapshot.members.map { ($0.id, $0) })
        let historical: [HistoricalContribution] = historicalOrder.compactMap { id in
            guard let contribution = historicalByAssignment[id], let member = membersByID[id.memberID] else { return nil }
            return HistoricalContribution(revisionID: contribution.revisionID, member: member,
                                          state: contribution.state)
        }
        return ResolvedOccurrence(winningRevision: revision, scheduledOwner: owner,
                                  activeContributions: active,
                                  displacedHistoricalContributions: historical)
    }

    private static func alternatingOwner(choreID: UUID, on day: CivilDay,
                                         snapshot: HouseholdSnapshot, calendar: Calendar) -> FamilyMember? {
        var revisionsByDay: [CivilDay: ChoreRevision] = [:]
        for revision in snapshot.revisions where revision.choreID == choreID && revision.effectiveDay <= day {
            revisionsByDay[revision.effectiveDay] = revision
        }
        let timeline = revisionsByDay.values.sorted { $0.effectiveDay < $1.effectiveDay }
        var priorOwnerID: UUID?
        var ownerID: UUID?
        for entry in timeline.enumerated() {
            let (index, revision) = entry
            guard revision.mode == .alternating, !revision.isArchived else { continue }
            let end = timeline.indices.contains(index + 1)
                ? min(timeline[index + 1].effectiveDay, day.adding(days: 1, calendar: calendar))
                : day.adding(days: 1, calendar: calendar)
            let startDate = revision.effectiveDay.date(in: calendar)
            let weekday = calendar.component(.weekday, from: startDate)
            let offset = (revision.weekday.rawValue - weekday + 7) % 7
            var occurrence = revision.effectiveDay.adding(days: offset, calendar: calendar)
            while occurrence < end {
                let eligibleIDs = Set(snapshot.members.filter {
                    $0.role == .child && $0.isActive(on: occurrence) && revision.memberIDs.contains($0.id)
                }.map(\.id))
                if let nextOwnerID = nextOwner(after: priorOwnerID, participants: revision.memberIDs,
                                               eligibleIDs: eligibleIDs) {
                    priorOwnerID = nextOwnerID
                    if occurrence == day { ownerID = nextOwnerID }
                }
                occurrence = occurrence.adding(days: 7, calendar: calendar)
            }
        }
        return ownerID.flatMap { snapshot.member($0) }
    }

    private static func nextOwner(after priorOwnerID: UUID?, participants: [UUID],
                                  eligibleIDs: Set<UUID>) -> UUID? {
        guard !participants.isEmpty, !eligibleIDs.isEmpty else { return nil }
        let priorIndex = priorOwnerID.flatMap { participants.firstIndex(of: $0) }
        let start = priorIndex.map { ($0 + 1) % participants.count } ?? 0
        for offset in participants.indices {
            let candidate = participants[(start + offset) % participants.count]
            if eligibleIDs.contains(candidate) { return candidate }
        }
        return nil
    }
}

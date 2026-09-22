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
    let occurrenceDisposition: ChoreOccurrenceDisposition?
    let isActiveOccurrence: Bool
    let isDeleted: Bool
    let today: CivilDay

    var id: UUID { configuration.choreID }
    var isScheduledOccurrence: Bool { isActiveOccurrence && configuration.schedulingMode == .scheduled }
    var isAsNeededOccurrence: Bool { isActiveOccurrence && configuration.schedulingMode == .asNeeded }
    var requiredMembers: [FamilyMember] { eligibleMembers.filter { requiredMemberIDs.contains($0.id) } }
    var turnOwner: FamilyMember? { turnOwnerID.flatMap { id in eligibleMembers.first { $0.id == id } } }
    var isNotNeeded: Bool { occurrenceDisposition?.state == .notNeeded }
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
        let current = chores.filter { !$0.isDeleted }
        return member.role == .parent ? current : current.filter {
            !$0.isNotNeeded && $0.eligibleMembers.contains { $0.id == member.id }
        }
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
            if snapshot.isChoreDeleted(choreID, on: day) {
                guard let deletion = snapshot.choreDeletions.last(where: {
                    $0.choreID == choreID && $0.day <= day
                }), deletion.day == day,
                      let winningRevisionID = deletion.revisionID,
                      let original = snapshot.revisions.first(where: { $0.id == winningRevisionID }) else { return nil }
                let retained: [DatedCompletion]
                if let resolved = deletion.resolvedContributions {
                    retained = resolved
                } else {
                    var latestByMember: [UUID: DatedCompletion] = [:]
                    for contribution in snapshot.recordedAssignments where contribution.choreID == choreID
                        && contribution.day == day && contribution.revisionID == winningRevisionID {
                        latestByMember[contribution.memberID] = contribution
                    }
                    retained = latestByMember.values.filter(\.state.isAccountedFor).sorted { $0.key < $1.key }
                }
                guard !retained.isEmpty || deletion.wasNotNeeded == true else { return nil }
                let eligibleIDs = Set(deletion.eligibleMemberIDs ?? retained.flatMap(\.eligibleMemberIDs))
                let requiredIDs = original.mode == .anyOne ? [] : Set(retained.map(\.memberID))
                let members = snapshot.members.filter { eligibleIDs.contains($0.id) }
                let disposition = deletion.wasNotNeeded == true ? ChoreOccurrenceDisposition(
                    choreID: choreID, revisionID: original.id, day: day, state: .notNeeded,
                    alternatingSkipBehavior: original.mode == .alternating ? .keepTurn : nil,
                    recordedByMemberID: deletion.recordedByMemberID
                ) : nil
                return DailyChore(
                    configuration: original, day: day, eligibleMembers: members,
                    requiredMemberIDs: requiredIDs,
                    turnOwnerID: deletion.turnOwnerID,
                    contributions: retained, historicalContributions: [], occurrenceDisposition: disposition,
                    isActiveOccurrence: false, isDeleted: true, today: today
                )
            }
            if revision.isArchived {
                guard let previous = previousConfiguration(before: revision, on: day, snapshot: snapshot) else {
                    return nil
                }
                let retained = snapshot.completions.filter {
                    $0.choreID == choreID && $0.day == day && $0.revisionID == previous.id
                        && $0.state.isAccountedFor
                }
                guard !retained.isEmpty else { return nil }
                let retainedIDs = Set(retained.map(\.memberID))
                let members = snapshot.members.filter { retainedIDs.contains($0.id) }
                return DailyChore(
                    configuration: previous, day: day, eligibleMembers: members,
                    requiredMemberIDs: retainedIDs,
                    turnOwnerID: previous.mode == .alternating ? retained.first?.memberID : nil,
                    contributions: retained, historicalContributions: [], occurrenceDisposition: nil,
                    isActiveOccurrence: false, isDeleted: true, today: today
                )
            }
            let disposition = snapshot.occurrence(choreID: choreID, on: day).flatMap {
                $0.revisionID == revision.id ? $0 : nil
            }
            let scheduled = revision.schedulingMode == .scheduled
                && revision.weekday.rawValue == weekday
            let activated = revision.schedulingMode == .asNeeded
                && disposition?.state == .available
            let notNeeded = scheduled && disposition?.state == .notNeeded
            guard scheduled || activated || !recorded.isEmpty else { return nil }
            let occurrenceExists = scheduled || activated
            let scheduledMembers = occurrenceExists ? eligibleMembers(for: revision, on: day, snapshot: snapshot) : []
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
                              occurrenceDisposition: notNeeded || activated ? disposition : nil,
                              isActiveOccurrence: occurrenceExists, isDeleted: false,
                              today: today)
        }.sorted {
            let titleOrder = $0.configuration.title.localizedStandardCompare($1.configuration.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func activeOccurrence(for revision: ChoreRevision, in chores: [DailyChore]) -> DailyChore? {
        chores.first { $0.configuration.id == revision.id && $0.isActiveOccurrence }
    }

    static func nextAlternatingOwner(choreID: UUID, on day: CivilDay,
                                     snapshot: HouseholdSnapshot) -> FamilyMember? {
        guard let revision = snapshot.configuration(choreID: choreID, on: day),
              !revision.isArchived, !snapshot.isChoreDeleted(choreID, on: day),
              revision.mode == .alternating,
              revision.schedulingMode == .asNeeded else { return nil }
        return asNeededAlternatingOwner(choreID: choreID, on: day, snapshot: snapshot)
    }

    private static func resolveOccurrence(revision: ChoreRevision, scheduledMembers: [FamilyMember],
                                          choreID: UUID, day: CivilDay, snapshot: HouseholdSnapshot,
                                          calendar: Calendar) -> ResolvedOccurrence {
        var owner: FamilyMember?
        if revision.mode == .alternating, !scheduledMembers.isEmpty {
            switch revision.schedulingMode {
            case .scheduled:
                owner = scheduledAlternatingOwner(choreID: choreID, on: day,
                                                  snapshot: snapshot, calendar: calendar)
            case .asNeeded:
                owner = asNeededAlternatingOwner(choreID: choreID, on: day, snapshot: snapshot)
            }
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

    private static func scheduledAlternatingOwner(choreID: UUID, on day: CivilDay,
                                                  snapshot: HouseholdSnapshot,
                                                  calendar: Calendar) -> FamilyMember? {
        var revisionsByDay: [CivilDay: ChoreRevision] = [:]
        for revision in snapshot.revisions where revision.choreID == choreID && revision.effectiveDay <= day {
            revisionsByDay[revision.effectiveDay] = revision
        }
        let timeline = revisionsByDay.values.sorted { $0.effectiveDay < $1.effectiveDay }
        var priorOwnerID: UUID?
        var ownerID: UUID?
        func applyOccurrence(_ occurrence: CivilDay, revision: ChoreRevision) {
            let eligibleIDs = Set(snapshot.members.filter {
                $0.role == .child && $0.isActive(on: occurrence) && revision.memberIDs.contains($0.id)
            }.map(\.id))
            guard let nextOwnerID = nextOwner(after: priorOwnerID, participants: revision.memberIDs,
                                              eligibleIDs: eligibleIDs) else { return }
            if occurrence == day { ownerID = nextOwnerID }
            let disposition = snapshot.occurrence(choreID: choreID, on: occurrence)
            let keepsTurn = disposition?.revisionID == revision.id
                && disposition?.state == .notNeeded
                && disposition?.alternatingSkipBehavior == .keepTurn
            if !keepsTurn { priorOwnerID = nextOwnerID }
        }
        for entry in timeline.enumerated() {
            let (index, revision) = entry
            guard revision.mode == .alternating, !revision.isArchived else { continue }
            let end = timeline.indices.contains(index + 1)
                ? min(timeline[index + 1].effectiveDay, day.adding(days: 1, calendar: calendar))
                : day.adding(days: 1, calendar: calendar)
            guard revision.schedulingMode == .scheduled else { continue }
            let startDate = revision.effectiveDay.date(in: calendar)
            let weekday = calendar.component(.weekday, from: startDate)
            let offset = (revision.weekday.rawValue - weekday + 7) % 7
            var occurrence = revision.effectiveDay.adding(days: offset, calendar: calendar)
            while occurrence < end {
                applyOccurrence(occurrence, revision: revision)
                occurrence = occurrence.adding(days: 7, calendar: calendar)
            }
        }
        return ownerID.flatMap { snapshot.member($0) }
    }

    private static func asNeededAlternatingOwner(choreID: UUID, on day: CivilDay,
                                                 snapshot: HouseholdSnapshot) -> FamilyMember? {
        var priorOwnerID: UUID?
        var activeOwnerID: UUID?
        let eventDays = Set(
            snapshot.occurrenceDispositions.filter {
                $0.choreID == choreID && $0.state == .available && $0.day <= day
            }.map(\.day)
            + snapshot.alternatingTurnAdvances.filter {
                $0.choreID == choreID && $0.day <= day
            }.map(\.day)
        ).sorted()

        func eligibleIDs(for revision: ChoreRevision, on eventDay: CivilDay) -> Set<UUID> {
            Set(snapshot.members.filter {
                $0.role == .child && $0.isActive(on: eventDay) && revision.memberIDs.contains($0.id)
            }.map(\.id))
        }

        for eventDay in eventDays {
            guard let revision = snapshot.configuration(choreID: choreID, on: eventDay),
                  !revision.isArchived, revision.mode == .alternating,
                  revision.schedulingMode == .asNeeded else { continue }
            let eligible = eligibleIDs(for: revision, on: eventDay)
            let activation = snapshot.occurrenceDispositions.first {
                $0.choreID == choreID && $0.revisionID == revision.id
                    && $0.day == eventDay && $0.state == .available
            }
            if activation?.assignedMemberID != nil || activation == nil {
                for advance in snapshot.alternatingTurnAdvances where advance.choreID == choreID
                    && advance.revisionID == revision.id && advance.day == eventDay {
                    guard let ownerID = nextOwner(after: priorOwnerID, participants: revision.memberIDs,
                                                  eligibleIDs: eligible),
                          ownerID != activation?.assignedMemberID,
                          ownerID == advance.expectedMemberID else { continue }
                    priorOwnerID = ownerID
                }
            }
            guard let activation,
                  let ownerID = activation.assignedMemberID
                    ?? nextOwner(after: priorOwnerID, participants: revision.memberIDs,
                                 eligibleIDs: eligible) else { continue }
            if eventDay == day { activeOwnerID = ownerID }
            let completed = snapshot.recordedAssignments.last {
                $0.choreID == choreID && $0.revisionID == revision.id && $0.day == eventDay
                    && $0.memberID == ownerID
            }?.state.isAccountedFor == true
            if completed || activation.assignedMemberID == nil { priorOwnerID = ownerID }
        }
        if let activeOwnerID { return snapshot.member(activeOwnerID) }
        guard let revision = snapshot.configuration(choreID: choreID, on: day),
              !revision.isArchived, revision.mode == .alternating,
              revision.schedulingMode == .asNeeded else { return nil }
        let ownerID = nextOwner(after: priorOwnerID, participants: revision.memberIDs,
                                eligibleIDs: eligibleIDs(for: revision, on: day))
        return ownerID.flatMap { snapshot.member($0) }
    }

    private static func previousConfiguration(before archived: ChoreRevision, on day: CivilDay,
                                              snapshot: HouseholdSnapshot) -> ChoreRevision? {
        guard let archivedIndex = snapshot.revisions.firstIndex(where: { $0.id == archived.id }) else { return nil }
        return snapshot.revisions[..<archivedIndex].filter {
            $0.choreID == archived.choreID && $0.effectiveDay <= day && !$0.isArchived
        }.enumerated().max {
            $0.element.effectiveDay == $1.element.effectiveDay
                ? $0.offset < $1.offset : $0.element.effectiveDay < $1.element.effectiveDay
        }?.element
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

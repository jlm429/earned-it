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
    let excusedMemberIDs: Set<UUID>
    let occurrenceDisposition: ChoreOccurrenceDisposition?
    let occurrenceID: UUID?
    let asNeededStatus: AsNeededOccurrenceStatus?
    let isActiveOccurrence: Bool
    let isDeleted: Bool
    let today: CivilDay

    var id: UUID { occurrenceID ?? configuration.choreID }
    var choreID: UUID { configuration.choreID }
    var isScheduledOccurrence: Bool { isActiveOccurrence && configuration.schedulingMode == .scheduled }
    var isAsNeededOccurrence: Bool { occurrenceID != nil && configuration.schedulingMode == .asNeeded }
    var isActionableOccurrence: Bool { asNeededStatus == nil || asNeededStatus == .open }
    var requiredMembers: [FamilyMember] { eligibleMembers.filter { requiredMemberIDs.contains($0.id) } }
    var turnOwner: FamilyMember? { turnOwnerID.flatMap { id in eligibleMembers.first { $0.id == id } } }
    var isNotNeeded: Bool { occurrenceDisposition?.state == .notNeeded }
    var requiredCompletionCount: Int { requiredMembers.isEmpty ? min(1, eligibleMembers.count) : requiredMembers.count }
    var completedMembers: [FamilyMember] { eligibleMembers.filter { state(for: $0.id) == .done } }
    var notNeededMembers: [FamilyMember] { eligibleMembers.filter { state(for: $0.id) == .notNeeded } }
    var accountedMembers: [FamilyMember] { eligibleMembers.filter { state(for: $0.id).isAccountedFor } }
    func isExcused(_ memberID: UUID) -> Bool { excusedMemberIDs.contains(memberID) }
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
        guard eligibleMembers.contains(where: { $0.id == memberID }), !isExcused(memberID) else { return nil }
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
        let swaps = SwapRules.project(snapshot: snapshot, today: today)
        return choreIDs.flatMap { choreID -> [DailyChore] in
            guard let revision = snapshot.configuration(choreID: choreID, on: day) else { return [] }
            let recorded = snapshot.recordedAssignments.filter { $0.choreID == choreID && $0.day == day }
            if snapshot.isChoreDeleted(choreID, on: day) {
                if let deletion = snapshot.occurrenceAwareChoreDeletions.first(where: {
                    $0.choreID == choreID && $0.day == day
                }), let original = snapshot.revisions.first(where: { $0.id == deletion.revisionID }) {
                    let membersByID = Dictionary(uniqueKeysWithValues: snapshot.members.map { ($0.id, $0) })
                    return deletion.resolvedOccurrences.compactMap { occurrence in
                        let members = occurrence.eligibleMemberIDs.compactMap { membersByID[$0] }
                        guard !members.isEmpty else { return nil }
                        return DailyChore(
                            configuration: original, day: occurrence.day, eligibleMembers: members,
                            requiredMemberIDs: Set(occurrence.requiredMemberIDs),
                            turnOwnerID: occurrence.assignedMemberID,
                            contributions: occurrence.contributions,
                            historicalContributions: [],
                            excusedMemberIDs: Set(occurrence.excusedMemberIDs),
                            occurrenceDisposition: nil, occurrenceID: occurrence.id,
                            asNeededStatus: .completed, isActiveOccurrence: false,
                            isDeleted: true, today: today
                        )
                    }
                }
                guard let deletion = snapshot.choreDeletions.first(where: {
                    $0.choreID == choreID && $0.day <= day
                }), deletion.day == day,
                      let winningRevisionID = deletion.revisionID,
                      let original = snapshot.revisions.first(where: { $0.id == winningRevisionID }) else { return [] }
                let retained: [DatedCompletion]
                if let resolved = deletion.resolvedContributions {
                    retained = resolved
                } else {
                    var latestByMember: [UUID: DatedCompletion] = [:]
                    for contribution in snapshot.recordedAssignments where contribution.choreID == choreID
                        && contribution.day == day && contribution.revisionID == winningRevisionID {
                        latestByMember[contribution.memberID] = contribution
                    }
                    retained = latestByMember.values.filter { $0.state != .unmarked }.sorted { $0.key < $1.key }
                }
                let resolvedExcusedIDs = Set(deletion.resolvedExcusedMemberIDs ?? snapshot.excuses.filter {
                    $0.day == day && $0.isExcused
                }.map(\.memberID))
                guard !retained.isEmpty || !resolvedExcusedIDs.isEmpty
                        || deletion.wasNotNeeded == true else { return [] }
                let eligibleIDs = Set(deletion.eligibleMemberIDs
                    ?? (retained.flatMap(\.eligibleMemberIDs) + Array(resolvedExcusedIDs)))
                let requiredIDs = original.mode == .anyOne ? [] : Set(retained.map(\.memberID))
                let members = snapshot.members.filter { eligibleIDs.contains($0.id) }
                let disposition = deletion.wasNotNeeded == true ? ChoreOccurrenceDisposition(
                    choreID: choreID, revisionID: original.id, day: day, state: .notNeeded,
                    alternatingSkipBehavior: original.mode == .alternating ? .keepTurn : nil,
                    recordedByMemberID: deletion.recordedByMemberID
                ) : nil
                return [DailyChore(
                    configuration: original, day: day, eligibleMembers: members,
                    requiredMemberIDs: requiredIDs,
                    turnOwnerID: deletion.turnOwnerID,
                    contributions: retained, historicalContributions: [],
                    excusedMemberIDs: resolvedExcusedIDs, occurrenceDisposition: disposition,
                    occurrenceID: nil, asNeededStatus: nil,
                    isActiveOccurrence: false, isDeleted: true, today: today
                )]
            }
            if revision.isArchived {
                guard let previous = previousConfiguration(before: revision, on: day, snapshot: snapshot) else {
                    return []
                }
                let retained = snapshot.completions.filter {
                    $0.choreID == choreID && $0.day == day && $0.revisionID == previous.id
                        && $0.state.isAccountedFor
                }
                guard !retained.isEmpty else { return [] }
                let retainedIDs = Set(retained.map(\.memberID))
                let members = snapshot.members.filter { retainedIDs.contains($0.id) }
                return [DailyChore(
                    configuration: previous, day: day, eligibleMembers: members,
                    requiredMemberIDs: retainedIDs,
                    turnOwnerID: previous.mode == .alternating ? retained.first?.memberID : nil,
                    contributions: retained, historicalContributions: [], excusedMemberIDs: [], occurrenceDisposition: nil,
                    occurrenceID: nil, asNeededStatus: nil,
                    isActiveOccurrence: false, isDeleted: true, today: today
                )]
            }

            if revision.schedulingMode == .asNeeded {
                let projected = snapshot.asNeededProjection(choreID: choreID, through: day).occurrences.filter {
                    $0.day == day && $0.revisionID == revision.id && $0.status != .withdrawn
                }
                let membersByID = Dictionary(uniqueKeysWithValues: snapshot.members.map { ($0.id, $0) })
                let excusedIDs = Set(snapshot.excuses.filter {
                    $0.day == day && $0.isExcused
                }.map(\.memberID))
                return projected.compactMap { occurrence in
                    let ownerID = occurrence.responsibilityOwnerID ?? occurrence.assignedMemberID ?? (revision.mode == .alternating
                        ? alternatingOwner(choreID: choreID, on: occurrence.day, snapshot: snapshot,
                                           calendar: household.calendar)?.id : nil)
                    let members = revision.mode == .alternating
                        ? ownerID.flatMap { membersByID[$0] }.map { [$0] } ?? []
                        : occurrence.eligibleMemberIDs.compactMap { membersByID[$0] }
                    guard !members.isEmpty else { return nil }
                    let requiredIDs = revision.mode == .alternating
                        ? Set(ownerID.map { [$0] } ?? []) : Set(occurrence.requiredMemberIDs)
                    return DailyChore(
                        configuration: revision, day: day, eligibleMembers: members,
                        requiredMemberIDs: requiredIDs,
                        turnOwnerID: ownerID,
                        contributions: occurrence.contributions.values.sorted { $0.key < $1.key },
                        historicalContributions: [], excusedMemberIDs: excusedIDs,
                        occurrenceDisposition: nil, occurrenceID: occurrence.id,
                        asNeededStatus: occurrence.status, isActiveOccurrence: true,
                        isDeleted: false, today: today
                    )
                }
            }
            let scheduled = revision.schedulingMode == .scheduled
                && revision.weekday.rawValue == weekday
            guard scheduled || !recorded.isEmpty else { return [] }
            let occurrenceExists = scheduled
            let scheduledMembers = occurrenceExists ? eligibleMembers(for: revision, on: day, snapshot: snapshot) : []
            let occurrence = resolveOccurrence(revision: revision, scheduledMembers: scheduledMembers,
                                               choreID: choreID, day: day, snapshot: snapshot,
                                               calendar: household.calendar, swaps: swaps)
            let disposition = snapshot.scheduledOccurrence(
                choreID: choreID, revisionID: revision.id, on: day,
                hasDone: occurrence.activeContributions.contains { $0.state == .done }
                    || SwapRules.preservesSettledTurn(choreID: choreID, day: day, snapshot: snapshot, swaps: swaps)
            )
            let notNeeded = scheduled && disposition?.state == .notNeeded
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
            return [DailyChore(configuration: occurrence.winningRevision, day: day, eligibleMembers: members,
                              requiredMemberIDs: requiredIDs, turnOwnerID: occurrence.scheduledOwner?.id,
                              contributions: occurrence.activeContributions,
                              historicalContributions: occurrence.displacedHistoricalContributions,
                              excusedMemberIDs: Set(snapshot.excuses.filter {
                                  $0.day == day && $0.isExcused
                              }.map(\.memberID)),
                              occurrenceDisposition: notNeeded ? disposition : nil,
                              occurrenceID: nil, asNeededStatus: nil,
                              isActiveOccurrence: occurrenceExists, isDeleted: false,
                              today: today)]
        }.sorted {
            let titleOrder = $0.configuration.title.localizedStandardCompare($1.configuration.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func activeOccurrence(for revision: ChoreRevision, in chores: [DailyChore]) -> DailyChore? {
        chores.first {
            $0.configuration.id == revision.id && $0.isActiveOccurrence && $0.isActionableOccurrence
        }
    }

    static func nextAlternatingOwner(choreID: UUID, on day: CivilDay,
                                     snapshot: HouseholdSnapshot) -> FamilyMember? {
        guard let revision = snapshot.configuration(choreID: choreID, on: day),
              !revision.isArchived, !snapshot.isChoreDeleted(choreID, on: day),
              revision.mode == .alternating,
              revision.schedulingMode == .asNeeded else { return nil }
        return alternatingOwner(choreID: choreID, on: day, snapshot: snapshot,
                                calendar: snapshot.household?.calendar ?? AppCalendar.current)
    }

    static func rotationOwner(choreID: UUID, on day: CivilDay,
                              snapshot: HouseholdSnapshot) -> FamilyMember? {
        alternatingOwner(choreID: choreID, on: day, snapshot: snapshot,
                         calendar: snapshot.household?.calendar ?? AppCalendar.current)
    }

    static func expectedAsNeededOwner(choreID: UUID, on day: CivilDay,
                                      snapshot: HouseholdSnapshot,
                                      projection: AsNeededControlProjection) -> UUID? {
        guard let revision = snapshot.configuration(choreID: choreID, on: day),
              !revision.isArchived, revision.mode == .alternating,
              revision.schedulingMode == .asNeeded else { return nil }
        return alternatingOwner(choreID: choreID, on: day, snapshot: snapshot,
                                calendar: snapshot.household?.calendar ?? AppCalendar.current,
                                asNeededProjection: projection)?.id
    }

    private static func resolveOccurrence(revision: ChoreRevision, scheduledMembers: [FamilyMember],
                                          choreID: UUID, day: CivilDay, snapshot: HouseholdSnapshot,
                                          calendar: Calendar, swaps: [ProjectedSwap]) -> ResolvedOccurrence {
        var owner: FamilyMember?
        if revision.mode == .alternating, !scheduledMembers.isEmpty {
            owner = alternatingOwner(choreID: choreID, on: day, snapshot: snapshot, calendar: calendar, swaps: swaps)
            if let originalOwner = owner {
                let scope = PuntScope(choreID: choreID, revisionID: revision.id, day: day, occurrenceID: nil)
                owner = snapshot.member(PuntRules.project(scope: scope, originalOwnerID: originalOwner.id,
                                                          snapshot: snapshot).ownerID)
                if let currentOwner = owner {
                    owner = snapshot.member(SwapRules.owner(choreID: choreID, day: day,
                                                            baseOwnerID: currentOwner.id, swaps: swaps))
                }
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
            active = owner.flatMap {
                snapshot.alternatingCompletion(choreID: choreID, on: day, memberID: $0.id)
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
                                         snapshot: HouseholdSnapshot,
                                         calendar: Calendar,
                                         asNeededProjection: AsNeededControlProjection? = nil,
                                         swaps: [ProjectedSwap]? = nil) -> FamilyMember? {
        let exchanges = swaps ?? SwapRules.project(snapshot: snapshot, today: day)
        var revisionsByDay: [CivilDay: ChoreRevision] = [:]
        for revision in snapshot.revisions where revision.choreID == choreID && revision.effectiveDay <= day {
            revisionsByDay[revision.effectiveDay] = revision
        }
        let timeline = revisionsByDay.values.sorted { $0.effectiveDay < $1.effectiveDay }
        var alternatingEraStarts: [UUID: CivilDay] = [:]
        var eraStart: CivilDay?
        var wasAlternating = false
        for revision in timeline {
            let isAlternating = revision.mode == .alternating && !revision.isArchived
            if isAlternating {
                if !wasAlternating { eraStart = revision.effectiveDay }
                alternatingEraStarts[revision.id] = eraStart
            } else {
                eraStart = nil
            }
            wasAlternating = isAlternating
        }
        var eventDays: Set<CivilDay> = []
        for entry in timeline.enumerated() {
            let (index, revision) = entry
            guard revision.mode == .alternating, !revision.isArchived,
                  revision.schedulingMode == .scheduled else { continue }
            let end = timeline.indices.contains(index + 1)
                ? min(timeline[index + 1].effectiveDay, day.adding(days: 1, calendar: calendar))
                : day.adding(days: 1, calendar: calendar)
            let startDate = revision.effectiveDay.date(in: calendar)
            let weekday = calendar.component(.weekday, from: startDate)
            let offset = (revision.weekday.rawValue - weekday + 7) % 7
            var occurrence = revision.effectiveDay.adding(days: offset, calendar: calendar)
            while occurrence < end {
                eventDays.insert(occurrence)
                occurrence = occurrence.adding(days: 7, calendar: calendar)
            }
        }
        let asNeeded = asNeededProjection ?? snapshot.asNeededProjection(choreID: choreID, through: day)
        eventDays.formUnion(asNeeded.occurrences.map(\.day))
        eventDays.formUnion(asNeeded.turnAdvances.map(\.day))
        let factOrder = Dictionary(uniqueKeysWithValues: snapshot.orderedFacts.enumerated().map { ($0.element.id, $0.offset) })

        var priorOwnerID: UUID?
        var activeEraStart: CivilDay?
        var activeOwnerID: UUID?
        for eventDay in eventDays.sorted() {
            guard let revision = snapshot.configuration(choreID: choreID, on: eventDay),
                  !revision.isArchived, revision.mode == .alternating else { continue }
            let eventEraStart = alternatingEraStarts[revision.id]
            if activeEraStart != eventEraStart {
                priorOwnerID = nil
                activeEraStart = eventEraStart
            }
            let eligibleIDs = Set(snapshot.members.filter {
                $0.role == .child && $0.isActive(on: eventDay) && revision.memberIDs.contains($0.id)
            }.map(\.id))
            switch revision.schedulingMode {
            case .scheduled:
                let weekday = calendar.component(.weekday, from: eventDay.date(in: calendar))
                guard revision.weekday.rawValue == weekday,
                      let ownerID = nextOwner(after: priorOwnerID, participants: revision.memberIDs,
                                              eligibleIDs: eligibleIDs) else { continue }
                if eventDay == day { activeOwnerID = ownerID }
                let legacyResponsibleID = PuntRules.project(
                    scope: PuntScope(choreID: choreID, revisionID: revision.id,
                                     day: eventDay, occurrenceID: nil),
                    originalOwnerID: ownerID, snapshot: snapshot
                ).ownerID
                let responsibleID = SwapRules.owner(choreID: choreID, day: eventDay,
                                                    baseOwnerID: legacyResponsibleID, swaps: exchanges)
                let hasDone = snapshot.alternatingCompletion(choreID: choreID, on: eventDay,
                                                              memberID: responsibleID)?.state == .done
                    || SwapRules.preservesSettledTurn(choreID: choreID, day: eventDay, snapshot: snapshot, swaps: exchanges)
                let disposition = snapshot.scheduledOccurrence(choreID: choreID, revisionID: revision.id,
                                                               on: eventDay, hasDone: hasDone)
                let keepsTurn = disposition?.alternatingSkipBehavior == .keepTurn
                if !keepsTurn { priorOwnerID = ownerID }
            case .asNeeded:
                enum Event {
                    case occurrence(ProjectedAsNeededOccurrence)
                    case advance(AcceptedAsNeededTurnAdvance)
                }
                var events: [(Int, Event)] = []
                events += asNeeded.occurrences.filter {
                    $0.revisionID == revision.id && $0.day == eventDay
                }.map { (factOrder[$0.activationFactID] ?? .max, .occurrence($0)) }
                events += asNeeded.turnAdvances.filter {
                    $0.revisionID == revision.id && $0.day == eventDay
                }.map { (factOrder[$0.factID] ?? .max, .advance($0)) }
                for (_, event) in events.sorted(by: { $0.0 < $1.0 }) {
                    switch event {
                    case .advance(let advance):
                        guard eligibleIDs.count > 1,
                              nextOwner(after: priorOwnerID, participants: revision.memberIDs,
                                        eligibleIDs: eligibleIDs) == advance.ownerID else { continue }
                        priorOwnerID = advance.ownerID
                    case .occurrence(let occurrence):
                        guard let ownerID = occurrence.assignedMemberID
                                ?? nextOwner(after: priorOwnerID, participants: revision.memberIDs,
                                             eligibleIDs: eligibleIDs),
                              eligibleIDs.contains(ownerID) else { continue }
                        if eventDay == day && occurrence.status == .open { activeOwnerID = ownerID }
                        if occurrence.consumedTurn || occurrence.isLegacy && occurrence.assignedMemberID == nil {
                            priorOwnerID = ownerID
                        }
                    }
                }
            }
        }
        if let activeOwnerID { return snapshot.member(activeOwnerID) }
        guard let revision = snapshot.configuration(choreID: choreID, on: day),
              !revision.isArchived, revision.mode == .alternating,
              revision.schedulingMode == .asNeeded else { return nil }
        if activeEraStart != alternatingEraStarts[revision.id] { priorOwnerID = nil }
        let ownerID = nextOwner(after: priorOwnerID, participants: revision.memberIDs,
                                eligibleIDs: Set(snapshot.members.filter {
                                    $0.role == .child && $0.isActive(on: day)
                                        && revision.memberIDs.contains($0.id)
                                }.map(\.id)))
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

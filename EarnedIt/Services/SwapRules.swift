import Foundation

struct SwapRequest: Codable, Equatable {
    let scope: ChoreScope
    let requesterID: UUID
    let recipientID: UUID
    let repaymentDay: CivilDay
}

enum SwapDecisionKind: String, Codable, Equatable {
    case accepted, declined, cancelled
}

struct SwapDecision: Codable, Equatable {
    let requestFactID: UUID
    let memberID: UUID
    let day: CivilDay
    let kind: SwapDecisionKind
}

enum SwapStatus: String, Equatable {
    case pending, accepted, declined, cancelled, expired, completed, ended, released
}

struct ProjectedSwap: Identifiable, Equatable {
    let id: UUID
    let request: SwapRequest
    var status: SwapStatus = .pending
    var decisionFactID: UUID?
    var wasAccepted = false
    var repaymentCancelled = false

    var participantIDs: Set<UUID> { [request.requesterID, request.recipientID] }
    var isActive: Bool { status == .pending || status == .accepted }
}

enum SwapRules {
    static let repaymentWindow = 28

    /// As Needed has no scheduled repayment date. It cannot promise a dated exchange.
    static func repaymentDay(for chore: DailyChore, recipientID: UUID,
                             snapshot: HouseholdSnapshot) -> CivilDay? {
        guard let household = snapshot.household, chore.configuration.mode == .alternating,
              chore.configuration.schedulingMode == .scheduled, chore.occurrenceID == nil else { return nil }
        for offset in 1...repaymentWindow {
            let day = chore.day.adding(days: offset, calendar: household.calendar)
            guard let revision = snapshot.configuration(choreID: chore.choreID, on: day),
                  compatible(revision, with: chore.configuration), !snapshot.isChoreDeleted(chore.choreID, on: day),
                  snapshot.member(recipientID)?.isActive(on: day) == true,
                  revision.weekday.rawValue == household.calendar.component(.weekday, from: day.date(in: household.calendar))
            else { continue }
            if ChoreRules.rotationOwner(choreID: chore.choreID, on: day, snapshot: snapshot)?.id == recipientID {
                return day
            }
        }
        return nil
    }

    private static func compatible(_ revision: ChoreRevision, with original: ChoreRevision) -> Bool {
        !revision.isArchived && revision.mode == .alternating && revision.schedulingMode == .scheduled
            && revision.weekday == original.weekday && revision.memberIDs == original.memberIDs
    }

    private static func source(_ request: SwapRequest, snapshot: HouseholdSnapshot) -> DailyChore? {
        guard ChoreRules.rotationOwner(choreID: request.scope.choreID, on: request.scope.day, snapshot: snapshot)?.id == request.requesterID,
              request.participants.allSatisfy({ snapshot.member($0)?.isActive(on: request.scope.day) == true }) else { return nil }
        let legacy = PuntRules.project(scope: PuntScope(choreID: request.scope.choreID,
            revisionID: request.scope.revisionID, day: request.scope.day, occurrenceID: nil),
            originalOwnerID: request.requesterID, snapshot: snapshot)
        guard legacy.pending == nil, legacy.accepted == nil else { return nil }
        return ChoreRules.dailyList(snapshot: snapshot, day: request.scope.day, today: request.scope.day).first {
            ChoreScope($0) == request.scope && !$0.isDeleted && !$0.isNotNeeded
                && $0.isScheduledOccurrence && $0.turnOwnerID == request.requesterID
                && $0.contributions.allSatisfy { !$0.state.isAccountedFor }
        }
    }

    private static func isAccounted(_ request: SwapRequest, repayment: Bool,
                                    snapshot: HouseholdSnapshot) -> Bool {
        let day = repayment ? request.repaymentDay : request.scope.day
        let member = repayment ? request.requesterID : request.recipientID
        return snapshot.alternatingCompletion(choreID: request.scope.choreID, on: day,
                                               memberID: member)?.state.isAccountedFor == true
    }

    private static func repaymentAvailable(_ request: SwapRequest, snapshot: HouseholdSnapshot) -> Bool {
        guard let original = snapshot.revisions.first(where: { $0.id == request.scope.revisionID }),
              let revision = snapshot.configuration(choreID: request.scope.choreID, on: request.repaymentDay),
              compatible(revision, with: original),
              !snapshot.isChoreDeleted(request.scope.choreID, on: request.repaymentDay),
              request.participants.allSatisfy({ snapshot.member($0)?.isActive(on: request.repaymentDay) == true }),
              ChoreRules.rotationOwner(choreID: request.scope.choreID, on: request.repaymentDay,
                                       snapshot: snapshot)?.id == request.recipientID else { return false }
        return snapshot.scheduledOccurrence(choreID: request.scope.choreID, revisionID: revision.id,
                                            on: request.repaymentDay, hasDone: false) == nil
    }

    /// Replay globally, rather than per chore, to reserve both children's eligibility.
    /// Acceptance reads only its preceding journal. Later offline facts cannot silently
    /// move an approval across an already completed turn or resurrect a released exchange.
    static func project(snapshot: HouseholdSnapshot, today: CivilDay) -> [ProjectedSwap] {
        guard snapshot.replaysSwaps, snapshot.orderedFacts.contains(where: {
            if case .swapRequest = $0.body { return true }; return false
        }), let household = snapshot.household else { return [] }
        var result: [ProjectedSwap] = []
        var prefix: [HouseholdFact] = []
        var used: Set<String> = []
        func endpoint(_ choreID: UUID, _ day: CivilDay) -> String { "\(choreID)/\(day)" }
        func settle(_ current: CivilDay, _ state: HouseholdSnapshot) {
            for index in result.indices where result[index].isActive {
                let request = result[index].request
                if result[index].status == .pending {
                    if current > request.scope.day || source(request, snapshot: state) == nil
                        || !repaymentAvailable(request, snapshot: state) {
                        result[index].status = .expired
                    }
                } else {
                    let paid = isAccounted(request, repayment: true, snapshot: state)
                    let covered = isAccounted(request, repayment: false, snapshot: state)
                    // Done wins a concurrent Not Needed fact. A cancelled promise never revives.
                    let sourceDisposition = state.configuration(choreID: request.scope.choreID, on: request.scope.day).flatMap {
                        state.scheduledOccurrence(choreID: request.scope.choreID, revisionID: $0.id,
                                                  on: request.scope.day, hasDone: covered)
                    }
                    let sourceRemoved = !covered && (state.isChoreDeleted(request.scope.choreID, on: request.scope.day)
                        || sourceDisposition != nil)
                    if sourceRemoved || !paid && !repaymentAvailable(request, snapshot: state) {
                        result[index].repaymentCancelled = true
                        result[index].status = .released
                    } else if paid && covered {
                        result[index].status = .completed
                    } else if current > request.repaymentDay.adding(days: 1, calendar: household.calendar) {
                        result[index].status = .ended
                    }
                }
            }
        }
        for fact in snapshot.orderedFacts {
            switch fact.body {
            case .swapRequest(let request):
                defer { prefix.append(fact) }
                let state = HouseholdSnapshot(facts: prefix, replaysSwaps: false)
                settle(request.scope.day, state)
                guard fact.authorMemberID == request.requesterID, request.requesterID != request.recipientID,
                      request.participants.allSatisfy({ state.member($0)?.role == .child }),
                      !result.contains(where: { $0.isActive && !$0.participantIDs.isDisjoint(with: request.participants) }),
                      !used.contains(endpoint(request.scope.choreID, request.scope.day)),
                      !used.contains(endpoint(request.scope.choreID, request.repaymentDay)),
                      let chore = source(request, snapshot: state),
                      repaymentDay(for: chore, recipientID: request.recipientID, snapshot: state) == request.repaymentDay,
                      repaymentAvailable(request, snapshot: state) else { continue }
                result.append(ProjectedSwap(id: fact.id, request: request))
            case .swapDecision(let decision):
                defer { prefix.append(fact) }
                let state = HouseholdSnapshot(facts: prefix, replaysSwaps: false)
                settle(decision.day, state)
                guard let index = result.firstIndex(where: { $0.id == decision.requestFactID }),
                      result[index].status == .pending,
                      fact.authorMemberID == decision.memberID,
                      decision.day == result[index].request.scope.day else { continue }
                let request = result[index].request
                guard decision.memberID == (decision.kind == .cancelled ? request.requesterID : request.recipientID)
                else { continue }
                result[index].decisionFactID = fact.id
                switch decision.kind {
                case .accepted:
                    result[index].wasAccepted = true
                    result[index].status = .accepted
                    used.insert(endpoint(request.scope.choreID, request.scope.day))
                    used.insert(endpoint(request.scope.choreID, request.repaymentDay))
                case .declined: result[index].status = .declined
                case .cancelled: result[index].status = .cancelled
                }
            default:
                // A valid exchanged Done wins a concurrent disposition under every arrival
                // order. Omit only that disposition from the rotation replay, never the journal.
                if case .occurrence(let disposition) = fact.body, disposition.state == .notNeeded,
                   result.contains(where: { swap in
                       guard swap.wasAccepted, swap.request.scope.choreID == disposition.choreID else { return false }
                       if disposition.day == swap.request.scope.day {
                           return isAccounted(swap.request, repayment: false, snapshot: snapshot)
                       }
                       return disposition.day == swap.request.repaymentDay
                           && isAccounted(swap.request, repayment: true, snapshot: snapshot)
                   }) { continue }
                prefix.append(fact)
                if result.contains(where: { $0.isActive }) && affectsExchange(fact, swaps: result) {
                    // Reconcile structural changes as soon as they enter the journal, including
                    // future effective changes. Historical accepted source turns stay bound.
                    settle(household.createdDay, HouseholdSnapshot(facts: prefix, replaysSwaps: false))
                }
            }
        }
        settle(today, HouseholdSnapshot(facts: prefix, replaysSwaps: false))
        // A correction changes credit without reopening a settled exchange or claiming
        // both turns are still complete. Later exchanges retain their original admission.
        for index in result.indices where result[index].status == .completed {
            let request = result[index].request
            if !isAccounted(request, repayment: false, snapshot: snapshot)
                || !isAccounted(request, repayment: true, snapshot: snapshot) {
                result[index].status = .ended
            }
        }
        return result
    }

    private static func affectsExchange(_ fact: HouseholdFact, swaps: [ProjectedSwap]) -> Bool {
        let active = swaps.filter(\.isActive)
        let choreIDs = Set(active.map { $0.request.scope.choreID })
        switch fact.body {
        case .member(let member): return active.contains { $0.participantIDs.contains(member.id) }
        case .chore(let revision): return choreIDs.contains(revision.choreID)
        case .completion(let completion): return choreIDs.contains(completion.choreID)
        case .occurrence(let occurrence): return choreIDs.contains(occurrence.choreID)
        case .scheduledOccurrenceRestoration(let restoration): return choreIDs.contains(restoration.choreID)
        case .choreDeletion(let deletion): return choreIDs.contains(deletion.choreID)
        case .occurrenceAwareChoreDeletion(let deletion): return choreIDs.contains(deletion.choreID)
        default: return false
        }
    }

    static func owner(choreID: UUID, day: CivilDay, baseOwnerID: UUID,
                      swaps: [ProjectedSwap]) -> UUID {
        for swap in swaps where swap.wasAccepted
            && swap.request.scope.choreID == choreID {
            if day == swap.request.scope.day { return swap.request.recipientID }
            if day == swap.request.repaymentDay && !swap.repaymentCancelled { return swap.request.requesterID }
        }
        return baseOwnerID
    }

    static func candidates(for chore: DailyChore, actor: FamilyMember,
                           snapshot: HouseholdSnapshot, today: CivilDay) -> [(FamilyMember, CivilDay)] {
        guard actor.role == .child, chore.day == today, chore.turnOwnerID == actor.id,
              chore.isScheduledOccurrence, !chore.isNotNeeded, !chore.isDeleted,
              chore.contributions.allSatisfy({ !$0.state.isAccountedFor }) else { return [] }
        let swaps = project(snapshot: snapshot, today: today)
        guard !swaps.contains(where: { $0.isActive && $0.participantIDs.contains(actor.id) }),
              !swaps.contains(where: { $0.wasAccepted && $0.request.scope.choreID == chore.choreID
                  && ($0.request.scope.day == today || $0.request.repaymentDay == today) }) else { return [] }
        let state = snapshot
        guard ChoreRules.rotationOwner(choreID: chore.choreID, on: today, snapshot: state)?.id == actor.id else { return [] }
        let legacy = PuntRules.project(scope: PuntRules.scope(for: chore), originalOwnerID: actor.id, snapshot: state)
        guard legacy.pending == nil, legacy.accepted == nil else { return [] }
        return ChoreRules.eligibleMembers(for: chore.configuration, on: today, snapshot: state).compactMap { child in
            guard child.id != actor.id,
                  !swaps.contains(where: { $0.isActive && $0.participantIDs.contains(child.id) }),
                  let repayment = repaymentDay(for: chore, recipientID: child.id, snapshot: state),
                  !swaps.contains(where: { $0.wasAccepted && $0.request.scope.choreID == chore.choreID
                      && ($0.request.scope.day == repayment || $0.request.repaymentDay == repayment) }),
                  repaymentAvailable(SwapRequest(scope: ChoreScope(chore), requesterID: actor.id,
                      recipientID: child.id, repaymentDay: repayment), snapshot: state) else { return nil }
            return (child, repayment)
        }
    }
}

private extension SwapRequest {
    var participants: Set<UUID> { [requesterID, recipientID] }
}

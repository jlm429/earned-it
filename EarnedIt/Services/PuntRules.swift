import Foundation

struct PuntScope: Codable, Equatable, Hashable {
    let choreID: UUID
    let revisionID: UUID
    let day: CivilDay
    let occurrenceID: UUID?
}

struct PuntRequest: Codable, Equatable {
    let scope: PuntScope
    let requesterID: UUID
    let recipientID: UUID
}

enum PuntDecisionKind: String, Codable, Equatable {
    case accepted, declined, cancelled
}

struct PuntDecision: Codable, Equatable {
    let requestFactID: UUID
    let scope: PuntScope
    let day: CivilDay
    let memberID: UUID
    let kind: PuntDecisionKind
}

enum PuntStatus: String, Equatable {
    case pending, accepted, declined, cancelled, expired
}

struct ProjectedPunt: Identifiable, Equatable {
    let id: UUID
    let request: PuntRequest
    var status: PuntStatus
    var decisionFactID: UUID?
}

struct PuntProjection {
    var ownerID: UUID
    var requests: [ProjectedPunt] = []
    var isClosed = false
    var pending: ProjectedPunt? { requests.last { $0.status == .pending } }
    var accepted: ProjectedPunt? { requests.first { $0.status == .accepted } }
}

enum PuntRules {
    static func scope(for chore: DailyChore) -> PuntScope {
        PuntScope(choreID: chore.choreID, revisionID: chore.configuration.id,
                  day: chore.day, occurrenceID: chore.occurrenceID)
    }

    /// One approved punt per occurrence. The original owner still consumes the rotation slot.
    /// Facts replay in Lamport order, so a closed occurrence cannot acquire a new owner.
    static func project(scope: PuntScope, originalOwnerID: UUID,
                        snapshot: HouseholdSnapshot, today: CivilDay? = nil) -> PuntProjection {
        var result = PuntProjection(ownerID: originalOwnerID)
        guard let household = snapshot.household,
              let revision = snapshot.revisions.first(where: { $0.id == scope.revisionID }),
              revision.choreID == scope.choreID, revision.mode == .alternating else { return result }
        let eligible = Set(ChoreRules.eligibleMembers(for: revision, on: scope.day, snapshot: snapshot).map(\.id))
        let matchesConfiguration = snapshot.configuration(choreID: scope.choreID, on: scope.day)?.id == revision.id
        var activated = scope.occurrenceID == nil && revision.schedulingMode == .scheduled
            && revision.weekday.rawValue == household.calendar.component(
                .weekday, from: scope.day.date(in: household.calendar))
        var closed = !matchesConfiguration || !eligible.contains(originalOwnerID)
        var controlHeadID: UUID?
        let capabilityIndex = snapshot.occurrenceCapabilityIndex
        for (index, fact) in snapshot.orderedFacts.enumerated() {
            switch fact.body {
            case .asNeededOccurrence(let value) where value.id == scope.occurrenceID
                && value.choreID == scope.choreID && value.revisionID == scope.revisionID && value.day == scope.day:
                activated = value.assignedMemberID == originalOwnerID
                controlHeadID = fact.id
            case .occurrence(let value) where value.choreID == scope.choreID
                && value.revisionID == scope.revisionID && value.day == scope.day:
                if value.state == .available && fact.id == scope.occurrenceID {
                    activated = value.assignedMemberID == nil || value.assignedMemberID == originalOwnerID
                    controlHeadID = fact.id
                } else if value.state == .notNeeded { closed = true }
            case .choreDeletion(let value) where value.choreID == scope.choreID && value.day <= scope.day:
                closed = true
            case .occurrenceAwareChoreDeletion(let value) where value.choreID == scope.choreID && value.day <= scope.day:
                closed = true
            case .asNeededOccurrenceResolution(let value) where value.occurrenceID == scope.occurrenceID
                && value.revisionID == scope.revisionID && value.day == scope.day:
                if value.expectedControlHeadID == controlHeadID,
                   fact.authorMemberID == value.recordedByMemberID,
                   snapshot.member(value.recordedByMemberID)?.role == .parent { closed = true }
            case .completion(let value) where activated && (scope.occurrenceID == nil
                || (revision.schedulingMode == .asNeeded && index < capabilityIndex))
                && value.choreID == scope.choreID && value.revisionID == scope.revisionID && value.day == scope.day:
                if value.memberID == result.ownerID, fact.authorMemberID == value.recordedByMemberID,
                   value.recordedByMemberID == value.memberID || snapshot.member(value.recordedByMemberID)?.role == .parent {
                    controlHeadID = fact.id
                    if value.state.isAccountedFor { closed = true }
                }
            case .asNeededOccurrenceCompletion(let value) where value.occurrenceID == scope.occurrenceID
                && value.revisionID == scope.revisionID && value.day == scope.day:
                if value.memberID == result.ownerID, fact.authorMemberID == value.recordedByMemberID,
                   value.recordedByMemberID == value.memberID || snapshot.member(value.recordedByMemberID)?.role == .parent {
                    controlHeadID = fact.id
                    if value.state.isAccountedFor { closed = true }
                }
            case .puntRequest(let request) where request.scope == scope:
                guard activated, !closed, result.pending == nil, result.accepted == nil,
                      request.requesterID == result.ownerID,
                      fact.authorMemberID == request.requesterID,
                      request.requesterID != request.recipientID,
                      eligible.contains(request.recipientID),
                      snapshot.member(request.requesterID)?.role == .child else { continue }
                result.requests.append(ProjectedPunt(id: fact.id, request: request, status: .pending))
            case .puntDecision(let decision) where decision.scope == scope:
                guard activated, !closed, decision.day == scope.day,
                      fact.authorMemberID == decision.memberID,
                      let index = result.requests.firstIndex(where: { $0.id == decision.requestFactID }),
                      result.requests[index].status == .pending else { continue }
                let request = result.requests[index].request
                let expectedActor = decision.kind == .cancelled ? request.requesterID : request.recipientID
                guard expectedActor == decision.memberID, eligible.contains(decision.memberID) else { continue }
                result.requests[index].decisionFactID = fact.id
                switch decision.kind {
                case .accepted:
                    result.requests[index].status = .accepted
                    result.ownerID = request.recipientID
                case .declined: result.requests[index].status = .declined
                case .cancelled: result.requests[index].status = .cancelled
                }
            default: break
            }
        }
        result.isClosed = closed || !activated || today.map { $0 != scope.day } == true
        if result.isClosed {
            for index in result.requests.indices where result.requests[index].status == .pending {
                result.requests[index].status = .expired
            }
        }
        return result
    }
}

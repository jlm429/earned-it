import Foundation

struct FamilyActivity: Identifiable, Equatable {
    let id: UUID
    let recipientIDs: Set<UUID>
    let title: String
    let detail: String
    let day: CivilDay?
    let punt: ProjectedPunt?
    var swap: ProjectedSwap? = nil
    var isAlertEligible = true
}

enum FamilyActivityRules {
    static func activity(snapshot: HouseholdSnapshot, today: CivilDay) -> [FamilyActivity] {
        guard let household = snapshot.household else { return [] }
        func date(_ day: CivilDay) -> String { AppCalendar.displayDay(day, calendar: household.calendar) }
        func name(_ id: UUID) -> String { snapshot.member(id)?.displayName ?? "Family member" }
        func parents(on day: CivilDay) -> Set<UUID> {
            Set(snapshot.members.filter { $0.role == .parent && snapshot.isActive($0, on: day) }.map(\.id))
        }
        func recipients(_ revision: ChoreRevision, on day: CivilDay) -> Set<UUID> {
            Set(ChoreRules.eligibleMembers(for: revision, on: day, snapshot: snapshot).map(\.id))
        }
        let swaps = SwapRules.project(snapshot: snapshot, today: today)
        var nudgeIDs: Set<UUID> = []
        return snapshot.orderedFacts.reversed().compactMap { fact in
            var activityID = fact.id
            var targets: Set<UUID> = []
            var title = ""
            var detail = ""
            var day: CivilDay?
            var punt: ProjectedPunt?
            var swap: ProjectedSwap?
            let author = fact.authorMemberID.flatMap { snapshot.member($0) }
            switch fact.body {
            case .bonusAward(let award) where author?.role == .parent:
                targets = [award.memberID]
                title = "Bonus awarded"
                detail = "\(name(award.recordedByMemberID)) awarded you \(award.amount.formatted())."
                if !award.note.isEmpty { detail += " \(award.note)" }
                day = award.day
            case .choreNudge(let nudge) where author?.role == .parent:
                guard nudge.scope.day == today,
                      let chore = ChoreRules.dailyList(snapshot: snapshot, day: today, today: today).first(where: {
                          ChoreScope($0) == nudge.scope
                      }), FamilyExtrasRules.nudgeTargets(for: chore).contains(where: { $0.id == nudge.memberID })
                else { return nil }
                activityID = nudge.activityID(householdID: fact.householdID)
                guard nudgeIDs.insert(activityID).inserted else { return nil }
                targets = [nudge.memberID]
                title = "A little reminder"
                detail = "Your parent reminded you about \(chore.configuration.title). It is still on your list today."
                day = today
            case .swapRequest(let request):
                guard let projected = swaps.first(where: { $0.id == fact.id }) else { return nil }
                targets = [request.requesterID, request.recipientID]
                let chore = snapshot.revisions.first { $0.id == request.scope.revisionID }?.title ?? "this chore"
                title = "Swap turns"
                detail = "\(name(request.requesterID)) asks \(name(request.recipientID)) to cover \(chore) on \(date(request.scope.day)). In return, \(name(request.requesterID)) covers \(date(request.repaymentDay))."
                day = request.scope.day
                swap = projected
            case .swapDecision(let decision):
                guard let projected = swaps.first(where: {
                    $0.id == decision.requestFactID && $0.decisionFactID == fact.id
                }) else { return nil }
                targets = projected.participantIDs.union(parents(on: projected.request.scope.day))
                title = "Swap \(decision.kind.rawValue)"
                detail = "\(name(decision.memberID)) \(decision.kind.rawValue) the turn exchange."
                if decision.kind == .accepted {
                    detail += " \(name(projected.request.recipientID)) covers \(date(projected.request.scope.day)); \(name(projected.request.requesterID)) covers \(date(projected.request.repaymentDay))."
                }
                day = decision.day
            case .chore(let revision) where author?.role == .parent:
                guard snapshot.configuration(choreID: revision.choreID, on: revision.effectiveDay)?.id == revision.id else { return nil }
                // An inactive As Needed definition is management, not a request to do it.
                guard revision.schedulingMode == .scheduled || revision.isArchived else { return nil }
                targets = recipients(revision, on: revision.effectiveDay)
                title = revision.isArchived ? "Chore archived" : "Chore requested"
                detail = "\(author!.displayName) \(revision.isArchived ? "archived" : "assigned") \(revision.title). Starts \(revision.effectiveDay)."
                day = revision.effectiveDay
            case .asNeededOccurrence(let occurrence):
                guard author?.role == .parent,
                      let revision = snapshot.revisions.first(where: { $0.id == occurrence.revisionID }),
                      snapshot.asNeededProjection(choreID: occurrence.choreID, through: occurrence.day)
                        .occurrences.contains(where: { $0.id == occurrence.id }) else { return nil }
                targets = recipients(revision, on: occurrence.day)
                title = "Chore available"
                detail = "\(revision.title) is available today."
                if let owner = occurrence.assignedMemberID { detail += " It is \(name(owner))’s turn." }
                day = occurrence.day
            case .occurrence(let occurrence):
                guard author?.role == .parent,
                      let revision = snapshot.revisions.first(where: { $0.id == occurrence.revisionID }) else { return nil }
                targets = recipients(revision, on: occurrence.day)
                title = occurrence.state == .available ? "Chore available" : "Chore not needed"
                detail = "\(revision.title): \(occurrence.state == .available ? "available" : "not needed") on \(occurrence.day)."
                day = occurrence.day
            case .scheduledOccurrenceRestoration(let restoration):
                guard author?.role == .parent,
                      let revision = snapshot.revisions.first(where: { $0.id == restoration.revisionID }) else { return nil }
                targets = recipients(revision, on: restoration.day)
                title = "Chore available again"
                detail = "\(revision.title) is required on \(restoration.day)."
                day = restoration.day
            case .asNeededOccurrenceResolution(let resolution):
                guard author?.role == .parent,
                      let revision = snapshot.revisions.first(where: { $0.id == resolution.revisionID }),
                      snapshot.asNeededProjection(choreID: resolution.choreID, through: resolution.day)
                        .occurrences.contains(where: { $0.id == resolution.occurrenceID && $0.status == .withdrawn }) else { return nil }
                targets = recipients(revision, on: resolution.day)
                title = "Chore withdrawn"
                detail = "\(revision.title) is no longer needed on \(resolution.day)."
                day = resolution.day
            case .asNeededTurnAdvance(let advance):
                guard author?.role == .parent,
                      let revision = snapshot.revisions.first(where: { $0.id == advance.revisionID }),
                      snapshot.asNeededProjection(choreID: advance.choreID, through: advance.day)
                        .turnAdvances.contains(where: { $0.factID == fact.id }) else { return nil }
                targets = recipients(revision, on: advance.day)
                title = "Turn skipped"
                detail = "Your parent skipped \(name(advance.expectedMemberID))’s next turn for \(revision.title)."
                day = advance.day
            case .choreDeletion(let deletion):
                guard author?.role == .parent else { return nil }
                targets = Set(deletion.eligibleMemberIDs ?? [])
                title = "Chore removed"
                detail = "Your parent removed a chore. Recorded history is kept."
                day = deletion.day
            case .occurrenceAwareChoreDeletion(let deletion):
                guard author?.role == .parent,
                      let revision = snapshot.revisions.first(where: { $0.id == deletion.revisionID }) else { return nil }
                targets = recipients(revision, on: deletion.day)
                title = "Chore removed"
                detail = "Your parent removed \(revision.title). Recorded history is kept."
                day = deletion.day
            case .puntRequest(let request):
                guard let ownerID = PuntRules.originalOwner(scope: request.scope, snapshot: snapshot) else { return nil }
                let projection = PuntRules.project(scope: request.scope, originalOwnerID: ownerID,
                                                   snapshot: snapshot, today: today)
                guard let projected = projection.requests.first(where: { $0.id == fact.id }) else { return nil }
                targets = [request.requesterID, request.recipientID]
                title = "Earlier turn request"
                let chore = snapshot.revisions.first { $0.id == request.scope.revisionID }?.title ?? "Chore"
                detail = "\(name(request.requesterID)) asked \(name(request.recipientID)) to take \(chore) today."
                day = request.scope.day
                punt = projected
            case .puntDecision(let decision):
                guard let source = snapshot.orderedFacts.first(where: { $0.id == decision.requestFactID }),
                      case .puntRequest(let request) = source.body,
                      let ownerID = PuntRules.originalOwner(scope: request.scope, snapshot: snapshot),
                      let projected = PuntRules.project(scope: request.scope, originalOwnerID: ownerID,
                                                        snapshot: snapshot).requests.first(where: {
                          $0.id == source.id && $0.decisionFactID == fact.id
                      }) else { return nil }
                targets = decision.kind == .cancelled ? [request.recipientID] : [request.requesterID]
                title = "Earlier turn request \(projected.status.rawValue)"
                detail = "\(name(decision.memberID)) \(projected.status.rawValue) the turn request."
                day = request.scope.day
            case .completion(let completion):
                targets = author?.role == .parent ? [completion.memberID] : parents(on: completion.day)
                title = author?.role == .parent ? "Chore updated" : "Chore progress"
                let chore = snapshot.revisions.first { $0.id == completion.revisionID }?.title ?? "Chore"
                detail = "\(name(completion.recordedByMemberID)) marked \(chore) \(completion.state.rawValue.lowercased()) for \(name(completion.memberID)) on \(completion.day)."
                day = completion.day
            case .asNeededOccurrenceCompletion(let completion):
                let projected = snapshot.asNeededProjection(choreID: completion.choreID, through: completion.day)
                guard projected.occurrences.contains(where: {
                    $0.id == completion.occurrenceID && $0.contributions[completion.memberID] == completion.datedCompletion
                }) else { return nil }
                targets = author?.role == .parent ? [completion.memberID] : parents(on: completion.day)
                title = author?.role == .parent ? "Chore updated" : "Chore progress"
                let chore = snapshot.revisions.first { $0.id == completion.revisionID }?.title ?? "Chore"
                detail = "\(name(completion.recordedByMemberID)) marked \(chore) \(completion.state.rawValue.lowercased()) for \(name(completion.memberID)) on \(completion.day)."
                day = completion.day
            case .excuse(let excuse) where author?.role == .parent:
                targets = [excuse.memberID]
                title = excuse.isExcused ? "Day excused" : "Excuse removed"
                detail = "\(excuse.day): \(excuse.isExcused ? "your day is excused" : "your usual requirements apply")."
                day = excuse.day
            case .allowance(let allowance) where author?.role == .parent:
                targets = [allowance.memberID]
                title = "Allowance updated"
                detail = "Your parent updated your allowance starting the week of \(allowance.effectiveWeek)."
                day = allowance.effectiveWeek
            case .request(let request):
                targets = parents(on: today)
                title = "Profile access requested"
                detail = "A family installation requested approved profile access. Review in Manage Family."
                guard !snapshot.grants.contains(where: { $0.requestID == request.id }) else { return nil }
            case .grant(let grant) where author?.role == .parent:
                targets = Set(snapshot.requests.first { $0.id == grant.requestID }?.memberIDs ?? [])
                title = grant.memberIDs.isEmpty ? "Profile access removed" : "Profile access approved"
                detail = "A parent updated this installation’s approved profiles."
            default: return nil
            }
            if let authorID = fact.authorMemberID, punt == nil, swap == nil { targets.remove(authorID) }
            guard !targets.isEmpty else { return nil }
            return FamilyActivity(id: activityID, recipientIDs: targets, title: title, detail: detail, day: day,
                                  punt: punt, swap: swap,
                                  isAlertEligible: swap == nil || swap?.status == .pending)
        }
    }
}

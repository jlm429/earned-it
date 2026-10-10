import Foundation

enum AsNeededOccurrenceStatus: Equatable {
    case open
    case completed
    case withdrawn
}

struct ProjectedAsNeededOccurrence: Equatable, Identifiable {
    let id: UUID
    let activationFactID: UUID
    let choreID: UUID
    let revisionID: UUID
    let day: CivilDay
    let eligibleMemberIDs: [UUID]
    let requiredMemberIDs: [UUID]
    let assignedMemberID: UUID?
    var responsibilityOwnerID: UUID? = nil
    let isLegacy: Bool
    var status: AsNeededOccurrenceStatus
    var contributions: [UUID: DatedCompletion]
    var closureFactID: UUID?
    var consumedTurn: Bool

    var isFullyComplete: Bool {
        if let owner = responsibilityOwnerID { return contributions[owner]?.state == .done }
        if requiredMemberIDs.isEmpty {
            return contributions.values.contains { $0.state == .done }
        }
        return requiredMemberIDs.allSatisfy { contributions[$0]?.state == .done }
    }
}

struct AcceptedAsNeededTurnAdvance: Equatable {
    let factID: UUID
    let choreID: UUID
    let revisionID: UUID
    let day: CivilDay
    let ownerID: UUID
}

struct AsNeededControlProjection: Equatable {
    var occurrences: [ProjectedAsNeededOccurrence] = []
    var turnAdvances: [AcceptedAsNeededTurnAdvance] = []
    var controlHeadID: UUID?

    var openOccurrence: ProjectedAsNeededOccurrence? {
        occurrences.last { $0.status == .open }
    }
}

extension HouseholdSnapshot {
    func asNeededProjection(choreID: UUID, through day: CivilDay) -> AsNeededControlProjection {
        let facts = orderedFacts
        let deletionIndex = facts.firstIndex { fact in
            if case .choreDeletion(let deletion) = fact.body { return deletion.choreID == choreID }
            if case .occurrenceAwareChoreDeletion(let deletion) = fact.body { return deletion.choreID == choreID }
            return false
        } ?? facts.endIndex
        let capabilityIndex = occurrenceCapabilityIndex

        var legacyWinnerByDay: [CivilDay: UUID] = [:]
        for (index, fact) in facts.enumerated() where index < deletionIndex && index < capabilityIndex {
            guard case .occurrence(let occurrence) = fact.body,
                  occurrence.choreID == choreID, occurrence.day <= day,
                  occurrence.state == .available,
                  revisions.contains(where: {
                      $0.id == occurrence.revisionID && $0.choreID == choreID
                          && $0.schedulingMode == .asNeeded
                  }) else { continue }
            legacyWinnerByDay[occurrence.day] = fact.id
        }

        var result = AsNeededControlProjection()
        var openIndex: Int?

        func winningRevisionMatches(_ revisionID: UUID, on occurrenceDay: CivilDay) -> Bool {
            configuration(choreID: choreID, on: occurrenceDay)?.id == revisionID
        }

        func indexOfOccurrence(_ occurrenceID: UUID) -> Int? {
            result.occurrences.firstIndex { $0.id == occurrenceID }
        }

        func hasLaterDone(for occurrence: ProjectedAsNeededOccurrence, after index: Int) -> Bool {
            guard index + 1 < deletionIndex else { return false }
            return facts[(index + 1)..<deletionIndex].contains { fact in
                guard case .asNeededOccurrenceCompletion(let completion) = fact.body,
                      completion.occurrenceID == occurrence.id,
                      completion.choreID == choreID,
                      completion.revisionID == occurrence.revisionID,
                      completion.day == occurrence.day,
                      completion.day <= day, completion.state == .done,
                      let revision = revisions.first(where: { $0.id == completion.revisionID }),
                      completion.mode == revision.mode else { return false }
                let eligible = (occurrence.responsibilityOwnerID ?? occurrence.assignedMemberID)
                    .map { [$0] } ?? occurrence.eligibleMemberIDs
                return eligible.contains(completion.memberID) && completion.eligibleMemberIDs == eligible
            }
        }

        for (index, fact) in facts.enumerated() where index < deletionIndex {
            switch fact.body {
            case .occurrence(let legacy):
                guard index < capabilityIndex, legacy.choreID == choreID,
                      legacy.day <= day, legacy.state == .available,
                      legacyWinnerByDay[legacy.day] == fact.id,
                      winningRevisionMatches(legacy.revisionID, on: legacy.day),
                      let revision = revisions.first(where: { $0.id == legacy.revisionID }),
                      revision.schedulingMode == .asNeeded else { continue }
                let eligible = AsNeededOccurrenceRules.eligibleMemberIDs(
                    revision: revision, day: legacy.day, snapshot: self
                )
                let assigned = legacy.assignedMemberID ?? (revision.mode == .alternating
                    ? ChoreRules.expectedAsNeededOwner(choreID: choreID, on: legacy.day,
                                                       snapshot: self, projection: result) : nil)
                let required = revision.mode == .anyOne
                    ? [] : (assigned.map { [$0] } ?? eligible)
                result.occurrences.append(ProjectedAsNeededOccurrence(
                    id: fact.id, activationFactID: fact.id, choreID: choreID,
                    revisionID: legacy.revisionID, day: legacy.day,
                    eligibleMemberIDs: eligible, requiredMemberIDs: required,
                    assignedMemberID: assigned, isLegacy: true,
                    status: .open, contributions: [:], closureFactID: nil,
                    consumedTurn: legacy.assignedMemberID == nil
                ))
                openIndex = result.occurrences.indices.last
                applyPunt(to: &result.occurrences[result.occurrences.count - 1])
                result.controlHeadID = fact.id

            case .completion(let legacy):
                guard index < capabilityIndex, legacy.choreID == choreID,
                      legacy.day <= day,
                      let occurrenceIndex = result.occurrences.lastIndex(where: {
                          $0.day == legacy.day && $0.revisionID == legacy.revisionID && $0.isLegacy
                      }) else { continue }
                result.occurrences[occurrenceIndex].contributions[legacy.memberID] = legacy
                if result.occurrences[occurrenceIndex].isFullyComplete {
                    result.occurrences[occurrenceIndex].status = .completed
                    result.occurrences[occurrenceIndex].closureFactID = fact.id
                    result.occurrences[occurrenceIndex].consumedTurn = true
                    if openIndex == occurrenceIndex { openIndex = nil }
                    result.controlHeadID = fact.id
                } else if openIndex == occurrenceIndex {
                    result.controlHeadID = fact.id
                }

            case .alternatingTurnAdvance(let legacy):
                guard index < capabilityIndex, legacy.choreID == choreID,
                      legacy.day <= day, openIndex == nil,
                      winningRevisionMatches(legacy.revisionID, on: legacy.day),
                      ChoreRules.expectedAsNeededOwner(choreID: choreID, on: legacy.day,
                                                       snapshot: self, projection: result)
                        == legacy.expectedMemberID else { continue }
                result.turnAdvances.append(AcceptedAsNeededTurnAdvance(
                    factID: fact.id, choreID: choreID, revisionID: legacy.revisionID,
                    day: legacy.day, ownerID: legacy.expectedMemberID
                ))
                result.controlHeadID = fact.id

            case .asNeededOccurrence(let occurrence):
                guard index > capabilityIndex,
                      occurrence.choreID == choreID, occurrence.day <= day,
                      occurrence.expectedControlHeadID == result.controlHeadID,
                      openIndex == nil,
                      winningRevisionMatches(occurrence.revisionID, on: occurrence.day),
                      let revision = revisions.first(where: { $0.id == occurrence.revisionID }) else { continue }
                let expectedEligible = AsNeededOccurrenceRules.eligibleMemberIDs(
                    revision: revision, day: occurrence.day, snapshot: self
                )
                let expectedOwner = revision.mode == .alternating
                    ? ChoreRules.expectedAsNeededOwner(choreID: choreID, on: occurrence.day,
                                                       snapshot: self, projection: result) : nil
                let expectedRequired = revision.mode == .anyOne ? []
                    : (expectedOwner.map { [$0] } ?? expectedEligible)
                guard occurrence.eligibleMemberIDs == expectedEligible,
                      occurrence.requiredMemberIDs == expectedRequired,
                      occurrence.assignedMemberID == expectedOwner else { continue }
                result.occurrences.append(ProjectedAsNeededOccurrence(
                    id: occurrence.id, activationFactID: fact.id, choreID: choreID,
                    revisionID: occurrence.revisionID, day: occurrence.day,
                    eligibleMemberIDs: occurrence.eligibleMemberIDs,
                    requiredMemberIDs: occurrence.requiredMemberIDs,
                    assignedMemberID: occurrence.assignedMemberID, isLegacy: false,
                    status: .open, contributions: [:], closureFactID: nil,
                    consumedTurn: false
                ))
                openIndex = result.occurrences.indices.last
                applyPunt(to: &result.occurrences[result.occurrences.count - 1])
                result.controlHeadID = fact.id

            case .asNeededOccurrenceCompletion(let completion):
                guard index > capabilityIndex,
                      completion.choreID == choreID, completion.day <= day,
                      let occurrenceIndex = indexOfOccurrence(completion.occurrenceID),
                      result.occurrences[occurrenceIndex].revisionID == completion.revisionID,
                      result.occurrences[occurrenceIndex].day == completion.day,
                      let revision = revisions.first(where: { $0.id == completion.revisionID }),
                      completion.mode == revision.mode else { continue }
                let occurrence = result.occurrences[occurrenceIndex]
                let contributionEligible = (occurrence.responsibilityOwnerID ?? occurrence.assignedMemberID).map { [$0] }
                    ?? occurrence.eligibleMemberIDs
                guard contributionEligible.contains(completion.memberID),
                      completion.eligibleMemberIDs == contributionEligible,
                      occurrence.status != .withdrawn else { continue }
                let wasCompleted = result.occurrences[occurrenceIndex].status == .completed
                let hadDependentControl = wasCompleted
                    && result.controlHeadID != result.occurrences[occurrenceIndex].closureFactID
                var projectedCompletion = completion.datedCompletion
                if wasCompleted && hadDependentControl && completion.state == .unmarked {
                    projectedCompletion = DatedCompletion(
                        choreID: completion.choreID, revisionID: completion.revisionID,
                        memberID: completion.memberID, day: completion.day, state: .missed,
                        eligibleMemberIDs: completion.eligibleMemberIDs, mode: completion.mode,
                        recordedByMemberID: completion.recordedByMemberID
                    )
                }
                result.occurrences[occurrenceIndex].contributions[completion.memberID] = projectedCompletion
                if result.occurrences[occurrenceIndex].isFullyComplete {
                    result.occurrences[occurrenceIndex].status = .completed
                    if !result.occurrences[occurrenceIndex].consumedTurn {
                        result.occurrences[occurrenceIndex].consumedTurn = true
                    }
                    if !hadDependentControl {
                        result.occurrences[occurrenceIndex].closureFactID = fact.id
                        if openIndex == occurrenceIndex { openIndex = nil }
                        result.controlHeadID = fact.id
                    }
                } else if result.occurrences[occurrenceIndex].status == .completed {
                    let canReopen = completion.state == .unmarked
                        && result.controlHeadID == result.occurrences[occurrenceIndex].closureFactID
                    if canReopen {
                        result.occurrences[occurrenceIndex].status = .open
                        result.occurrences[occurrenceIndex].consumedTurn = false
                        result.occurrences[occurrenceIndex].closureFactID = nil
                        openIndex = occurrenceIndex
                        result.controlHeadID = fact.id
                    }
                } else if openIndex == occurrenceIndex {
                    result.controlHeadID = fact.id
                }

            case .asNeededOccurrenceResolution(let resolution):
                guard index > capabilityIndex,
                      resolution.choreID == choreID, resolution.day <= day,
                      resolution.state == .withdrawn,
                      let occurrenceIndex = indexOfOccurrence(resolution.occurrenceID),
                      openIndex == occurrenceIndex,
                      resolution.expectedControlHeadID == result.controlHeadID,
                      !result.occurrences[occurrenceIndex].contributions.values.contains(where: {
                          $0.state == .done
                      }),
                      !hasLaterDone(for: result.occurrences[occurrenceIndex], after: index) else { continue }
                result.occurrences[occurrenceIndex].status = .withdrawn
                openIndex = nil
                result.controlHeadID = fact.id

            case .asNeededTurnAdvance(let advance):
                guard index > capabilityIndex,
                      advance.choreID == choreID, advance.day <= day,
                      advance.expectedControlHeadID == result.controlHeadID,
                      openIndex == nil,
                      winningRevisionMatches(advance.revisionID, on: advance.day),
                      ChoreRules.expectedAsNeededOwner(choreID: choreID, on: advance.day,
                                                       snapshot: self, projection: result)
                        == advance.expectedMemberID,
                      let revision = revisions.first(where: { $0.id == advance.revisionID }),
                      AsNeededOccurrenceRules.eligibleMemberIDs(
                        revision: revision, day: advance.day, snapshot: self
                      ).count > 1 else { continue }
                result.turnAdvances.append(AcceptedAsNeededTurnAdvance(
                    factID: fact.id, choreID: choreID, revisionID: advance.revisionID,
                    day: advance.day, ownerID: advance.expectedMemberID
                ))
                result.controlHeadID = fact.id

            default:
                continue
            }
        }
        return result
    }

    private func applyPunt(to occurrence: inout ProjectedAsNeededOccurrence) {
        guard let original = occurrence.assignedMemberID else { return }
        let scope = PuntScope(choreID: occurrence.choreID, revisionID: occurrence.revisionID,
                              day: occurrence.day, occurrenceID: occurrence.id)
        occurrence.responsibilityOwnerID = PuntRules.project(
            scope: scope, originalOwnerID: original, snapshot: self
        ).ownerID
    }
}

private enum AsNeededOccurrenceRules {
    static func eligibleMemberIDs(revision: ChoreRevision, day: CivilDay,
                                  snapshot: HouseholdSnapshot) -> [UUID] {
        snapshot.members.filter {
            $0.role == .child && $0.isActive(on: day)
                && (revision.mode == .all || revision.memberIDs.contains($0.id))
        }.map(\.id)
    }
}

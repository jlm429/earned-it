import Foundation
import CryptoKit

/// A parent award records recognition, independently of weekly eligibility or payments.
struct BonusAward: Codable, Equatable {
    let memberID: UUID
    let amount: AllowanceAmount
    let day: CivilDay
    let note: String
    let recordedByMemberID: UUID
}

struct RecordedBonus: Identifiable, Equatable {
    let id: UUID
    let award: BonusAward
}

struct ChoreScope: Codable, Equatable, Hashable {
    let choreID: UUID
    let revisionID: UUID
    let day: CivilDay
    let occurrenceID: UUID?

    init(_ chore: DailyChore) {
        choreID = chore.choreID
        revisionID = chore.configuration.id
        day = chore.day
        occurrenceID = chore.occurrenceID
    }
}

struct ChoreNudge: Codable, Equatable {
    let scope: ChoreScope
    let memberID: UUID
    let recordedByMemberID: UUID
    var sentAt: Date? = nil

    func matches(_ chore: DailyChore) -> Bool {
        scope.choreID == chore.choreID && scope.day == chore.day && scope.occurrenceID == chore.occurrenceID
    }

    /// Independent offline reminders share a delivery receipt without sharing mutable facts.
    func activityID(householdID: UUID) -> UUID {
        let window = sentAt.map { "/\(floor($0.timeIntervalSince1970 / FamilyExtrasRules.nudgeCooldown))" } ?? ""
        let key = "nudge/\(householdID)/\(scope.choreID)/\(scope.day)/\(scope.occurrenceID?.uuidString ?? "scheduled")/\(memberID)\(window)"
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

enum FamilyExtrasRules {
    static let nudgeCooldown: TimeInterval = 60
    static func bonuses(memberID: UUID, snapshot: HouseholdSnapshot) -> [RecordedBonus] {
        snapshot.orderedFacts.reversed().compactMap { fact in
            guard case .bonusAward(let award) = fact.body, award.memberID == memberID,
                  fact.authorMemberID == award.recordedByMemberID,
                  snapshot.member(award.recordedByMemberID)?.role == .parent else { return nil }
            return RecordedBonus(id: fact.id, award: award)
        }
    }

    static func nudgeTargets(for chore: DailyChore) -> [FamilyMember] {
        guard chore.day == chore.today, chore.isActiveOccurrence, chore.isActionableOccurrence,
              !chore.isDeleted, !chore.isNotNeeded else { return [] }
        return chore.remainingMembers.filter { !chore.isExcused($0.id) }
    }

    static func hasNudge(for chore: DailyChore, memberID: UUID, snapshot: HouseholdSnapshot, now: Date) -> Bool {
        snapshot.orderedFacts.contains { fact in
            guard case .choreNudge(let value) = fact.body, value.matches(chore), value.memberID == memberID,
                  fact.authorMemberID == value.recordedByMemberID,
                  snapshot.member(value.recordedByMemberID)?.role == .parent,
                  let sentAt = value.sentAt else { return false }
            return now.timeIntervalSince(sentAt) < nudgeCooldown
        }
    }
}

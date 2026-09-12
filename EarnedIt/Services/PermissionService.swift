import Foundation

enum HouseholdError: LocalizedError, Equatable {
    case invalidAllowance, completionLocked
    case permission, invalidName, duplicateName, missingChildren, invalidAssignment, unavailableDay
    case noHousehold, alreadyHasHousehold, cloudUnavailable, wrongAccount, invitation, readOnly
    case invitationNotFound, invitationExpired, invitationRevoked, invitationConsumed, invitationUnavailable
    case invitationOwnerRequired, accountMembershipConflict
    case missingProfile, lastParent, pendingChanges, malformedData, familyStillSyncing

    var errorDescription: String? {
        switch self {
        case .invalidAllowance: "Enter an amount from 0 to 999,999 using the currency’s decimal places, or leave it blank. Do not use grouping separators."
        case .completionLocked: "You can mark an item on its scheduled day and the following day in your family timezone. After that, check in with your parent for a correction."
        case .permission: "This profile does not have permission for that change."
        case .invalidName: "Use a name with 1 to 50 characters."
        case .duplicateName: "A member with that name and role already exists."
        case .missingChildren: "Add at least one child to finish setup."
        case .invalidAssignment: "Choose one child, at least two children to take turns, or an eligible group for this chore."
        case .unavailableDay: "This change is not available for that day."
        case .noHousehold: "Create a family or accept an existing family invitation first."
        case .alreadyHasHousehold: "This installation already has a family. Disconnect in Settings before joining another."
        case .cloudUnavailable: "iCloud sharing is unavailable. Sign in to iCloud on a device with the app's iCloud capability enabled, then try again. Local changes are kept."
        case .wrongAccount: "The iCloud account has changed. Switch back to the connected account before syncing this family."
        case .invitation: "Use an Earned It iCloud family invitation. Ask a parent to send it from Family & Sharing."
        case .invitationNotFound: "That invitation code does not match a family available to this iCloud account. Open the Apple invitation first, then try the code again."
        case .invitationExpired: "That invitation has expired. Ask a parent for a new one."
        case .invitationRevoked: "That invitation was revoked. Ask a parent for a new one."
        case .invitationConsumed: "That invitation has already been used. Ask a parent for a new one."
        case .invitationUnavailable: "That invitation or family profile is no longer available. Ask a parent for a new invitation."
        case .invitationOwnerRequired: "This iCloud version only lets the family owner add another person. Ask the owner to create this invitation."
        case .accountMembershipConflict: "This iCloud account already belongs to an Earned It family member. Use that member, or ask the family owner to remove this account before joining again."
        case .readOnly: "This invitation permits viewing only. Ask the family owner for permission to make changes."
        case .missingProfile: "A parent needs to approve profiles for this installation."
        case .lastParent: "Keep at least one active parent. Switch profiles before archiving yourself."
        case .pendingChanges: "Sync pending changes before disconnecting so your work is kept."
        case .familyStillSyncing: "The family is still syncing its setup. Ask the owner to finish syncing, then try connecting again."
        case .malformedData: "The shared family contains data this version cannot read safely. Update the app or contact the family owner."
        }
    }
}

enum PermissionService {
    static func availableProfiles(snapshot: HouseholdSnapshot, session: DeviceSession, day: CivilDay) -> [FamilyMember] {
        guard let household = snapshot.household else { return [] }
        let hasCreatorAccess = household.creatorDeviceID == session.deviceID
        let granted = snapshot.grants.first {
            $0.deviceID == session.deviceID && $0.cloudParticipantID == session.cloudParticipantID
        }?.memberIDs ?? []
        var invited: [UUID] = []
        if let participant = session.cloudParticipantID,
           let membership = try? snapshot.accountMembership(participantID: participant,
                                                            now: day.date(in: household.calendar)) {
            invited = [membership.member.id]
        }
        let authorized = Set(granted + invited + (session.legacyProfileIDs ?? []))
        return snapshot.members.filter { snapshot.isActive($0, on: day) && (hasCreatorAccess || authorized.contains($0.id)) }
    }

    static func requireParent(_ actor: FamilyMember?) throws {
        guard actor?.role == .parent else { throw HouseholdError.permission }
    }

    static func canChildEdit(day: CivilDay, today: CivilDay) -> Bool {
        // Civil dates use UTC here only for calendar arithmetic, independent of elapsed hours.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return day <= today && today <= day.adding(days: 1, calendar: calendar)
    }

    static func canSetState(actor: FamilyMember, target: UUID, chore: DailyChore, state: DailyStateKind) -> Bool {
        guard chore.day <= chore.today,
              chore.eligibleMembers.contains(where: { $0.id == target }) else { return false }
        if actor.role == .parent { return state != .unmarked || chore.day == chore.today }
        return actor.id == target && canChildEdit(day: chore.day, today: chore.today) && state != .missed
    }
}

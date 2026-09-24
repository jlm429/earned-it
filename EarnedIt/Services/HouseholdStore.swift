import Foundation
import Observation
import CloudKit
import UIKit

@MainActor
@Observable
final class HouseholdStore {
    private struct StaleOwnerMembershipReleaseCandidate {
        let lock: AccountMembershipLock
        let participantID: String
        let accountGeneration: UInt64
    }

    private static let pendingInvitationCleanupRetryDelay: TimeInterval = 30
    private let repository: HouseholdRepository
    private let transport: (any HouseholdTransport)?
    private let clock: () -> Date
    private let automaticSync: Bool
    private(set) var snapshot = HouseholdSnapshot()
    private(set) var session: DeviceSession
    private(set) var midnightTimerRevision = UUID()
    private(set) var today: Date
    private(set) var isSyncing = false
    private(set) var syncMessage = "On this device"
    private(set) var lastSyncedAt: Date?
    private(set) var cloudAccessBlocked = false
    private(set) var cloudIsReadOnly = false
    private(set) var isCheckingAccountMembership = false
    private(set) var isJoiningInvitation = false
    private(set) var requiresMembershipRecovery = false
    private(set) var canReleaseStaleOwnerMembership = false
    private(set) var rejectedChanges: [UUID: String] = [:]
    var errorMessage: String?
    private var syncTask: Task<Void, Never>?
    private var activeSync: Task<Void, Error>?
    private var invitationCleanupTail: Task<Void, Never>?
    private var syncAgain = false
    private var facts: [HouseholdFact] = []
    private var staleOwnerMembershipReleaseCandidate: StaleOwnerMembershipReleaseCandidate?

    init(repository: HouseholdRepository, transport: (any HouseholdTransport)? = nil,
         clock: @escaping () -> Date = { .now }, automaticSync: Bool = true,
         performLocalMigrations: Bool = true) throws {
        self.repository = repository
        self.transport = transport
        self.clock = clock
        self.automaticSync = automaticSync
        session = try repository.session()
        today = clock()
        isCheckingAccountMembership = transport != nil && session.householdID == nil
            && session.pendingInvitationAcceptance == nil && session.pendingInvitationPackage == nil
        cloudIsReadOnly = session.location != nil && session.cloudCanWrite != true
        try reload()
        if performLocalMigrations { try migrateLegacyProfileAccess() }
    }

    var household: Household? { snapshot.household }
    var hasPendingInvitationPackage: Bool { session.pendingInvitationPackage != nil }
    var lastJoinReceipt: LastJoinReceipt? { session.lastJoinReceipt }
    var hasFamilyDeletionNotice: Bool { session.familyDeletionNoticeState == .pending }
    var calendar: Calendar { household?.calendar ?? AppCalendar.current }
    var day: CivilDay { CivilDay(today, calendar: calendar) }
    var nextHouseholdMidnight: Date { tomorrow.date(in: calendar) }
    var tomorrow: CivilDay { day.adding(days: 1, calendar: calendar) }
    var profiles: [FamilyMember] { PermissionService.availableProfiles(snapshot: snapshot, session: session, day: day) }
    var selectedMember: FamilyMember? { profiles.first { $0.id == session.selectedMemberID } }
    var children: [FamilyMember] { snapshot.members.filter { $0.role == .child && snapshot.isActive($0, on: tomorrow) } }
    var pendingCount: Int { (try? session.householdID.map { try repository.pending(householdID: $0).count }) ?? 0 }
    var pendingRequests: [ProfileRequest] {
        snapshot.requests.filter { request in !snapshot.grants.contains { $0.requestID == request.id } }
    }
    var currentRequest: ProfileRequest? {
        snapshot.requests.last { $0.deviceID == session.deviceID && $0.cloudParticipantID == session.cloudParticipantID }
    }
    var familyInvitations: [FamilyInvitation] { snapshot.invitations.sorted { $0.createdAt > $1.createdAt } }
    var familyAccessLost: Bool { session.familyAccessLost == true }
    var canRemoveUnavailableFamilyFromDevice: Bool {
        familyAccessLost && session.accountMembershipLockAttemptID == nil
    }
    var canDeleteFamily: Bool {
        guard let selectedMember else { return false }
        return selectedMember.role == .parent && session.location?.isOwner == true
            && selectedMember.id == snapshot.creatorMemberID
    }
    var canFinishDeletingFamily: Bool {
        canDeleteFamily && familyAccessLost && session.pendingFamilyDeletion == true
            && session.accountMembershipLockAttemptID != nil
    }
    var pendingInvitationCleanupID: String? {
        guard let pending = session.pendingInvitationAcceptance else { return nil }
        return "\(pending.location.id)/\(pending.invitationID?.uuidString ?? "pending")/\(pending.phase.rawValue)"
    }

    func cloudAccountDidChange() {
        canReleaseStaleOwnerMembership = false
        staleOwnerMembershipReleaseCandidate = nil
        transport?.accountDidChange()
    }

    #if DEBUG
    func prepareStaleOwnerMembershipRecoveryUITest() {
        guard session.householdID == nil, session.pendingInvitationAcceptance == nil else { return }
        isCheckingAccountMembership = false
        requiresMembershipRecovery = true
        canReleaseStaleOwnerMembership = true
    }
    #endif

    func dailyList(on date: Date? = nil) -> [DailyChore] {
        ChoreRules.dailyList(snapshot: snapshot, day: CivilDay(date ?? today, calendar: calendar), today: day)
    }

    func nextAlternatingOwner(choreID: UUID) -> FamilyMember? {
        ChoreRules.nextAlternatingOwner(choreID: choreID, on: day, snapshot: snapshot)
    }

    func choreAssignmentDay(choreID: UUID) -> CivilDay {
        snapshot.revisions.contains { $0.choreID == choreID } ? tomorrow : day
    }

    func eligibleChildren(choreID: UUID) -> [FamilyMember] {
        let effective = choreAssignmentDay(choreID: choreID)
        return snapshot.members.filter { $0.role == .child && snapshot.isActive($0, on: effective) }
    }

    func orderedEligibleChildren(choreID: UUID, selectedMemberIDs: Set<UUID>) -> [FamilyMember] {
        let eligible = eligibleChildren(choreID: choreID)
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        let effective = choreAssignmentDay(choreID: choreID)
        let retained = snapshot.configuration(choreID: choreID, on: effective)?.memberIDs.compactMap {
            selectedMemberIDs.contains($0) ? byID[$0] : nil
        } ?? []
        let retainedIDs = Set(retained.map(\.id))
        return retained + eligible.filter { selectedMemberIDs.contains($0.id) && !retainedIDs.contains($0.id) }
    }

    func weekFacts(for memberID: UUID, containing date: Date? = nil) -> [DayFacts] {
        MetricsService.weekFacts(childID: memberID, containing: date ?? today, snapshot: snapshot, today: today)
    }

    func allowanceWeek(for memberID: UUID, containing date: Date? = nil) -> AllowanceWeek {
        AllowanceService.week(childID: memberID, containing: date ?? today, snapshot: snapshot, today: today)
    }

    func allowanceHistory(for memberID: UUID) -> [AllowanceWeek] {
        AllowanceService.history(childID: memberID, snapshot: snapshot, today: today)
    }

    func saveAllowance(memberID: UUID, text: String, currencyCode: String, locale: Locale = .autoupdatingCurrent) throws {
        try requireParent()
        guard let member = snapshot.member(memberID), member.role == .child,
              snapshot.isActive(member, on: day) else { throw HouseholdError.permission }
        let amount = try AllowanceAmount.parse(text, currencyCode: currencyCode, locale: locale)
        let start = CivilDay(AppCalendar.weekStart(containing: today, calendar: calendar), calendar: calendar)
        try append(.allowance(AllowanceRevision(memberID: memberID, effectiveWeek: start, amount: amount)))
    }

    /// A local presentation receipt prevents replay after relaunch without syncing profile selection.
    func consumeCelebration(for memberID: UUID) throws -> Bool {
        today = clock()
        guard selectedMember?.id == memberID, selectedMember?.role == .child,
              let previous = allowanceHistory(for: memberID).dropFirst().first, previous.earned else { return false }
        guard !(session.celebratedWeeks ?? []).contains(previous.id) else { return false }
        let retained = Set(snapshot.members.filter { $0.role == .child }.flatMap { allowanceHistory(for: $0.id).map(\.id) })
        var updated = session
        updated.celebratedWeeks = (session.celebratedWeeks ?? []).filter { retained.contains($0) } + [previous.id]
        try repository.commit(facts: [], session: updated)
        session = updated
        return true
    }

    func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    func significantTimeChanged() {
        midnightTimerRevision = UUID()
        refreshDate()
    }

    func refreshDate() {
        today = clock()
        scheduleSync()
    }

    func selectProfile(_ id: UUID?) throws {
        today = clock()
        if let id, !profiles.contains(where: { $0.id == id }) { throw HouseholdError.permission }
        var updated = session
        updated.selectedMemberID = id
        try repository.commit(facts: [], session: updated)
        session = updated
    }

    func createFamily(name: String, parentName: String, timeZone: TimeZone = .current) throws {
        today = clock()
        guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
        guard !requiresMembershipRecovery else { throw HouseholdError.accountMembershipConflict }
        let name = try validatedName(name)
        let parentName = try validatedName(parentName)
        var calendar = AppCalendar.current
        calendar.timeZone = timeZone
        let household = Household(id: UUID(), name: name, timeZoneID: timeZone.identifier,
                                  createdDay: CivilDay(clock(), calendar: calendar), creatorDeviceID: session.deviceID)
        let parent = FamilyMember(id: UUID(), householdID: household.id, displayName: parentName,
                                  role: .parent, avatar: .sun, joinedDay: household.createdDay)
        var updated = session
        updated.householdID = household.id
        updated.selectedMemberID = parent.id
        updated.legacyProfileIDs = []
        let created = [
            HouseholdFact(id: UUID(), householdID: household.id, sequence: 1, authorDeviceID: session.deviceID,
                          authorMemberID: parent.id, body: .household(household)),
            HouseholdFact(id: UUID(), householdID: household.id, sequence: 2, authorDeviceID: session.deviceID,
                          authorMemberID: parent.id, body: .member(parent))
        ]
        try repository.commit(facts: created, session: updated)
        session = updated
        try reload()
    }

    func finishSetup() throws {
        try requireParent()
        guard var household, !children.isEmpty else { throw HouseholdError.missingChildren }
        household.isSetupComplete = true
        try append(.household(household))
    }

    func renameFamily(_ name: String) throws {
        try requireParent()
        guard session.pendingFamilyDeletion != true else { throw HouseholdError.permission }
        guard var household else { throw HouseholdError.noHousehold }
        let name = try validatedName(name)
        guard name != household.name else { return }
        household.name = name
        try append(.household(household))
    }

    @discardableResult
    func saveMember(id: UUID = UUID(), name: String, role: UserRole, avatar: AvatarOption) throws -> FamilyMember {
        try requireParent()
        guard let household else { throw HouseholdError.noHousehold }
        let name = try validatedName(name)
        guard !snapshot.members.contains(where: {
            $0.id != id && $0.role == role && $0.archivedFrom == nil
                && $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { throw HouseholdError.duplicateName }
        let member: FamilyMember
        if var existing = snapshot.member(id) {
            guard existing.role == role else { throw HouseholdError.permission }
            existing.displayName = name
            existing.avatar = avatar
            member = existing
        } else {
            // Joining all-children chores is immediate, independent of next-day chore edits.
            // Persist the household day so reload and sync never backdate membership.
            member = FamilyMember(id: id, householdID: household.id, displayName: name, role: role,
                                  avatar: avatar, joinedDay: role == .child || !household.isSetupComplete ? day : tomorrow)
        }
        try append(.member(member))
        return member
    }

    func archiveMember(_ id: UUID) throws {
        try requireParent()
        guard var member = snapshot.member(id), member.id != selectedMember?.id else { throw HouseholdError.lastParent }
        if member.role == .parent && snapshot.members.filter({ $0.role == .parent && snapshot.isActive($0, on: tomorrow) }).count <= 1 {
            throw HouseholdError.lastParent
        }
        member.archivedFrom = tomorrow
        try append(.member(member))
    }

    @discardableResult
    func saveChore(choreID: UUID = UUID(), weekday: Weekday, title: String, notes: String = "",
                   category: ResponsibilityCategory = .home, mode: RequirementMode, memberIDs: [UUID],
                   schedulingMode: ChoreSchedulingMode = .scheduled,
                   firstAlternatingMemberID: UUID? = nil) throws -> UUID {
        try requireParent()
        guard let household else { throw HouseholdError.noHousehold }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80, notes.count <= 300 else { throw HouseholdError.invalidAssignment }
        let effective = choreAssignmentDay(choreID: choreID)
        guard !snapshot.isChoreDeleted(choreID, on: effective) else { throw HouseholdError.invalidAssignment }
        let eligible = eligibleChildren(choreID: choreID)
        let eligibleIDs = eligible.map(\.id)
        let ids = Set(memberIDs)
        let current = snapshot.configuration(choreID: choreID, on: effective)
        let currentIsLegacy = current.map { !RequirementMode.assignmentChoices.contains($0.mode) } ?? false
        let preservesLegacy = currentIsLegacy && current?.mode == mode && current?.memberIDs == memberIDs
        if currentIsLegacy && !RequirementMode.assignmentChoices.contains(mode) && !preservesLegacy {
            throw HouseholdError.invalidAssignment
        }
        if !preservesLegacy {
            guard mode == .all || ids.isSubset(of: Set(eligibleIDs)) else { throw HouseholdError.invalidAssignment }
            switch mode {
            case .particular: guard ids.count == 1 else { throw HouseholdError.invalidAssignment }
            case .multiple: guard ids.count >= 2 else { throw HouseholdError.invalidAssignment }
            case .anyOne: guard !ids.isEmpty else { throw HouseholdError.invalidAssignment }
            case .all: guard !eligibleIDs.isEmpty else { throw HouseholdError.invalidAssignment }
            case .alternating: guard ids.count >= 2 else { throw HouseholdError.invalidAssignment }
            }
        }
        var orderedIDs = preservesLegacy ? memberIDs
            : orderedEligibleChildren(choreID: choreID, selectedMemberIDs: ids).map(\.id)
        if mode == .alternating {
            if current != nil, current?.mode != .alternating, firstAlternatingMemberID == nil {
                throw HouseholdError.invalidAssignment
            }
            let implicitFirstID = current?.memberIDs.first(where: orderedIDs.contains) ?? memberIDs.first
            var firstID = firstAlternatingMemberID ?? implicitFirstID
            if current?.mode == .alternating,
               firstAlternatingMemberID == current?.memberIDs.first,
               firstAlternatingMemberID.map({ !orderedIDs.contains($0) }) == true {
                firstID = implicitFirstID
            }
            guard let firstID, let index = orderedIDs.firstIndex(of: firstID) else {
                throw HouseholdError.invalidAssignment
            }
            orderedIDs = Array(orderedIDs[index...] + orderedIDs[..<index])
        }
        let revision = ChoreRevision(id: UUID(), householdID: household.id, choreID: choreID, weekday: weekday,
                                     effectiveDay: effective, title: title, notes: notes, category: category, mode: mode,
                                     memberIDs: mode == .all ? [] : orderedIDs, isArchived: false,
                                     schedulingMode: schedulingMode)
        try append(.chore(revision))
        return choreID
    }

    func archiveChore(_ choreID: UUID) throws {
        try requireParent()
        guard let old = snapshot.configuration(choreID: choreID, on: tomorrow) else { throw HouseholdError.invalidAssignment }
        try append(.chore(ChoreRevision(id: UUID(), householdID: old.householdID, choreID: choreID,
                                       weekday: old.weekday, effectiveDay: tomorrow, title: old.title, notes: old.notes,
                                       category: old.category, mode: old.mode, memberIDs: old.memberIDs, isArchived: true,
                                       schedulingMode: old.schedulingMode)))
    }

    /// Removes a chore from current lists immediately while retaining immutable dated facts.
    func deleteChore(_ choreID: UUID) throws {
        try requireParent()
        guard !snapshot.isChoreDeleted(choreID, on: day), let parent = selectedMember else {
            throw HouseholdError.invalidAssignment
        }
        let current = snapshot.configuration(choreID: choreID, on: day)
        let future = snapshot.configuration(choreID: choreID, on: tomorrow)
        let currentOccurrence = dailyList().first { $0.id == choreID }
        guard current?.isArchived == false || future?.isArchived == false else {
            throw HouseholdError.invalidAssignment
        }
        var tombstones: [HouseholdFactBody] = []
        if let current, !current.isArchived {
            tombstones.append(.chore(ChoreRevision(
                id: UUID(), householdID: current.householdID, choreID: choreID,
                weekday: current.weekday, effectiveDay: day, title: current.title,
                notes: current.notes, category: current.category, mode: current.mode,
                memberIDs: current.memberIDs, isArchived: true,
                schedulingMode: current.schedulingMode
            )))
        }
        if let future, !future.isArchived, future.id != current?.id {
            tombstones.append(.chore(ChoreRevision(
                id: UUID(), householdID: future.householdID, choreID: choreID,
                weekday: future.weekday, effectiveDay: tomorrow, title: future.title,
                notes: future.notes, category: future.category, mode: future.mode,
                memberIDs: future.memberIDs, isArchived: true,
                schedulingMode: future.schedulingMode
            )))
        }
        tombstones.append(.choreDeletion(ChoreDeletion(
            choreID: choreID, day: day, recordedByMemberID: parent.id,
            revisionID: current?.id,
            eligibleMemberIDs: currentOccurrence?.eligibleMembers.map(\.id),
            turnOwnerID: currentOccurrence?.turnOwnerID,
            wasNotNeeded: currentOccurrence?.isNotNeeded,
            resolvedContributions: currentOccurrence?.contributions.filter { $0.state != .unmarked },
            resolvedExcusedMemberIDs: currentOccurrence.map { occurrence in
                occurrence.eligibleMembers.filter { member in
                    snapshot.excuses.contains {
                        $0.memberID == member.id && $0.day == day && $0.isExcused
                    }
                }.map(\.id)
            } ?? []
        )))
        try append(tombstones)
    }

    func activateAsNeededChore(choreID: UUID, date: Date? = nil) throws {
        try requireParent()
        let occurrenceDay = CivilDay(date ?? today, calendar: calendar)
        guard occurrenceDay == day,
              let revision = snapshot.configuration(choreID: choreID, on: occurrenceDay),
              !revision.isArchived, !snapshot.isChoreDeleted(choreID, on: occurrenceDay),
              revision.schedulingMode == .asNeeded,
              snapshot.occurrence(choreID: choreID, on: occurrenceDay) == nil,
              !snapshot.occurrenceDispositions.contains(where: { activation in
                  guard activation.choreID == choreID, activation.state == .available else { return false }
                  guard snapshot.configuration(choreID: choreID, on: activation.day)?.id
                      == activation.revisionID else { return false }
                  return ChoreRules.dailyList(snapshot: snapshot, day: activation.day, today: day)
                      .first(where: { $0.id == choreID })?.isFullyComplete == false
              }),
              !ChoreRules.eligibleMembers(for: revision, on: occurrenceDay, snapshot: snapshot).isEmpty,
              let parent = selectedMember else { throw HouseholdError.unavailableDay }
        try append(.occurrence(ChoreOccurrenceDisposition(
            choreID: choreID, revisionID: revision.id, day: occurrenceDay, state: .available,
            alternatingSkipBehavior: nil, recordedByMemberID: parent.id,
            assignedMemberID: revision.mode == .alternating
                ? ChoreRules.nextAlternatingOwner(choreID: choreID, on: occurrenceDay, snapshot: snapshot)?.id : nil
        )))
    }

    func skipNextAlternatingChild(choreID: UUID) throws {
        try requireParent()
        guard let revision = snapshot.configuration(choreID: choreID, on: day),
              !revision.isArchived, !snapshot.isChoreDeleted(choreID, on: day),
              revision.mode == .alternating,
              revision.schedulingMode == .asNeeded,
              ChoreRules.activeOccurrence(for: revision, in: dailyList()) == nil,
              let owner = nextAlternatingOwner(choreID: choreID),
              let parent = selectedMember else { throw HouseholdError.unavailableDay }
        try append(.alternatingTurnAdvance(AlternatingTurnAdvance(
            choreID: choreID, revisionID: revision.id, expectedMemberID: owner.id,
            day: day, recordedByMemberID: parent.id
        )))
    }

    func markOccurrenceNotNeeded(choreID: UUID, date: Date,
                                 alternatingSkipBehavior: AlternatingSkipBehavior? = nil) throws {
        try requireParent()
        let occurrenceDay = CivilDay(date, calendar: calendar)
        guard occurrenceDay <= day,
              let chore = dailyList(on: date).first(where: { $0.id == choreID }),
              chore.isScheduledOccurrence,
              !chore.isNotNeeded,
              let parent = selectedMember else { throw HouseholdError.unavailableDay }
        if chore.configuration.mode == .alternating {
            guard alternatingSkipBehavior != nil else { throw HouseholdError.invalidAssignment }
        } else if alternatingSkipBehavior != nil {
            throw HouseholdError.invalidAssignment
        }
        try append(.occurrence(ChoreOccurrenceDisposition(
            choreID: choreID, revisionID: chore.configuration.id, day: chore.day, state: .notNeeded,
            alternatingSkipBehavior: alternatingSkipBehavior, recordedByMemberID: parent.id
        )))
    }

    func setCompletion(choreID: UUID, memberID: UUID, date: Date, state: DailyStateKind) throws {
        try requireWriteAccess()
        let requestedDay = CivilDay(date, calendar: calendar)
        if selectedMember?.role == .child && !PermissionService.canChildEdit(day: requestedDay, today: day) {
            throw HouseholdError.completionLocked
        }
        guard let actor = selectedMember,
              let chore = dailyList(on: date).first(where: { $0.id == choreID }),
              PermissionService.canSetState(actor: actor, target: memberID, chore: chore, state: state) else {
            throw HouseholdError.permission
        }
        try append(.completion(DatedCompletion(choreID: choreID, revisionID: chore.configuration.id,
                                              memberID: memberID, day: chore.day, state: state,
                                              eligibleMemberIDs: (chore.configuration.mode == .anyOne
                                                  ? chore.eligibleMembers : chore.requiredMembers).map(\.id),
                                              mode: chore.configuration.mode, recordedByMemberID: actor.id)))
    }

    func setExcused(memberID: UUID, date: Date, excused: Bool) throws {
        try requireParent()
        let dateDay = CivilDay(date, calendar: calendar)
        guard dateDay <= day, let member = snapshot.member(memberID), member.role == .child,
              member.isActive(on: dateDay) else { throw HouseholdError.unavailableDay }
        try append(.excuse(Excuse(memberID: memberID, day: dateDay, isExcused: excused)))
    }

    func requestProfiles(_ ids: [UUID], deviceName: String) throws {
        try requireWriteAccess()
        guard let participant = session.cloudParticipantID, session.location != nil,
              !ids.isEmpty, Set(ids).isSubset(of: Set(snapshot.members.filter { snapshot.isActive($0, on: day) }.map(\.id))) else {
            throw HouseholdError.missingProfile
        }
        try append(.request(ProfileRequest(id: UUID(), deviceID: session.deviceID, cloudParticipantID: participant,
                                          deviceName: try validatedName(deviceName), memberIDs: ids)))
    }

    func approve(_ request: ProfileRequest, memberIDs: [UUID]) throws {
        try requireParent()
        guard let parent = selectedMember, snapshot.requests.contains(request),
              Set(memberIDs).isSubset(of: Set(request.memberIDs)) else { throw HouseholdError.permission }
        try append(.grant(ProfileGrant(requestID: request.id, deviceID: request.deviceID,
                                       cloudParticipantID: request.cloudParticipantID, memberIDs: memberIDs,
                                       approvedBy: parent.id)))
    }

    func revoke(_ grant: ProfileGrant) throws {
        try requireParent()
        guard let parent = selectedMember else { throw HouseholdError.permission }
        try append(.grant(ProfileGrant(requestID: grant.requestID, deviceID: grant.deviceID,
                                       cloudParticipantID: grant.cloudParticipantID, memberIDs: [], approvedBy: parent.id)))
    }

    func invitationStatus(_ invitation: FamilyInvitation) -> InvitationLifecycleStatus {
        snapshot.invitationStatus(invitation, now: clock())
    }

    func createChildInvitation(memberID: UUID) async throws -> IssuedFamilyInvitation {
        try requireParent()
        guard let member = snapshot.member(memberID), member.role == .child,
              snapshot.isActive(member, on: day) else { throw HouseholdError.permission }
        return try await issueInvitation(for: member, adding: nil)
    }

    func createParentInvitation(name: String, avatar: AvatarOption) async throws -> IssuedFamilyInvitation {
        try requireParent()
        guard let household else { throw HouseholdError.noHousehold }
        let name = try validatedName(name)
        guard !snapshot.members.contains(where: {
            $0.role == .parent && $0.archivedFrom == nil
                && $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { throw HouseholdError.duplicateName }
        let member = FamilyMember(id: UUID(), householdID: household.id, displayName: name, role: .parent,
                                  avatar: avatar, joinedDay: day)
        return try await issueInvitation(for: member, adding: member)
    }

    func revokeInvitation(_ invitation: FamilyInvitation) async throws {
        try requireParent()
        guard snapshot.invitation(invitation.id) == invitation,
              snapshot.invitationClaim(invitation.id)?.deviceID != session.deviceID,
              let parent = selectedMember, let transport, let location = session.location else {
            throw HouseholdError.permission
        }
        try await transport.revokeInvitationAccess(participantID: invitation.cloudShareParticipantID, from: location)
        var bodies: [HouseholdFactBody] = [
            .invitationRevocation(InvitationRevocation(invitationID: invitation.id,
                                                       revokedByMemberID: parent.id))
        ]
        if snapshot.invitationClaim(invitation.id) == nil, invitation.role == .parent,
           var unclaimedParent = snapshot.member(invitation.memberID) {
            unclaimedParent.archivedFrom = day
            bodies.append(.member(unclaimedParent))
        }
        try append(bodies)
        try await synchronize()
    }

    @discardableResult
    func collectOwnerTransitionPreflight() async -> OwnerTransitionPreflightSnapshot? {
        guard let household, let transport else { return nil }
        let diagnostics = transport.familyTransitionDiagnostics
        let ownsDiagnosticRun = !diagnostics.isActive
        if ownsDiagnosticRun {
            diagnostics.begin(targetHouseholdID: household.id,
                              localAttemptID: session.accountMembershipLockAttemptID,
                              localParticipantID: session.cloudParticipantID)
        }
        let localFacts = (try? repository.facts(householdID: household.id)) ?? []
        let localPendingCount = (try? repository.pending(householdID: household.id,
                                                         includingRejected: true).count) ?? 0
        let result = await transport.ownerTransitionPreflight(
            targetHouseholdID: household.id,
            localSession: session,
            localFacts: localFacts,
            localPendingFactCount: localPendingCount
        )
        diagnostics.record(preflight: result)
        if ownsDiagnosticRun {
            diagnostics.finish(outcome: result.cloudErrors.isEmpty ? .succeeded : .failed)
        }
        return result
    }

    @discardableResult
    func collectChildRecoveryPreflight() async -> ChildRecoveryPreflightSnapshot? {
        guard let transport,
              let householdID = session.location?.householdID ?? session.householdID else { return nil }
        let diagnostics = transport.familyTransitionDiagnostics
        diagnostics.begin(targetHouseholdID: householdID,
                          localAttemptID: session.accountMembershipLockAttemptID,
                          localParticipantID: session.cloudParticipantID)
        let localFacts = (try? repository.facts(householdID: householdID)) ?? []
        let result = await transport.childRecoveryPreflight(localSession: session, localFacts: localFacts)
        diagnostics.record(childRecoveryPreflight: result)
        diagnostics.finish(outcome: result.cloudErrors.isEmpty ? .succeeded : .failed)
        return result
    }

    private func issueInvitation(for member: FamilyMember, adding newMember: FamilyMember?) async throws
        -> IssuedFamilyInvitation {
        try requireParent()
        guard session.pendingFamilyDeletion != true else { throw HouseholdError.permission }
        guard let household, member.householdID == household.id, member.role == .parent || newMember == nil else {
            throw HouseholdError.permission
        }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let diagnostics = transport.familyTransitionDiagnostics
        diagnostics.begin(targetHouseholdID: household.id,
                          localAttemptID: session.accountMembershipLockAttemptID,
                          localParticipantID: session.cloudParticipantID)
        do {
            if session.location == nil { _ = await collectOwnerTransitionPreflight() }
            if session.location?.isOwner == true {
                try await pruneUnavailableInvitationAccess()
            }
            let code = try InvitationCode.generate()
            if session.location == nil { try await connect() }
            try await synchronize()
            guard let location = session.location, let parent = selectedMember else {
                throw HouseholdError.cloudUnavailable
            }
            let now = try await transport.invitationValidationTime(in: location, clientTime: clock())
            let issuedMember = newMember.map {
                FamilyMember(id: $0.id, householdID: $0.householdID, displayName: $0.displayName,
                             role: $0.role, avatar: $0.avatar,
                             joinedDay: CivilDay(now, calendar: household.calendar), archivedFrom: $0.archivedFrom)
            }
            let access = try await transport.createInvitationAccess(for: location,
                                                                    title: household.name, role: member.role)
            let invitation = FamilyInvitation(id: UUID(), householdID: household.id, claimFactID: UUID(),
                                              memberID: member.id, role: member.role,
                                              codeDigest: InvitationCode.digest(code)!, createdAt: now,
                                              expiresAt: now.addingTimeInterval(InvitationCode.lifetime),
                                              createdByMemberID: parent.id,
                                              cloudShareParticipantID: access.participantID,
                                              cloudShareURLDigest: InvitationCode.shareURLDigest(access.url))
            do {
                var bodies: [HouseholdFactBody] = []
                if let issuedMember { bodies.append(.member(issuedMember)) }
                bodies.append(.invitation(invitation))
                diagnostics.record(stage: .invitationAppend, outcome: .started, householdID: household.id,
                                   factCount: bodies.count)
                try append(bodies)
                diagnostics.record(stage: .invitationAppend, outcome: .succeeded, householdID: household.id,
                                   factCount: bodies.count)
                try await synchronize()
                diagnostics.finish(outcome: .succeeded)
                return IssuedFamilyInvitation(invitation: invitation, code: code, shareURL: access.url)
            } catch {
                if snapshot.invitation(invitation.id) == nil {
                    diagnostics.record(stage: .invitationAppend, outcome: .failed,
                                       householdID: household.id, error: error)
                }
                diagnostics.finish(outcome: .failed, error: error)
                try? await transport.revokeInvitationAccess(participantID: access.participantID, from: location)
                if snapshot.invitation(invitation.id) != nil {
                    var cleanup: [HouseholdFactBody] = [
                        .invitationRevocation(InvitationRevocation(invitationID: invitation.id,
                                                                   revokedByMemberID: parent.id))
                    ]
                    if var unsharedParent = issuedMember {
                        unsharedParent.archivedFrom = day
                        cleanup.append(.member(unsharedParent))
                    }
                    try? append(cleanup)
                }
                throw error
            }
        } catch {
            if diagnostics.isActive { diagnostics.finish(outcome: .failed, error: error) }
            throw error
        }
    }

    func connect() async throws {
        try requireParent()
        guard let household, let transport else { throw HouseholdError.cloudUnavailable }
        if session.location != nil {
            try await synchronize()
            try await reconcileAccountMembershipLock()
            return
        }
        let connectingSession = session
        transport.familyTransitionDiagnostics.record(stage: .participantLookup, outcome: .started,
                                                     householdID: household.id)
        let participant: String
        do {
            participant = try await transport.participantID()
            transport.familyTransitionDiagnostics.expect(participantID: participant)
            transport.familyTransitionDiagnostics.record(stage: .participantLookup, outcome: .succeeded,
                                                         householdID: household.id,
                                                         participantID: participant)
        } catch {
            transport.familyTransitionDiagnostics.record(stage: .participantLookup, outcome: .failed,
                                                         householdID: household.id, error: error)
            throw error
        }
        guard session.deviceID == connectingSession.deviceID,
              session.householdID == connectingSession.householdID, session.location == nil else {
            throw HouseholdError.noHousehold
        }
        let binding = AccountMembershipBinding.owner(householdID: household.id)
        let lock = try await acquireAccountMembershipLock(householdID: household.id,
                                                          attemptID: session.accountMembershipLockAttemptID,
                                                          matching: binding)
        transport.familyTransitionDiagnostics.expect(attemptID: lock.attemptID)
        var provisional = session
        provisional.cloudParticipantID = participant
        provisional.accountMembershipLockAttemptID = lock.attemptID
        try repository.commit(facts: [], session: provisional)
        session = provisional
        let location = try await transport.createZone(for: household)
        let lifecycleState = try await transport.ensureFamilyLifecycleAuthority(
            householdID: household.id,
            expectedParticipantID: participant
        )
        guard lifecycleState == .active else { throw HouseholdError.accountMembershipConflict }
        guard session.deviceID == connectingSession.deviceID,
              session.householdID == connectingSession.householdID, session.location == nil else {
            throw HouseholdError.noHousehold
        }
        var updated = session
        updated.location = location
        updated.cloudParticipantID = participant
        updated.accountMembershipLockAttemptID = lock.attemptID
        try repository.commit(facts: [], session: updated)
        session = updated
        try await synchronize()
        let active = try await transport.activateAccountMembershipLock(householdID: household.id,
                                                                        attemptID: lock.attemptID,
                                                                        claimBinding: binding,
                                                                        ownerAuthorityBinding: ownerAuthorityBinding(
                                                                            for: location,
                                                                            participant: participant
                                                                        ),
                                                                        now: clock())
        var connected = session
        connected.accountMembershipLockAttemptID = active.attemptID
        connected.accountMembershipClaimBinding = binding
        try repository.commit(facts: [], session: connected)
        session = connected
    }

    func discoverFamilies() async throws -> [CloudFamily] {
        guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        _ = try await transport.participantID()
        return try await transport.discoverFamilies()
    }

    func discoverOwnerRecoveries() async throws -> [CloudFamily] {
        guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
        let candidates = try await filteredOwnerRecoveryCandidates()
        guard candidates.count == 1 else { return [] }
        return [candidates[0].family]
    }

    func recoverOwnerFamily(_ location: CloudLocation) async throws {
        guard session.householdID == nil, location.isOwner else { throw HouseholdError.invitationUnavailable }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let participant = try await transport.participantID()
        let binding = AccountMembershipBinding.owner(householdID: location.householdID)
        if let existing = try await transport.accountMembershipLock(), existing.state == .active,
           (existing.householdID != location.householdID || existing.claimBinding != binding) {
            throw HouseholdError.accountMembershipConflict
        }
        let candidates = try await filteredOwnerRecoveryCandidates()
        guard candidates.count == 1, candidates[0].family.location == location else {
            throw HouseholdError.invitationUnavailable
        }
        let member = candidates[0].member
        let attemptID = session.accountMembershipLockAttemptID ?? UUID()
        let lock = try await acquireAccountMembershipLock(householdID: location.householdID,
                                                          attemptID: attemptID, matching: binding)
        if session.accountMembershipLockAttemptID != lock.attemptID || session.cloudParticipantID != participant {
            var provisional = session
            provisional.accountMembershipLockAttemptID = lock.attemptID
            provisional.cloudParticipantID = participant
            try repository.commit(facts: [], session: provisional)
            session = provisional
        }
        let refreshed: (family: CloudFamily, member: FamilyMember, facts: [HouseholdFact])
        do {
            let refreshedCandidates = try await filteredOwnerRecoveryCandidates()
            guard refreshedCandidates.count == 1, let candidate = refreshedCandidates.first,
                  candidate.family.location == location,
                  candidate.member.id == member.id else { throw HouseholdError.invitationUnavailable }
            refreshed = candidate
        } catch {
            if lock.state == .provisional, lock.attemptID == attemptID {
                if (try? await transport.releaseAccountMembershipLock(
                    householdID: location.householdID, attemptID: attemptID,
                    expectedParticipantID: participant, now: clock()
                )) == true {
                    var cleared = session
                    cleared.accountMembershipLockAttemptID = nil
                    do {
                        try repository.commit(facts: [], session: cleared)
                        session = cleared
                    } catch {}
                }
            }
            throw error
        }
        let lifecycleState = try await transport.ensureFamilyLifecycleAuthority(
            householdID: location.householdID,
            expectedParticipantID: participant
        )
        guard lifecycleState == .active else { throw HouseholdError.accountMembershipConflict }
        let active = try await transport.activateAccountMembershipLock(householdID: location.householdID,
                                                                        attemptID: lock.attemptID,
                                                                        claimBinding: binding,
                                                                        ownerAuthorityBinding: ownerAuthorityBinding(
                                                                            for: location,
                                                                            participant: participant
                                                                        ),
                                                                        now: clock())
        var updated = session
        updated.householdID = location.householdID
        updated.location = location
        updated.cloudParticipantID = participant
        updated.selectedMemberID = member.id
        updated.cloudCanWrite = true
        updated.legacyProfileIDs = [member.id]
        updated.accountMembershipLockAttemptID = active.attemptID
        updated.accountMembershipClaimBinding = binding
        try repository.commit(facts: refreshed.facts, session: updated, uploaded: true)
        session = updated
        try reload()
        cloudIsReadOnly = false
        syncMessage = "Family connected"
    }

    func join(url: URL) async throws {
        guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let participant = try await transport.participantID()
        let location = try await transport.invitationLocation(for: url)
        var binding = location.isOwner ? AccountMembershipBinding.owner(householdID: location.householdID) : nil
        if binding == nil, try await transport.hasAcceptedAccess(to: location) {
            let remote = try await transport.fetch(from: location)
            try validate(remote, householdID: location.householdID)
            binding = try membershipBinding(in: HouseholdSnapshot(facts: remote), location: location,
                                              participant: participant)
        }
        let lock = try await acquireAccountMembershipLock(householdID: location.householdID,
                                                          attemptID: session.accountMembershipLockAttemptID,
                                                          matching: binding)
        if session.accountMembershipLockAttemptID != lock.attemptID || session.cloudParticipantID != participant {
            var updated = session
            updated.accountMembershipLockAttemptID = lock.attemptID
            updated.cloudParticipantID = participant
            try repository.commit(facts: [], session: updated)
            session = updated
        }
        try await transport.accept(url: url, expected: location)
        try await importFamily(location, participant: participant, accountLockAttemptID: lock.attemptID)
    }

    func join(url: URL, invitationCode: String) async throws {
        var components = URLComponents()
        components.scheme = "earnedit-invitation"
        components.host = "join"
        components.queryItems = [URLQueryItem(name: "code", value: invitationCode),
                                 URLQueryItem(name: "share", value: url.absoluteString)]
        guard let package = components.url else { throw HouseholdError.invitationNotFound }
        try await redeemInvitation(package.absoluteString)
    }

    func redeemInvitation(_ text: String,
                          openShareURL: (URL) async -> Bool = { await UIApplication.shared.open($0) }) async throws {
        guard let credential = InvitationCredential(text: text),
              let digest = InvitationCode.digest(credential.code) else { throw HouseholdError.invitationNotFound }
        guard !isJoiningInvitation else { return }
        recordJoinReceipt { $0 = LastJoinReceipt() }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let participant: String
        do { participant = try await transport.participantID() }
        catch {
            recordJoinFailure(stage: .package, error: error)
            throw error
        }
        if let pending = session.pendingInvitationPackage {
            guard pending.cloudParticipantID == participant else { throw HouseholdError.wrongAccount }
            guard pending.codeDigest == digest,
                  credential.shareURL == nil || credential.shareURL == pending.shareURL else {
                throw HouseholdError.invitationNotFound
            }
        } else if let shareURL = credential.shareURL {
            try persistInvitationPackage(PendingInvitationPackage(codeDigest: digest, shareURL: shareURL,
                                                                   cloudParticipantID: participant))
        }
        if hasPendingInvitationPackage {
            _ = try await continuePendingInvitation(allowAppleVerification: true, openShareURL: openShareURL)
        } else {
            try await redeemCredential(codeDigest: digest, shareURL: nil)
        }
    }

    /// Retry the same package after cold launch, native callback, or interrupted acceptance.
    /// Opening Apple's URL is conditional on its verification error and explicit user retry.
    @discardableResult
    func continuePendingInvitation(allowAppleVerification: Bool = false,
                                   openShareURL: (URL) async -> Bool = { await UIApplication.shared.open($0) }) async throws -> Bool {
        guard !isJoiningInvitation, var pending = session.pendingInvitationPackage else { return false }
        if session.lastJoinReceipt == nil { recordJoinReceipt { $0 = LastJoinReceipt() } }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        isJoiningInvitation = true
        defer { isJoiningInvitation = false }
        guard try await transport.participantID() == pending.cloudParticipantID else { throw HouseholdError.wrongAccount }
        do {
            try await redeemCredential(codeDigest: pending.codeDigest, shareURL: pending.shareURL)
            try persistInvitationPackage(nil)
            return selectedMember != nil
        } catch let error as CKError where error.code == .participantMayNeedVerification {
            recordJoinFailure(stage: .metadata, error: error)
            pending.needsAppleVerification = true
            try persistInvitationPackage(pending)
            if allowAppleVerification {
                guard await openShareURL(pending.shareURL) else { throw HouseholdError.invitation }
            }
            return false
        } catch {
            recordJoinFailure(stage: joinFailureStage, error: error, preserveExisting: true)
            try clearTerminalInvitationPackage(after: error)
            throw error
        }
    }

    private func persistInvitationPackage(_ package: PendingInvitationPackage?) throws {
        var updated = session
        updated.pendingInvitationPackage = package
        try repository.commit(facts: [], session: updated)
        session = updated
    }

    private func clearTerminalInvitationPackage(after error: Error) throws {
        // Interrupted delivery retains its original digest and account. A terminal refusal
        // clears only the local delivery package so a parent can send a new invitation.
        if !(error is CancellationError), !(error is CKError),
           (error as? HouseholdError) != .familyStillSyncing {
            try persistInvitationPackage(nil)
        }
    }

    private func redeemCredential(codeDigest: String, shareURL: URL?) async throws {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        if session.householdID == nil,
           !hasPendingInvitationPackage || session.pendingInvitationAcceptance?.phase == .cleanupRequired {
            try await retryInvitationCleanup()
        }
        if let location = session.location, let participant = session.cloudParticipantID {
            do {
                if let shareURL,
                   session.pendingInvitationAcceptance?.phase == .awaitingRedemption {
                    guard try await transport.invitationLocation(for: shareURL) == location else {
                        throw HouseholdError.invitationNotFound
                    }
                }
                try await redeemPreparedInvitation(codeDigest: codeDigest, in: location, participant: participant)
            }
            catch {
                guard session.pendingInvitationAcceptance?.phase == .awaitingRedemption else { throw error }
                if let cloudError = error as? CKError, Self.isRetryableInvitationError(cloudError) { throw error }
                if hasPendingInvitationPackage, (error as? HouseholdError) == .familyStillSyncing {
                    throw error
                }
                try await abandonPendingInvitationAcceptance(preserving: error)
            }
            return
        }
        guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
        let participant = try await transport.participantID()
        if let shareURL {
            let location = try await transport.invitationLocation(for: shareURL)
            if try await resumeAccountMembership(participant: participant, requestedLocation: location,
                                                 invitationCodeDigest: codeDigest) { return }
            try await prepareInvitationAcceptance(url: shareURL, location: location, participant: participant)
            try await redeemPreparedInvitation(codeDigest: codeDigest, in: location, participant: participant)
            return
        }
        if try await resumeAccountMembership(participant: participant, requestedLocation: nil,
                                             invitationCodeDigest: codeDigest) { return }
        let families = try await transport.discoverFamilies()
        for family in families {
            let remote = try await transport.fetch(from: family.location)
            let imported = HouseholdSnapshot(facts: remote)
            if imported.invitations.contains(where: { $0.codeDigest == codeDigest }) {
                try await redeemInvitation(codeDigest: codeDigest, in: family.location, participant: participant, remote: remote)
                return
            }
        }
        throw HouseholdError.invitationNotFound
    }

    func accept(metadata: CKShare.Metadata) async {
        do {
            guard let transport else { throw HouseholdError.cloudUnavailable }
            let location = try transport.invitationLocation(for: metadata)
            try await acceptSystemInvitation(location: location) {
                try await transport.accept(metadata: metadata, expected: location)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func acceptSystemInvitation(location: CloudLocation, _ acceptance: () async throws -> Void) async throws {
        if session.lastJoinReceipt == nil { recordJoinReceipt { $0 = LastJoinReceipt() } }
        if let package = session.pendingInvitationPackage {
            guard !isJoiningInvitation else { return }
            isJoiningInvitation = true
            defer { isJoiningInvitation = false }
            guard let transport else { throw HouseholdError.cloudUnavailable }
            guard try await transport.participantID() == package.cloudParticipantID else {
                throw HouseholdError.wrongAccount
            }
            guard try await transport.invitationLocation(for: package.shareURL) == location else {
                throw HouseholdError.invitationNotFound
            }
            do {
                if session.location == location, selectedMember != nil {
                    try await redeemCredential(codeDigest: package.codeDigest, shareURL: package.shareURL)
                } else {
                    try await prepareInvitationAcceptance(location: location, participant: package.cloudParticipantID,
                                                           acceptance: acceptance)
                    try await redeemPreparedInvitation(codeDigest: package.codeDigest, in: location,
                                                       participant: package.cloudParticipantID)
                }
                try persistInvitationPackage(nil)
            } catch {
                recordJoinFailure(stage: joinFailureStage, error: error, preserveExisting: true)
                try clearTerminalInvitationPackage(after: error)
                throw error
            }
            return
        }
        try await acceptSystemInvitationAccess(location: location, acceptance)
    }

    private func acceptSystemInvitationAccess(location: CloudLocation, _ acceptance: () async throws -> Void) async throws {
        guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        try await retryInvitationCleanup()
        let participant = try await transport.participantID()
        if try await resumeAccountMembership(participant: participant, requestedLocation: location,
                                             invitationCodeDigest: nil) { return }
        let accessExisted = try await transport.hasAcceptedAccess(to: location)
        let lock = try await acquireAccountMembershipLock(householdID: location.householdID)
        recordJoinReceipt { $0.lock = .provisional }
        try beginPendingInvitationAcceptance(location: location, participant: participant,
                                             accessExistedBeforeAttempt: accessExisted, attemptID: lock.attemptID)
        do {
            try await acceptance()
            recordJoinReceipt { $0.nativeAcceptance = .yes }
            try confirmPendingInvitationAcceptance(location: location, participant: participant)
            try await identifyPendingInvitation(in: location)
            try await importFamily(location, participant: participant, accountLockAttemptID: lock.attemptID)
        }
        catch let cloudError as CKError where Self.isRetryableInvitationError(cloudError) { throw cloudError }
        catch {
            recordJoinFailure(stage: joinFailureStage, error: error, preserveExisting: true)
            try await abandonPendingInvitationAcceptance(preserving: error)
        }
    }

    func joinExisting(_ location: CloudLocation) async throws {
        guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let participant = try await transport.participantID()
        let binding = location.isOwner ? AccountMembershipBinding.owner(householdID: location.householdID) : nil
        let lock = try await acquireAccountMembershipLock(householdID: location.householdID,
                                                          attemptID: session.accountMembershipLockAttemptID,
                                                          matching: binding)
        try await importFamily(location, participant: participant, accountLockAttemptID: lock.attemptID)
    }

    private func redeemPreparedInvitation(codeDigest: String, in location: CloudLocation, participant: String) async throws {
        do { try await redeemInvitation(codeDigest: codeDigest, in: location, participant: participant) }
        catch let cloudError as CKError where Self.isRetryableInvitationError(cloudError)
            || (hasPendingInvitationPackage && cloudError.code == .operationCancelled) { throw cloudError }
        catch {
            if hasPendingInvitationPackage,
               error is CancellationError || (error as? HouseholdError) == .familyStillSyncing { throw error }
            try persistInvitationPackage(nil)
            try await abandonPendingInvitationAcceptance(preserving: error)
        }
    }

    private func redeemInvitation(codeDigest: String, in location: CloudLocation, participant: String,
                                  remote suppliedFacts: [HouseholdFact]? = nil) async throws {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        guard session.householdID == nil || session.householdID == location.householdID else {
            throw HouseholdError.alreadyHasHousehold
        }
        let remote: [HouseholdFact]
        if let suppliedFacts { remote = suppliedFacts }
        else {
            do { remote = try await transport.fetch(from: location) }
            catch {
                if Self.isInvitationVisibilityError(error) {
                    recordJoinReceipt { $0.sharedZoneVisible = .no }
                }
                recordJoinFailure(stage: .sharedVisibility, error: error)
                if hasPendingInvitationPackage, Self.isInvitationVisibilityError(error) {
                    throw HouseholdError.familyStillSyncing
                }
                throw error
            }
        }
        recordJoinReceipt { $0.sharedZoneVisible = .yes }
        try validate(remote, householdID: location.householdID)
        let imported = HouseholdSnapshot(facts: remote)
        try validateCompleteFamily(imported, householdID: location.householdID)
        if let membership = try imported.committedAccountMembership(participantID: participant) {
            recordJoinReceipt {
                $0.claim = .committed
                $0.exactMembership = .yes
            }
            guard codeDigest == membership.claim.codeDigest else {
                throw HouseholdError.accountMembershipConflict
            }
            let canWrite = try await transport.canWrite(to: location)
            guard canWrite else { throw HouseholdError.readOnly }
            let lock = try await activateAccountMembershipLock(
                location: location, claimBinding: AccountMembershipBinding.invitation(membership)
            )
            recordJoinReceipt { $0.lock = .active }
            try attach(remote: remote, location: location, participant: participant,
                       membership: membership, cloudCanWrite: canWrite,
                       accountLockAttemptID: lock.attemptID)
            return
        }
        guard let invitation = imported.invitations.first(where: { $0.codeDigest == codeDigest }) else {
            recordJoinRefusal(.invitationRecordMissing, stage: .exactInvitation, error: .invitationNotFound)
            throw HouseholdError.invitationNotFound
        }
        guard let member = imported.member(invitation.memberID) else {
            recordJoinRefusal(.memberRecordMissing, stage: .exactInvitation, error: .invitationNotFound)
            throw HouseholdError.invitationNotFound
        }
        guard member.role == invitation.role else {
            recordJoinRefusal(.roleMismatch, stage: .exactInvitation, error: .invitationNotFound)
            throw HouseholdError.invitationNotFound
        }
        guard invitation.householdID == location.householdID else {
            recordJoinRefusal(.householdMismatch, stage: .exactInvitation, error: .invitationNotFound)
            throw HouseholdError.invitationNotFound
        }
        recordJoinReceipt {
            $0.claim = .absent
            $0.exactMembership = .no
        }
        if imported.isInvitationRevoked(invitation.id) {
            recordJoinRefusal(.revoked, stage: .exactInvitation, error: .invitationRevoked)
            throw HouseholdError.invitationRevoked
        }
        let hasExactAccess: Bool
        if let package = session.pendingInvitationPackage,
           package.codeDigest == invitation.codeDigest,
           invitation.cloudShareURLDigest == InvitationCode.shareURLDigest(package.shareURL),
           session.pendingInvitationAcceptance?.invitationID == invitation.id {
            hasExactAccess = try await transport.hasAcceptedAccess(to: location)
        } else {
            hasExactAccess = try await transport.hasInvitationAccess(
                participantID: invitation.cloudShareParticipantID, in: location
            )
        }
        guard hasExactAccess else {
            recordJoinRefusal(.participantSlotMismatch, stage: .exactInvitation, error: .invitationNotFound)
            throw HouseholdError.invitationNotFound
        }
        recordJoinReceipt {
            $0.failureStage = nil
            $0.failureCategory = .none
            $0.refusalReason = .none
        }
        let validationTime = try await transport.invitationValidationTime(in: location, clientTime: clock())
        guard let importedHousehold = imported.household,
              imported.isActive(member, on: CivilDay(validationTime, calendar: importedHousehold.calendar)) else {
            recordJoinRefusal(.memberInactive, stage: .exactInvitation, error: .invitationUnavailable)
            throw HouseholdError.invitationUnavailable
        }
        if let existing = imported.invitationClaim(invitation.id) {
            _ = existing
            recordJoinRefusal(.alreadyClaimed, stage: .claim, error: .invitationConsumed)
            throw HouseholdError.invitationConsumed
        }
        guard validationTime < invitation.expiresAt else {
            recordJoinRefusal(.expired, stage: .exactInvitation, error: .invitationExpired)
            throw HouseholdError.invitationExpired
        }
        guard try await transport.canWrite(to: location) else {
            recordJoinRefusal(.writeUnavailable, stage: .claim, error: .readOnly)
            throw HouseholdError.readOnly
        }
        let attemptID: UUID
        if let replacementAttemptID = try await replaceRevokedMembershipLockIfNeeded(
            in: imported,
            location: location,
            participant: participant,
            invitation: invitation,
            validatedAt: validationTime
        ) {
            attemptID = replacementAttemptID
        } else if let pending = session.pendingInvitationAcceptance, pending.location == location,
           let pendingAttemptID = pending.accountLockAttemptID {
            attemptID = pendingAttemptID
        } else {
            attemptID = try await acquireAccountMembershipLock(householdID: location.householdID).attemptID
            recordJoinReceipt { $0.lock = .provisional }
            try beginPendingInvitationAcceptance(location: location, participant: participant,
                                                 accessExistedBeforeAttempt: true, attemptID: attemptID)
            try confirmPendingInvitationAcceptance(location: location, participant: participant)
            var pending = try requirePendingInvitation(location: location)
            pending.invitationID = invitation.id
            pending.expiresAt = invitation.expiresAt
            try persistPendingInvitation(pending)
        }
        let previousSequence = remote.map(\.sequence).max() ?? 0
        guard previousSequence < Int64.max - 1 else { throw HouseholdError.malformedData }
        let claim = InvitationClaim(invitationID: invitation.id, deviceID: session.deviceID,
                                    cloudParticipantID: participant, memberID: invitation.memberID,
                                    codeDigest: invitation.codeDigest, claimedAt: validationTime)
        let invitationFact = HouseholdFact(id: invitation.claimFactID, householdID: location.householdID,
                                           sequence: previousSequence + 1, authorDeviceID: session.deviceID,
                                           authorMemberID: nil, body: .invitationClaim(claim))
        let accountFact = HouseholdFact(id: InvitationCode.accountClaimID(householdID: location.householdID,
                                                                          participantID: participant,
                                                                          generationID: invitation.id),
                                        householdID: location.householdID, sequence: previousSequence + 2,
                                        authorDeviceID: session.deviceID, authorMemberID: nil,
                                        body: .invitationClaim(claim))
        let confirmedClaims: [HouseholdFact]
        do {
            confirmedClaims = try await transport.claimInvitation([invitationFact, accountFact], in: location)
        } catch HouseholdError.invitationConsumed {
            let refreshed = try await transport.fetch(from: location)
            try validate(refreshed, householdID: location.householdID)
            let refreshedSnapshot = HouseholdSnapshot(facts: refreshed)
            if let membership = try refreshedSnapshot.committedAccountMembership(participantID: participant),
               membership.claim.codeDigest == invitation.codeDigest {
                let canWrite = try await transport.canWrite(to: location)
                let lock = try await activateAccountMembershipLock(
                    location: location, claimBinding: AccountMembershipBinding.invitation(membership),
                    attemptID: attemptID
                )
                recordJoinReceipt {
                    $0.claim = .committed
                    $0.lock = .active
                    $0.exactMembership = .yes
                }
                try attach(remote: refreshed, location: location, participant: participant,
                           membership: membership, cloudCanWrite: canWrite,
                           accountLockAttemptID: lock.attemptID)
                return
            }
            recordJoinRefusal(.atomicClaimConflict, stage: .claim, error: .invitationConsumed)
            throw HouseholdError.invitationConsumed
        } catch {
            recordJoinFailure(stage: .claim, error: error)
            throw error
        }
        recordJoinReceipt {
            $0.claim = .committed
            $0.exactMembership = .yes
        }
        let membership = AccountFamilyMembership(invitation: invitation, claim: claim, member: member)
        let lock = try await activateAccountMembershipLock(
            location: location, claimBinding: AccountMembershipBinding.invitation(membership),
            attemptID: attemptID
        )
        recordJoinReceipt { $0.lock = .active }
        try attach(remote: remote + confirmedClaims, location: location, participant: participant,
                   membership: membership, cloudCanWrite: true,
                   accountLockAttemptID: lock.attemptID)
        syncMessage = "Family joined"
    }

    private func importFamily(_ location: CloudLocation, participant: String,
                              accountLockAttemptID: UUID? = nil) async throws {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let remote = try await transport.fetch(from: location)
        try validate(remote, householdID: location.householdID)
        let imported = HouseholdSnapshot(facts: remote)
        try validateCompleteFamily(imported, householdID: location.householdID)
        let canWrite = try await transport.canWrite(to: location)
        guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
        var updated = session
        updated.householdID = location.householdID
        updated.location = location
        updated.cloudParticipantID = participant
        updated.selectedMemberID = nil
        updated.cloudCanWrite = canWrite
        updated.legacyProfileIDs = []
        updated.accountMembershipLockAttemptID = accountLockAttemptID
        updated.accountMembershipClaimBinding = nil
        try repository.commit(facts: remote, session: updated, uploaded: true)
        session = updated
        cloudIsReadOnly = !canWrite
        try reload()
        syncMessage = "Family connected"
    }

    private func attach(remote: [HouseholdFact], location: CloudLocation, participant: String,
                        membership: AccountFamilyMembership, cloudCanWrite: Bool,
                        accountLockAttemptID: UUID) throws {
        let imported = HouseholdSnapshot(facts: remote)
        guard let committed = try imported.committedAccountMembership(participantID: participant),
              AccountMembershipBinding.invitation(committed) == AccountMembershipBinding.invitation(membership) else {
            throw HouseholdError.malformedData
        }
        var updated = session
        updated.householdID = location.householdID
        updated.location = location
        updated.cloudParticipantID = participant
        updated.selectedMemberID = membership.member.id
        updated.cloudCanWrite = cloudCanWrite
        updated.legacyProfileIDs = []
        updated.pendingInvitationAcceptance = nil
        updated.accountMembershipLockAttemptID = accountLockAttemptID
        updated.accountMembershipClaimBinding = AccountMembershipBinding.invitation(membership)
        try repository.commit(facts: remote, session: updated, uploaded: true)
        session = updated
        cloudIsReadOnly = !cloudCanWrite
        try reload()
        recordJoinReceipt {
            $0.localAttach = .yes
            $0.failureStage = nil
            $0.failureCategory = .none
            $0.refusalReason = .none
        }
    }

    private func acquireAccountMembershipLock(householdID: UUID, attemptID: UUID? = nil,
                                              matching claimBinding: String? = nil) async throws
        -> AccountMembershipLock {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let candidate = attemptID ?? session.accountMembershipLockAttemptID ?? UUID()
        transport.familyTransitionDiagnostics.expect(attemptID: candidate)
        var lock = try await transport.acquireAccountMembershipLock(
            householdID: householdID,
            attemptID: candidate,
            leaseDuration: InvitationCode.lifetime,
            clientTime: clock()
        )
        if lock.state == .provisional, lock.householdID == householdID, lock.attemptID == candidate {
            return lock
        }
        if lock.state == .provisional, lock.householdID == householdID,
           lock.claimBinding == nil,
           let location = try await transport.membershipLocation(householdID: householdID),
           !location.isOwner, try await transport.hasAcceptedAccess(to: location) {
            let remote = try await transport.fetch(from: location)
            try validate(remote, householdID: householdID)
            let imported = HouseholdSnapshot(facts: remote)
            try validateCompleteFamily(imported, householdID: householdID)
            let invitation = try await matchedPendingInvitation(in: imported, location: location)
            let validationTime = try await transport.invitationValidationTime(in: location, clientTime: clock())
            if imported.invitationStatus(invitation, now: validationTime) == .available,
               validationTime < lock.expiresAt {
                // The account already accepted this exact invitation. Local envelope loss does
                // not turn its same-household provisional lease into unrelated membership.
                return lock
            }
        }
        if lock.state == .active, lock.householdID == householdID,
           let claimBinding, lock.claimBinding == claimBinding {
            if let localBinding = session.accountMembershipClaimBinding, localBinding != claimBinding {
                throw HouseholdError.accountMembershipConflict
            }
            return lock
        }
        if lock.state == .active, lock.householdID == householdID,
           claimBinding == nil, session.householdID == nil {
            return lock
        }
        if lock.state == .active, session.householdID == nil {
            try await reconcileInactiveAccountMembershipLock(lock)
            lock = try await transport.acquireAccountMembershipLock(
                householdID: householdID,
                attemptID: candidate,
                leaseDuration: InvitationCode.lifetime,
                clientTime: clock()
            )
            if lock.state == .provisional, lock.householdID == householdID, lock.attemptID == candidate {
                return lock
            }
        }
        let validationTime = try await transport.accountMembershipValidationTime(clientTime: clock())
        if lock.state == .provisional, lock.expiresAt <= validationTime {
            try await reconcileExpiredAccountMembershipLock(lock)
            lock = try await transport.acquireAccountMembershipLock(
                householdID: householdID,
                attemptID: candidate,
                leaseDuration: InvitationCode.lifetime,
                clientTime: clock()
            )
            if lock.state == .provisional, lock.householdID == householdID, lock.attemptID == candidate {
                return lock
            }
            if lock.state == .active, lock.householdID == householdID,
               let claimBinding, lock.claimBinding == claimBinding {
                return lock
            }
        }
        throw HouseholdError.accountMembershipConflict
    }

    private func replaceRevokedMembershipLockIfNeeded(
        in imported: HouseholdSnapshot,
        location: CloudLocation,
        participant: String,
        invitation: FamilyInvitation,
        validatedAt: Date
    ) async throws -> UUID? {
        guard let transport,
              session.householdID == nil,
              let existing = try await transport.accountMembershipLock(),
              existing.householdID == location.householdID,
              existing.state == .active else {
            return nil
        }
        guard let revokedClaimBinding = existing.claimBinding,
              revokedMembershipBindingMatches(existing, in: imported, participant: participant) else {
            throw HouseholdError.accountMembershipConflict
        }
        let deviceID = session.deviceID
        let replacementAttemptID: UUID
        if let pendingAttemptID = session.pendingInvitationAcceptance?.accountLockAttemptID,
           pendingAttemptID != existing.attemptID {
            replacementAttemptID = pendingAttemptID
        } else {
            replacementAttemptID = UUID()
        }
        if var pending = session.pendingInvitationAcceptance {
            guard pending.location == location,
                  pending.cloudParticipantID == participant,
                  pending.phase != .cleanupRequired else { throw HouseholdError.accountMembershipConflict }
            pending.accountLockAttemptID = replacementAttemptID
            pending.invitationID = invitation.id
            pending.expiresAt = invitation.expiresAt
            try persistPendingInvitation(pending)
        } else {
            try beginPendingInvitationAcceptance(
                location: location,
                participant: participant,
                accessExistedBeforeAttempt: true,
                attemptID: replacementAttemptID
            )
            try confirmPendingInvitationAcceptance(location: location, participant: participant)
            var pending = try requirePendingInvitation(location: location)
            pending.invitationID = invitation.id
            pending.expiresAt = invitation.expiresAt
            try persistPendingInvitation(pending)
        }
        guard session.deviceID == deviceID,
              try await transport.participantID() == participant else { throw HouseholdError.wrongAccount }
        transport.familyTransitionDiagnostics.expect(attemptID: replacementAttemptID)
        let replacement = try await transport.replaceActiveRevokedAccountMembershipLock(
            householdID: location.householdID,
            revokedAttemptID: existing.attemptID,
            revokedClaimBinding: revokedClaimBinding,
            replacementAttemptID: replacementAttemptID,
            expectedParticipantID: participant,
            leaseDuration: InvitationCode.lifetime,
            validatedAt: validatedAt
        )
        guard replacement.state == .provisional,
              replacement.householdID == location.householdID,
              replacement.attemptID == replacementAttemptID,
              session.deviceID == deviceID,
              try await transport.participantID() == participant else {
            throw HouseholdError.accountMembershipConflict
        }
        recordJoinReceipt { $0.lock = .provisional }
        return replacementAttemptID
    }

    private func revokedMembershipBindingMatches(
        _ lock: AccountMembershipLock,
        in imported: HouseholdSnapshot,
        participant: String
    ) -> Bool {
        guard let binding = lock.claimBinding else { return false }
        return imported.invitationClaims.contains { claim in
            guard claim.cloudParticipantID == participant,
                  let invitation = imported.invitation(claim.invitationID),
                  imported.isInvitationRevoked(invitation.id),
                  invitation.memberID == claim.memberID,
                  invitation.codeDigest == claim.codeDigest,
                  let member = imported.member(claim.memberID),
                  member.role == invitation.role else { return false }
            return AccountMembershipBinding.invitation(
                AccountFamilyMembership(invitation: invitation, claim: claim, member: member)
            ) == binding
        }
    }

    private func reconcileInactiveAccountMembershipLock(_ lock: AccountMembershipLock) async throws {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let accountGeneration = transport.accountGeneration
        let participant = try await transport.participantID()
        guard transport.accountGeneration == accountGeneration else { throw HouseholdError.wrongAccount }
        guard let location = try await transport.membershipLocation(householdID: lock.householdID) else {
            guard try await releaseAccountMembershipLockIfFamilyDeleted(
                lock,
                participant: participant,
                expectedAccountGeneration: accountGeneration
            ) else { throw HouseholdError.accountMembershipConflict }
            return
        }
        let remote = try await transport.fetch(from: location)
        try validate(remote, householdID: location.householdID)
        let imported = HouseholdSnapshot(facts: remote)
        guard let current = try membershipBinding(in: imported, location: location, participant: participant),
              current == lock.claimBinding else { throw HouseholdError.accountMembershipConflict }
        throw HouseholdError.accountMembershipConflict
    }

    private func reconcileExpiredAccountMembershipLock(_ lock: AccountMembershipLock) async throws {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let accountGeneration = transport.accountGeneration
        let participant = try await transport.participantID()
        guard transport.accountGeneration == accountGeneration else { throw HouseholdError.wrongAccount }
        guard let location = try await transport.membershipLocation(householdID: lock.householdID) else {
            guard transport.accountGeneration == accountGeneration,
                  try await transport.releaseAccountMembershipLock(
                      expectedLock: lock,
                      expectedParticipantID: participant,
                      reason: .expiredProvisional,
                      clientTime: clock(),
                      expectedAccountGeneration: accountGeneration
                  ) else {
                throw HouseholdError.accountMembershipConflict
            }
            return
        }
        let remote = try await transport.fetch(from: location)
        do {
            try validate(remote, householdID: location.householdID)
            let imported = HouseholdSnapshot(facts: remote)
            if let binding = try membershipBinding(in: imported, location: location,
                                                   participant: participant) {
                _ = try await transport.activateAccountMembershipLock(householdID: lock.householdID,
                                                                       attemptID: lock.attemptID,
                                                                       claimBinding: binding,
                                                                       ownerAuthorityBinding: ownerAuthorityBinding(
                                                                           for: location,
                                                                           participant: participant
                                                                       ),
                                                                       now: clock())
                return
            }
        } catch is HouseholdError {
            throw HouseholdError.accountMembershipConflict
        }
        throw HouseholdError.accountMembershipConflict
    }

    private func membershipBinding(in imported: HouseholdSnapshot, location: CloudLocation,
                                   participant: String) throws -> String? {
        guard imported.household?.id == location.householdID else { return nil }
        if location.isOwner { return AccountMembershipBinding.owner(householdID: location.householdID) }
        if let membership = try imported.committedAccountMembership(participantID: participant) {
            return AccountMembershipBinding.invitation(membership)
        }
        if imported.grants.contains(where: { grant in
            grant.cloudParticipantID == participant && grant.memberIDs.contains { imported.member($0) != nil }
        }) {
            return AccountMembershipBinding.legacyShared(householdID: location.householdID,
                                                         participantID: participant)
        }
        return nil
    }

    private func ownerAuthorityBinding(for location: CloudLocation, participant: String) -> String {
        AccountMembershipBinding.ownerAuthority(
            participantID: location.isOwner ? participant : location.ownerName
        )
    }

    private func releaseAccountMembershipLockIfFamilyDeleted(
        _ lock: AccountMembershipLock,
        location: CloudLocation? = nil,
        participant: String,
        expectedAccountGeneration: UInt64
    ) async throws -> Bool {
        guard let transport,
              transport.accountGeneration == expectedAccountGeneration,
              lock.state == .active || lock.state == .released else { return false }
        let hasExactOwnerClaim = lock.claimBinding == AccountMembershipBinding.owner(
            householdID: lock.householdID
        )
        let exactOwnerAuthorityBinding = exactOwnerAuthorityBinding(for: lock, participant: participant)
        if hasExactOwnerClaim, exactOwnerAuthorityBinding == nil { return false }
        let ownerAuthorityBinding = exactOwnerAuthorityBinding ?? lock.ownerAuthorityBinding ?? location.flatMap { candidate in
            guard candidate.householdID == lock.householdID else { return nil }
            return self.ownerAuthorityBinding(for: candidate, participant: participant)
        }
        guard let ownerAuthorityBinding,
              let state = try await transport.familyLifecycleState(
                householdID: lock.householdID,
                ownerAuthorityBinding: ownerAuthorityBinding,
                expectedParticipantID: participant
              ),
              state == .deleted,
              transport.accountGeneration == expectedAccountGeneration,
              try await transport.membershipLocation(householdID: lock.householdID) == nil,
              transport.accountGeneration == expectedAccountGeneration,
              try await transport.accountMembershipLock() == lock,
              transport.accountGeneration == expectedAccountGeneration else { return false }
        if lock.state == .released { return true }
        return try await transport.releaseAccountMembershipLock(
            expectedLock: lock,
            expectedParticipantID: participant,
            reason: .confirmedFamilyDeletion,
            clientTime: clock(),
            expectedAccountGeneration: expectedAccountGeneration
        )
    }

    private func exactOwnerAuthorityBinding(for lock: AccountMembershipLock, participant: String) -> String? {
        guard lock.state == .active || lock.state == .released,
              lock.claimBinding == AccountMembershipBinding.owner(householdID: lock.householdID) else { return nil }
        let expected = AccountMembershipBinding.ownerAuthority(participantID: participant)
        guard lock.ownerAuthorityBinding == nil || lock.ownerAuthorityBinding == expected else { return nil }
        return expected
    }

    private func transitionToOnboardingIfFamilyDeleted(
        lock: AccountMembershipLock,
        location: CloudLocation? = nil,
        participant: String,
        expectedSession: DeviceSession,
        expectedAccountGeneration: UInt64
    ) async throws -> Bool {
        guard try await releaseAccountMembershipLockIfFamilyDeleted(
            lock,
            location: location,
            participant: participant,
            expectedAccountGeneration: expectedAccountGeneration
        ) else { return false }
        guard let transport,
              try await transport.participantID() == participant,
              transport.accountGeneration == expectedAccountGeneration,
              session == expectedSession else { throw HouseholdError.wrongAccount }
        try purgeDeletedFamily(householdID: lock.householdID)
        return true
    }

    private func ownerRecoveryMember(in imported: HouseholdSnapshot) -> FamilyMember? {
        guard imported.household != nil else { return nil }
        let invitedParentIDs = Set(imported.invitations.compactMap { invitation -> UUID? in
            invitation.role == .parent ? invitation.memberID : nil
        })
        let candidates = imported.members.filter {
            $0.role == .parent && $0.archivedFrom == nil && !invitedParentIDs.contains($0.id)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func ownerRecoveryCandidates(restrictedTo householdID: UUID? = nil) async throws
        -> [(family: CloudFamily, member: FamilyMember, facts: [HouseholdFact])] {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        var candidates: [(family: CloudFamily, member: FamilyMember, facts: [HouseholdFact])] = []
        for family in try await transport.discoverFamilies()
        where family.location.isOwner && (householdID == nil || family.location.householdID == householdID) {
            if let candidate = try await ownerRecoveryCandidate(for: family) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    private func filteredOwnerRecoveryCandidates() async throws
        -> [(family: CloudFamily, member: FamilyMember, facts: [HouseholdFact])] {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        guard let lock = try await transport.accountMembershipLock(), lock.state == .active else {
            return try await ownerRecoveryCandidates()
        }
        guard lock.claimBinding == AccountMembershipBinding.owner(householdID: lock.householdID) else {
            return []
        }
        return try await ownerRecoveryCandidates(restrictedTo: lock.householdID)
    }

    private func ownerRecoveryCandidate(for family: CloudFamily) async throws
        -> (family: CloudFamily, member: FamilyMember, facts: [HouseholdFact])? {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let remote = try await transport.fetch(from: family.location)
        try validate(remote, householdID: family.location.householdID)
        let imported = HouseholdSnapshot(facts: remote)
        try validateCompleteFamily(imported, householdID: family.location.householdID)
        guard let member = ownerRecoveryMember(in: imported) else { return nil }
        return (family, member, remote)
    }

    private func activateAccountMembershipLock(location: CloudLocation, claimBinding: String,
                                               attemptID suppliedAttemptID: UUID? = nil) async throws
        -> AccountMembershipLock {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let participant = try await transport.participantID()
        let attemptID: UUID
        if let existing = suppliedAttemptID ?? session.pendingInvitationAcceptance?.accountLockAttemptID {
            attemptID = existing
        } else {
            let acquired = try await acquireAccountMembershipLock(householdID: location.householdID,
                                                                  matching: claimBinding)
            attemptID = acquired.attemptID
        }
        return try await transport.activateAccountMembershipLock(
            householdID: location.householdID,
            attemptID: attemptID,
            claimBinding: claimBinding,
            ownerAuthorityBinding: ownerAuthorityBinding(for: location, participant: participant),
            now: clock()
        )
    }

    private func prepareInvitationAcceptance(url: URL, location: CloudLocation, participant: String) async throws {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        try await prepareInvitationAcceptance(location: location, participant: participant) {
            try await transport.accept(url: url, expected: location)
        }
    }

    private func prepareInvitationAcceptance(location: CloudLocation, participant: String,
                                             acceptance: () async throws -> Void) async throws {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        if let pending = session.pendingInvitationAcceptance, hasPendingInvitationPackage {
            guard pending.location == location, pending.cloudParticipantID == participant,
                  pending.phase != .cleanupRequired else { throw HouseholdError.invitationNotFound }
        } else {
            let accessExisted = try await transport.hasAcceptedAccess(to: location)
            let lock = try await acquireAccountMembershipLock(householdID: location.householdID)
            recordJoinReceipt {
                switch lock.state {
                case .provisional: $0.lock = .provisional
                case .active: $0.lock = .active
                case .released: $0.lock = .released
                }
            }
            try beginPendingInvitationAcceptance(location: location, participant: participant,
                                                 accessExistedBeforeAttempt: accessExisted, attemptID: lock.attemptID)
        }
        do {
            if session.pendingInvitationAcceptance?.phase == .acceptingAccess {
                do {
                    try await acceptance()
                    recordJoinReceipt { $0.nativeAcceptance = .yes }
                } catch {
                    let stage: JoinFailureStage = (error as? CKError)?.code == .participantMayNeedVerification
                        ? .metadata : .nativeAcceptance
                    recordJoinFailure(stage: stage, error: error)
                    throw error
                }
                try Task.checkCancellation()
                guard try await transport.participantID() == participant else { throw HouseholdError.wrongAccount }
                try confirmPendingInvitationAcceptance(location: location, participant: participant)
            }
            try await identifyPendingInvitation(in: location)
        } catch let cloudError as CKError where Self.isRetryableInvitationError(cloudError)
            || (hasPendingInvitationPackage && (cloudError.code == .participantMayNeedVerification
                                                 || cloudError.code == .operationCancelled)) {
            throw cloudError
        } catch is CancellationError where hasPendingInvitationPackage {
            throw CancellationError()
        } catch {
            if hasPendingInvitationPackage, session.pendingInvitationAcceptance?.phase == .awaitingRedemption,
               (Self.isInvitationVisibilityError(error)
                || ((error as? HouseholdError) == .invitationNotFound
                    && session.lastJoinReceipt?.refusalReason == .invitationRecordMissing)) {
                throw HouseholdError.familyStillSyncing
            }
            try await abandonPendingInvitationAcceptance(preserving: error)
        }
    }

    private func beginPendingInvitationAcceptance(location: CloudLocation, participant: String,
                                                  accessExistedBeforeAttempt: Bool, attemptID: UUID) throws {
        let continuingImport = session.householdID == location.householdID && session.location == location
            && session.cloudParticipantID == participant && session.accountMembershipClaimBinding == nil
            && profiles.isEmpty
        guard (session.householdID == nil || continuingImport), session.pendingInvitationAcceptance == nil else {
            throw HouseholdError.alreadyHasHousehold
        }
        let retainedFactIDs = try repository.facts(householdID: location.householdID).map(\.id)
        var updated = session
        updated.pendingInvitationAcceptance = PendingInvitationAcceptance(
            location: location,
            cloudParticipantID: participant,
            retainedFactIDs: retainedFactIDs,
            accessExistedBeforeAttempt: accessExistedBeforeAttempt,
            accountLockAttemptID: attemptID,
            invitationID: nil,
            expiresAt: nil,
            phase: .acceptingAccess
        )
        try repository.commit(facts: [], session: updated)
        session = updated
    }

    private func requirePendingInvitation(location: CloudLocation) throws -> PendingInvitationAcceptance {
        guard let pending = session.pendingInvitationAcceptance, pending.location == location else {
            throw HouseholdError.invitationNotFound
        }
        return pending
    }

    private func confirmPendingInvitationAcceptance(location: CloudLocation, participant: String) throws {
        guard var pending = session.pendingInvitationAcceptance,
              pending.location == location,
              pending.cloudParticipantID == participant,
              pending.phase == .acceptingAccess else { throw HouseholdError.invitationNotFound }
        pending.phase = .awaitingRedemption
        var updated = session
        updated.pendingInvitationAcceptance = pending
        try repository.commit(facts: [], session: updated)
        session = updated
    }

    private func identifyPendingInvitation(in location: CloudLocation) async throws {
        guard var pending = session.pendingInvitationAcceptance,
              pending.location == location,
              pending.phase == .awaitingRedemption,
              let transport else { throw HouseholdError.invitationNotFound }
        let remote: [HouseholdFact]
        do {
            remote = try await transport.fetch(from: location)
            recordJoinReceipt { $0.sharedZoneVisible = .yes }
        } catch {
            if Self.isInvitationVisibilityError(error) {
                recordJoinReceipt { $0.sharedZoneVisible = .no }
            }
            recordJoinFailure(stage: .sharedVisibility, error: error)
            throw error
        }
        try validate(remote, householdID: location.householdID)
        let imported = HouseholdSnapshot(facts: remote)
        try validateCompleteFamily(imported, householdID: location.householdID)
        let invitation: FamilyInvitation
        do { invitation = try await matchedPendingInvitation(in: imported, location: location) }
        catch {
            recordJoinFailure(stage: .exactInvitation, error: error)
            throw error
        }
        pending.invitationID = invitation.id
        pending.expiresAt = invitation.expiresAt
        try persistPendingInvitation(pending)
        let validationTime = try await transport.invitationValidationTime(in: location, clientTime: clock())
        switch imported.invitationStatus(invitation, now: validationTime) {
        case .available:
            recordJoinReceipt {
                $0.claim = .absent
                $0.exactMembership = .no
                $0.failureStage = nil
                $0.failureCategory = .none
                $0.refusalReason = .none
            }
            return
        case .expired:
            recordJoinRefusal(.expired, stage: .exactInvitation, error: .invitationExpired)
            throw HouseholdError.invitationExpired
        case .revoked:
            recordJoinRefusal(.revoked, stage: .exactInvitation, error: .invitationRevoked)
            throw HouseholdError.invitationRevoked
        case .consumed:
            recordJoinRefusal(.alreadyClaimed, stage: .claim, error: .invitationConsumed)
            throw HouseholdError.invitationConsumed
        }
    }

    private func matchedPendingInvitation(in imported: HouseholdSnapshot,
                                          location: CloudLocation) async throws -> FamilyInvitation {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        if let package = session.pendingInvitationPackage {
            let urlDigest = InvitationCode.shareURLDigest(package.shareURL)
            let matches = imported.invitations.filter {
                $0.codeDigest == package.codeDigest && $0.cloudShareURLDigest == urlDigest
            }
            guard matches.count == 1, let invitation = matches.first else {
                let reason: JoinRefusalReason
                if matches.count > 1 {
                    reason = .participantSlotAmbiguous
                } else if imported.invitations.contains(where: {
                    $0.codeDigest == package.codeDigest || $0.cloudShareURLDigest == urlDigest
                }) {
                    reason = .participantSlotMismatch
                } else {
                    reason = .invitationRecordMissing
                }
                recordJoinRefusal(reason, stage: .exactInvitation, error: .invitationNotFound)
                throw HouseholdError.invitationNotFound
            }
            return invitation
        }
        var matches: [FamilyInvitation] = []
        for invitation in imported.invitations {
            if try await transport.hasInvitationAccess(participantID: invitation.cloudShareParticipantID,
                                                       in: location) {
                matches.append(invitation)
            }
        }
        guard matches.count == 1, let invitation = matches.first else {
            let reason: JoinRefusalReason
            if matches.count > 1 {
                reason = .participantSlotAmbiguous
            } else if imported.invitations.isEmpty {
                reason = .invitationRecordMissing
            } else {
                reason = .participantSlotMismatch
            }
            recordJoinRefusal(reason, stage: .exactInvitation, error: .invitationNotFound)
            throw HouseholdError.invitationNotFound
        }
        return invitation
    }

    private func persistPendingInvitation(_ pending: PendingInvitationAcceptance) throws {
        var updated = session
        updated.pendingInvitationAcceptance = pending
        try repository.commit(facts: [], session: updated)
        session = updated
    }

    private func markPendingInvitationForCleanup(_ pending: PendingInvitationAcceptance) throws {
        var cleanup = pending
        cleanup.phase = .cleanupRequired
        var updated = session
        updated.householdID = nil
        updated.selectedMemberID = nil
        updated.cloudParticipantID = nil
        updated.location = nil
        updated.cloudCanWrite = nil
        updated.legacyProfileIDs = nil
        updated.pendingInvitationAcceptance = cleanup
        try repository.discardFacts(householdID: pending.location.householdID,
                                    retaining: Set(pending.retainedFactIDs ?? []), updating: updated)
        session = updated
        facts = []
        rejectedChanges = [:]
        snapshot = HouseholdSnapshot()
        cloudAccessBlocked = false
        cloudIsReadOnly = false
        syncMessage = "On this device"
    }

    private func abandonPendingInvitationAcceptance(preserving error: Error) async throws -> Never {
        guard let pending = session.pendingInvitationAcceptance else { throw error }
        if pending.phase != .cleanupRequired {
            try markPendingInvitationForCleanup(pending)
        }
        do { try await retryInvitationCleanup() } catch {}
        throw error
    }

    private nonisolated static func isRetryableInvitationError(_ error: CKError) -> Bool {
        switch error.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited,
             .zoneBusy, .notAuthenticated, .quotaExceeded:
            return true
        default:
            return false
        }
    }

    private nonisolated static func isInvitationVisibilityError(_ error: Error) -> Bool {
        if (error as? HouseholdError) == .familyStillSyncing { return true }
        guard let cloudError = error as? CKError else { return false }
        return cloudError.code == .zoneNotFound || cloudError.code == .unknownItem
            || cloudError.code == .permissionFailure
    }

    func recordJoinRootRoute(_ route: JoinRootRoute) {
        guard session.lastJoinReceipt != nil, session.lastJoinReceipt?.rootRoute != route else { return }
        recordJoinReceipt { $0.rootRoute = route }
    }

    private func recordJoinReceipt(_ change: (inout LastJoinReceipt) -> Void) {
        var updated = session
        var receipt = updated.lastJoinReceipt ?? LastJoinReceipt()
        change(&receipt)
        updated.lastJoinReceipt = receipt
        guard (try? repository.commit(facts: [], session: updated)) != nil else { return }
        session = updated
    }

    private func recordJoinFailure(stage: JoinFailureStage, error: Error, preserveExisting: Bool = false) {
        recordJoinReceipt {
            if preserveExisting, $0.failureStage != nil { return }
            $0.failureStage = stage
            $0.failureCategory = Self.joinFailureCategory(for: error)
            if stage == .nativeAcceptance { $0.nativeAcceptance = .no }
        }
    }

    private func recordJoinRefusal(_ reason: JoinRefusalReason, stage: JoinFailureStage,
                                   error: HouseholdError) {
        recordJoinReceipt {
            $0.refusalReason = reason
            $0.failureStage = stage
            $0.failureCategory = Self.joinFailureCategory(for: error)
        }
    }

    private var joinFailureStage: JoinFailureStage {
        if session.lastJoinReceipt?.nativeAcceptance != .yes { return .nativeAcceptance }
        if session.lastJoinReceipt?.sharedZoneVisible != .yes { return .sharedVisibility }
        if session.lastJoinReceipt?.claim != .committed { return .claim }
        if session.lastJoinReceipt?.lock != .active { return .lock }
        return .localAttach
    }

    private nonisolated static func joinFailureCategory(for error: Error) -> JoinFailureCategory {
        if error is CancellationError { return .cancelled }
        if let cloudError = error as? CKError {
            if isRetryableInvitationError(cloudError) { return .cloudKitRetryable }
            switch cloudError.code {
            case .zoneNotFound, .unknownItem: return .cloudKitVisibility
            case .permissionFailure: return .cloudKitPermission
            default: return .cloudKitOther
            }
        }
        switch error as? HouseholdError {
        case .accountMembershipConflict: return .accountConflict
        case .wrongAccount: return .wrongAccount
        case .readOnly: return .readOnly
        case .invitation, .invitationNotFound, .invitationExpired, .invitationRevoked,
             .invitationConsumed, .invitationUnavailable, .familyStillSyncing:
            return .invitationRefused
        default: return .other
        }
    }

    func pendingInvitationCleanupDelay() async throws -> TimeInterval? {
        guard let pending = session.pendingInvitationAcceptance else { return nil }
        if pending.phase == .cleanupRequired {
            return Self.pendingInvitationCleanupRetryDelay
        }
        guard pending.phase == .awaitingRedemption else { return nil }
        guard let expiration = pending.expiresAt else {
            return Self.pendingInvitationCleanupRetryDelay
        }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        do {
            let validationTime = try await transport.invitationValidationTime(
                in: pending.location, clientTime: clock()
            )
            return min(max(0, expiration.timeIntervalSince(validationTime)), InvitationCode.lifetime)
        } catch let error as CKError where Self.isRetryableInvitationError(error) {
            return Self.pendingInvitationCleanupRetryDelay
        }
    }

    func retryScheduledInvitationCleanup() async throws -> TimeInterval? {
        // Package delivery owns continuation while awaiting Apple's UI or an in-flight join.
        guard !isJoiningInvitation, !hasPendingInvitationPackage else {
            return Self.pendingInvitationCleanupRetryDelay
        }
        do {
            try await retryInvitationCleanup()
            return nil
        } catch let error as CKError where Self.isRetryableInvitationError(error) {
            return Self.pendingInvitationCleanupRetryDelay
        }
    }

    func retryInvitationCleanup() async throws {
        let predecessor = invitationCleanupTail
        let cleanup = Task { @MainActor in
            await predecessor?.value
            try Task.checkCancellation()
            try await performInvitationCleanup()
        }
        invitationCleanupTail = Task { _ = try? await cleanup.value }
        try await withTaskCancellationHandler {
            try await cleanup.value
        } onCancel: {
            cleanup.cancel()
        }
    }

    private func performInvitationCleanup() async throws {
        try Task.checkCancellation()
        guard var pending = session.pendingInvitationAcceptance else { return }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        guard try await transport.participantID() == pending.cloudParticipantID else {
            throw HouseholdError.wrongAccount
        }
        try Task.checkCancellation()
        if pending.accountLockAttemptID == nil {
            pending.accountLockAttemptID = try await acquireAccountMembershipLock(
                householdID: pending.location.householdID
            ).attemptID
            try persistPendingInvitation(pending)
        }
        let remote = try await accessibleFacts(at: pending.location)
        try Task.checkCancellation()
        if let remote {
            try validate(remote, householdID: pending.location.householdID)
            let imported = HouseholdSnapshot(facts: remote)
            try validateCompleteFamily(imported, householdID: pending.location.householdID)
            if let membership = try imported.committedAccountMembership(
                participantID: pending.cloudParticipantID
            ) {
                let canWrite = try await transport.canWrite(to: pending.location)
                let lock = try await activateAccountMembershipLock(
                    location: pending.location, claimBinding: AccountMembershipBinding.invitation(membership),
                    attemptID: pending.accountLockAttemptID
                )
                try attach(remote: remote, location: pending.location, participant: pending.cloudParticipantID,
                           membership: membership, cloudCanWrite: canWrite,
                           accountLockAttemptID: lock.attemptID)
                return
            }
            if pending.phase == .awaitingRedemption {
                if pending.invitationID == nil || pending.expiresAt == nil {
                    let invitation = try await matchedPendingInvitation(in: imported, location: pending.location)
                    pending.invitationID = invitation.id
                    pending.expiresAt = invitation.expiresAt
                    try persistPendingInvitation(pending)
                }
                let validationTime = try await transport.invitationValidationTime(
                    in: pending.location, clientTime: clock()
                )
                if let invitationID = pending.invitationID,
                   let invitation = imported.invitation(invitationID),
                   !imported.isInvitationRevoked(invitationID),
                   imported.invitationClaim(invitationID) == nil,
                   validationTime < (pending.expiresAt ?? invitation.expiresAt) {
                    if session.householdID == nil {
                        try await importFamily(pending.location, participant: pending.cloudParticipantID,
                                               accountLockAttemptID: pending.accountLockAttemptID)
                    }
                    return
                }
            }
        }
        try Task.checkCancellation()
        try markPendingInvitationForCleanup(pending)
        if pending.accessExistedBeforeAttempt == false {
            try Task.checkCancellation()
            try await transport.leave(pending.location, expectedParticipantID: pending.cloudParticipantID)
        }
        if let attemptID = pending.accountLockAttemptID {
            try Task.checkCancellation()
            guard try await transport.releaseAccountMembershipLock(householdID: pending.location.householdID,
                                                                   attemptID: attemptID,
                                                                   expectedParticipantID: pending.cloudParticipantID,
                                                                   now: clock()) else {
                throw HouseholdError.accountMembershipConflict
            }
            recordJoinReceipt { $0.lock = .released }
        }
        try Task.checkCancellation()
        var updated = session
        updated.pendingInvitationAcceptance = nil
        try repository.commit(facts: [], session: updated)
        session = updated
    }

    func reconcileAccountMembershipLock() async throws {
        if session.householdID == nil, session.pendingInvitationAcceptance == nil {
            try await recoverExistingAccountMembership()
            return
        }
        guard session.pendingInvitationAcceptance == nil,
              let location = session.location,
              let participant = session.cloudParticipantID,
              let transport else { return }
        let expectedSession = session
        let accountGeneration = transport.accountGeneration
        guard try await transport.participantID() == participant,
              transport.accountGeneration == accountGeneration else { throw HouseholdError.wrongAccount }
        let remote: [HouseholdFact]
        do {
            remote = try await transport.fetch(from: location)
        } catch let error as CKError where [.permissionFailure, .zoneNotFound, .userDeletedZone].contains(error.code) {
            if let attemptID = expectedSession.accountMembershipLockAttemptID,
               let lock = try await transport.accountMembershipLock(),
               lock.householdID == location.householdID,
               lock.attemptID == attemptID,
               try await transitionToOnboardingIfFamilyDeleted(
                   lock: lock,
                   location: location,
                   participant: participant,
                   expectedSession: expectedSession,
                   expectedAccountGeneration: accountGeneration
               ) {
                return
            }
            throw error
        }
        try validate(remote, householdID: location.householdID)
        let imported = HouseholdSnapshot(facts: remote)
        try await reconcileAccountMembershipLock(imported: imported, location: location,
                                                  participant: participant,
                                                  expectedAccountGeneration: accountGeneration)
    }

    /// Local absence is a bootstrap condition, never evidence that the account left its family.
    private func recoverExistingAccountMembership() async throws {
        guard let transport else {
            isCheckingAccountMembership = false
            return
        }
        isCheckingAccountMembership = true
        defer { isCheckingAccountMembership = false }
        let deviceID = session.deviceID
        let expectedSession = session
        canReleaseStaleOwnerMembership = false
        staleOwnerMembershipReleaseCandidate = nil
        do {
            let accountGeneration = transport.accountGeneration
            let participant = try await transport.participantID()
            guard transport.accountGeneration == accountGeneration else { throw HouseholdError.wrongAccount }
            guard let lock = try await recoveryMembershipLock(participant: participant) else {
                requiresMembershipRecovery = false
                return
            }
            guard lock.state != .released else {
                let expectedSession = session
                let hasExactOwnerClaim = lock.claimBinding == AccountMembershipBinding.owner(
                    householdID: lock.householdID
                )
                if try await transitionToOnboardingIfFamilyDeleted(
                    lock: lock,
                    participant: participant,
                    expectedSession: expectedSession,
                    expectedAccountGeneration: accountGeneration
                ) {
                    requiresMembershipRecovery = false
                    return
                }
                if hasExactOwnerClaim {
                    guard try await clearReleasedOwnerMembershipRouting(
                        lock: lock,
                        participant: participant,
                        expectedSession: expectedSession,
                        expectedAccountGeneration: accountGeneration
                    ) else { throw HouseholdError.accountMembershipConflict }
                    syncMessage = "Ready to create or join a family"
                }
                requiresMembershipRecovery = false
                return
            }
            requiresMembershipRecovery = true
            var location: CloudLocation?
            if lock.state == .provisional {
                guard lock.claimBinding == nil else {
                    throw HouseholdError.accountMembershipConflict
                }
                if try await transport.releaseAccountMembershipLock(
                    expectedLock: lock,
                    expectedParticipantID: participant,
                    reason: .expiredProvisional,
                    clientTime: clock(),
                    expectedAccountGeneration: accountGeneration
                ) {
                    guard try await transport.participantID() == participant,
                          transport.accountGeneration == accountGeneration,
                          session == expectedSession else { throw HouseholdError.wrongAccount }
                    requiresMembershipRecovery = false
                    syncMessage = "Ready to create or join a family"
                    return
                }
                location = try await transport.membershipLocation(householdID: lock.householdID)
                if location == nil {
                    try await validateRecovery(deviceID: deviceID, participant: participant, lock: lock)
                }
            } else {
                location = try await transport.membershipLocation(householdID: lock.householdID)
            }
            guard let location else {
                let hasExactOwnerClaim = lock.state == .active
                    && lock.claimBinding == AccountMembershipBinding.owner(householdID: lock.householdID)
                if hasExactOwnerClaim {
                    guard let ownerAuthorityBinding = exactOwnerAuthorityBinding(
                        for: lock,
                        participant: participant
                    ) else { throw HouseholdError.accountMembershipConflict }
                    let lifecycleState: FamilyLifecycleState?
                    do {
                        lifecycleState = try await transport.familyLifecycleState(
                            householdID: lock.householdID,
                            ownerAuthorityBinding: ownerAuthorityBinding,
                            expectedParticipantID: participant
                        )
                    } catch HouseholdError.accountMembershipConflict {
                        throw HouseholdError.accountMembershipConflict
                    } catch HouseholdError.wrongAccount {
                        throw HouseholdError.wrongAccount
                    } catch {
                        try await validateRecovery(
                            deviceID: deviceID,
                            participant: participant,
                            accountGeneration: accountGeneration,
                            lock: lock
                        )
                        staleOwnerMembershipReleaseCandidate = .init(
                            lock: lock,
                            participantID: participant,
                            accountGeneration: accountGeneration
                        )
                        canReleaseStaleOwnerMembership = true
                        throw error
                    }
                    if lifecycleState == .deleted {
                        if try await transitionToOnboardingIfFamilyDeleted(
                            lock: lock,
                            participant: participant,
                            expectedSession: expectedSession,
                            expectedAccountGeneration: accountGeneration
                        ) {
                            requiresMembershipRecovery = false
                            return
                        }
                        throw HouseholdError.accountMembershipConflict
                    }
                    try await validateRecovery(
                        deviceID: deviceID,
                        participant: participant,
                        accountGeneration: accountGeneration,
                        lock: lock
                    )
                    staleOwnerMembershipReleaseCandidate = .init(
                        lock: lock,
                        participantID: participant,
                        accountGeneration: accountGeneration
                    )
                    canReleaseStaleOwnerMembership = true
                    throw HouseholdError.ownerMembershipUnavailable
                }
                if try await transitionToOnboardingIfFamilyDeleted(
                    lock: lock,
                    participant: participant,
                    expectedSession: expectedSession,
                    expectedAccountGeneration: accountGeneration
                ) {
                    requiresMembershipRecovery = false
                    return
                }
                throw HouseholdError.invitationUnavailable
            }
            if location.isOwner {
                let lifecycleState = try await transport.ensureFamilyLifecycleAuthority(
                    householdID: location.householdID,
                    expectedParticipantID: participant
                )
                guard lifecycleState == .active else { throw HouseholdError.accountMembershipConflict }
            }
            let remote = try await transport.fetch(from: location)
            try validate(remote, householdID: lock.householdID)
            let imported = HouseholdSnapshot(facts: remote)
            guard imported.household?.id == lock.householdID else { throw HouseholdError.familyStillSyncing }
            if !location.isOwner { try validateCompleteFamily(imported, householdID: lock.householdID) }
            let membership = try imported.committedAccountMembership(participantID: participant)
            let binding = try membershipBinding(in: imported, location: location, participant: participant)
            if lock.state == .active {
                guard let binding, binding == lock.claimBinding else { throw HouseholdError.accountMembershipConflict }
            } else {
                guard lock.claimBinding == nil else { throw HouseholdError.accountMembershipConflict }
            }
            let canWrite = try await transport.canWrite(to: location)
            try await validateRecovery(deviceID: deviceID, participant: participant, lock: lock)
            if let membership {
                guard !location.isOwner else { throw HouseholdError.accountMembershipConflict }
                let validationTime = try await transport.accountMembershipValidationTime(clientTime: clock())
                guard let household = imported.household,
                      imported.isActive(membership.member, on: CivilDay(validationTime, calendar: household.calendar)) else {
                    throw HouseholdError.invitationUnavailable
                }
                try await validateRecovery(deviceID: deviceID, participant: participant, lock: lock)
                let active = try await transport.activateAccountMembershipLock(
                    householdID: lock.householdID, attemptID: lock.attemptID,
                    claimBinding: AccountMembershipBinding.invitation(membership),
                    ownerAuthorityBinding: ownerAuthorityBinding(for: location, participant: participant),
                    now: clock()
                )
                guard try await transport.participantID() == participant,
                      session.deviceID == deviceID, session.householdID == nil else { throw HouseholdError.wrongAccount }
                try attach(remote: remote, location: location, participant: participant,
                           membership: membership, cloudCanWrite: canWrite, accountLockAttemptID: active.attemptID)
            } else if location.isOwner || binding != nil {
                let member: FamilyMember
                if location.isOwner {
                    guard let owner = ownerRecoveryMember(in: imported) else { throw HouseholdError.accountMembershipConflict }
                    member = owner
                } else {
                    // A legacy account grant may lack the lost installation's selected identity.
                    // Recover only a single exact profile; multiple choices cannot confer authority.
                    let validationTime = try await transport.accountMembershipValidationTime(clientTime: clock())
                    guard let exact = legacyRecoveryMember(in: imported, participant: participant, now: validationTime) else {
                        throw HouseholdError.accountMembershipConflict
                    }
                    try await validateRecovery(deviceID: deviceID, participant: participant, lock: lock)
                    member = exact
                }
                guard let binding else { throw HouseholdError.accountMembershipConflict }
                let active = try await transport.activateAccountMembershipLock(
                    householdID: lock.householdID, attemptID: lock.attemptID, claimBinding: binding,
                    ownerAuthorityBinding: ownerAuthorityBinding(for: location, participant: participant),
                    now: clock()
                )
                guard try await transport.participantID() == participant,
                      session.deviceID == deviceID, session.householdID == nil else { throw HouseholdError.wrongAccount }
                var updated = session
                updated.householdID = lock.householdID
                updated.location = location
                updated.cloudParticipantID = participant
                updated.selectedMemberID = member.id
                updated.cloudCanWrite = canWrite
                updated.legacyProfileIDs = [member.id]
                updated.accountMembershipLockAttemptID = active.attemptID
                updated.accountMembershipClaimBinding = binding
                try repository.commit(facts: remote, session: updated, uploaded: true)
                session = updated
                cloudIsReadOnly = !canWrite
                try reload()
            } else {
                // Apple acceptance supplies transport access only. Retain the original provisional
                // attempt and require the exact unclaimed invitation before granting any profile.
                guard lock.state == .provisional else { throw HouseholdError.accountMembershipConflict }
                let invitation = try await matchedPendingInvitation(in: imported, location: location)
                let validationTime = try await transport.invitationValidationTime(in: location, clientTime: clock())
                guard imported.invitationStatus(invitation, now: validationTime) == .available,
                      validationTime < lock.expiresAt else { throw HouseholdError.invitationUnavailable }
                try await validateRecovery(deviceID: deviceID, participant: participant, lock: lock)
                try beginPendingInvitationAcceptance(location: location, participant: participant,
                                                     accessExistedBeforeAttempt: true, attemptID: lock.attemptID)
                try confirmPendingInvitationAcceptance(location: location, participant: participant)
                var pending = try requirePendingInvitation(location: location)
                pending.invitationID = invitation.id
                pending.expiresAt = invitation.expiresAt
                try persistPendingInvitation(pending)
                try await importFamily(location, participant: participant, accountLockAttemptID: lock.attemptID)
            }
            requiresMembershipRecovery = false
            syncMessage = "Family reconnected"
        } catch {
            requiresMembershipRecovery = true
            throw error
        }
    }

    func releaseStaleOwnerMembership() async throws {
        guard canReleaseStaleOwnerMembership, requiresMembershipRecovery,
              session.householdID == nil, session.pendingInvitationAcceptance == nil,
              let candidate = staleOwnerMembershipReleaseCandidate,
              let transport else { throw HouseholdError.accountMembershipConflict }
        canReleaseStaleOwnerMembership = false
        staleOwnerMembershipReleaseCandidate = nil
        let expectedSession = session
        let participant = try await transport.participantID()
        guard participant == candidate.participantID,
              transport.accountGeneration == candidate.accountGeneration else { throw HouseholdError.wrongAccount }
        guard let lock = try await transport.accountMembershipLock(),
              lock == candidate.lock,
              exactOwnerAuthorityBinding(for: lock, participant: participant) != nil,
              try await transport.membershipLocation(householdID: lock.householdID) == nil else {
            throw HouseholdError.accountMembershipConflict
        }
        try await validateRecovery(
            deviceID: expectedSession.deviceID,
            participant: participant,
            accountGeneration: candidate.accountGeneration,
            lock: lock
        )
        guard transport.accountGeneration == candidate.accountGeneration else { throw HouseholdError.wrongAccount }
        guard try await transport.releaseAccountMembershipLock(
            expectedLock: lock,
            expectedParticipantID: participant,
            reason: .ownerSelfRelease,
            clientTime: clock(),
            expectedAccountGeneration: candidate.accountGeneration
        ) else { throw HouseholdError.accountMembershipConflict }
        guard try await transport.participantID() == participant,
              transport.accountGeneration == candidate.accountGeneration,
              session == expectedSession else { throw HouseholdError.wrongAccount }
        try persistSessionByClearingMembershipRouting(expectedSession)
        requiresMembershipRecovery = false
        errorMessage = nil
        syncMessage = "Ready to create or join a family"
    }

    private func clearReleasedOwnerMembershipRouting(
        lock: AccountMembershipLock,
        participant: String,
        expectedSession: DeviceSession,
        expectedAccountGeneration: UInt64
    ) async throws -> Bool {
        guard let transport,
              transport.accountGeneration == expectedAccountGeneration,
              lock.state == .released,
              lock.claimBinding == AccountMembershipBinding.owner(householdID: lock.householdID),
              exactOwnerAuthorityBinding(for: lock, participant: participant) != nil,
              expectedSession.cloudParticipantID == nil || expectedSession.cloudParticipantID == participant,
              expectedSession.accountMembershipLockAttemptID == nil
                || expectedSession.accountMembershipLockAttemptID == lock.attemptID,
              expectedSession.accountMembershipClaimBinding == nil
                || expectedSession.accountMembershipClaimBinding == lock.claimBinding,
              expectedSession.location == nil || expectedSession.location?.householdID == lock.householdID else {
            return false
        }
        guard try await transport.membershipLocation(householdID: lock.householdID) == nil,
              transport.accountGeneration == expectedAccountGeneration else { return false }
        guard try await transport.accountMembershipLock() == lock,
              transport.accountGeneration == expectedAccountGeneration else { return false }
        guard try await transport.participantID() == participant,
              transport.accountGeneration == expectedAccountGeneration,
              session == expectedSession else { return false }
        try persistSessionByClearingMembershipRouting(expectedSession)
        return true
    }

    private func persistSessionByClearingMembershipRouting(_ expectedSession: DeviceSession) throws {
        var releasedSession = expectedSession
        releasedSession.cloudParticipantID = nil
        releasedSession.location = nil
        releasedSession.cloudCanWrite = nil
        releasedSession.accountMembershipLockAttemptID = nil
        releasedSession.accountMembershipClaimBinding = nil
        guard releasedSession != expectedSession else { return }
        try repository.commit(facts: [], session: releasedSession)
        session = releasedSession
    }

    private func legacyRecoveryMember(in imported: HouseholdSnapshot, participant: String, now: Date) -> FamilyMember? {
        let ids = Set(imported.grants.filter { $0.cloudParticipantID == participant }.flatMap(\.memberIDs))
        guard ids.count == 1, let id = ids.first, let member = imported.member(id),
              let household = imported.household,
              imported.isActive(member, on: CivilDay(now, calendar: household.calendar)) else { return nil }
        return member
    }

    private func recoveryMembershipLock(participant: String) async throws -> AccountMembershipLock? {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        if let existing = try await transport.accountMembershipLock() { return existing }
        // Older installations may have journal authority without a private account lock.
        // Inspect all accessible candidates before reserving anything or choosing a profile.
        var candidates: [(CloudLocation, String)] = []
        for family in try await transport.discoverFamilies() {
            let remote = try await transport.fetch(from: family.location)
            try validate(remote, householdID: family.location.householdID)
            let imported = HouseholdSnapshot(facts: remote)
            if !family.location.isOwner,
               imported.invitationClaims.contains(where: { $0.cloudParticipantID == participant }),
               try imported.committedAccountMembership(participantID: participant) == nil {
                continue
            }
            guard let binding = try membershipBinding(in: imported, location: family.location,
                                                      participant: participant) else { continue }
            if family.location.isOwner {
                guard ownerRecoveryMember(in: imported) != nil else { throw HouseholdError.accountMembershipConflict }
            } else if try imported.committedAccountMembership(participantID: participant) == nil {
                let validationTime = try await transport.accountMembershipValidationTime(clientTime: clock())
                guard legacyRecoveryMember(in: imported, participant: participant, now: validationTime) != nil else {
                    throw HouseholdError.accountMembershipConflict
                }
            }
            candidates.append((family.location, binding))
        }
        guard candidates.count <= 1 else { throw HouseholdError.accountMembershipConflict }
        guard let candidate = candidates.first else { return nil }
        requiresMembershipRecovery = true
        guard try await transport.participantID() == participant else { throw HouseholdError.wrongAccount }
        let attemptID = UUID()
        let lock = try await transport.acquireAccountMembershipLock(
            householdID: candidate.0.householdID, attemptID: attemptID,
            leaseDuration: InvitationCode.lifetime, clientTime: clock()
        )
        guard lock.householdID == candidate.0.householdID,
              (lock.state == .provisional && lock.attemptID == attemptID)
                || (lock.state == .active && lock.claimBinding == candidate.1) else {
            throw HouseholdError.accountMembershipConflict
        }
        return lock
    }

    private func validateRecovery(
        deviceID: UUID,
        participant: String,
        accountGeneration: UInt64? = nil,
        lock: AccountMembershipLock
    ) async throws {
        guard let transport, session.deviceID == deviceID, session.householdID == nil,
              session.pendingInvitationAcceptance == nil,
              try await transport.participantID() == participant,
              accountGeneration == nil || transport.accountGeneration == accountGeneration else {
            throw HouseholdError.wrongAccount
        }
        guard try await transport.accountMembershipLock() == lock else { throw HouseholdError.accountMembershipConflict }
        guard accountGeneration == nil || transport.accountGeneration == accountGeneration else {
            throw HouseholdError.wrongAccount
        }
    }

    private func reconcileAccountMembershipLock(imported: HouseholdSnapshot, location: CloudLocation,
                                                participant: String,
                                                expectedAccountGeneration: UInt64) async throws {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        guard transport.accountGeneration == expectedAccountGeneration,
              try await transport.participantID() == participant,
              transport.accountGeneration == expectedAccountGeneration else { throw HouseholdError.wrongAccount }
        if location.isOwner {
            let lifecycleState = try await transport.ensureFamilyLifecycleAuthority(
                householdID: location.householdID,
                expectedParticipantID: participant
            )
            guard lifecycleState == .active else { throw HouseholdError.accountMembershipConflict }
        }
        do {
            guard transport.accountGeneration == expectedAccountGeneration else { throw HouseholdError.wrongAccount }
            let currentLock = try await transport.accountMembershipLock()
            guard transport.accountGeneration == expectedAccountGeneration else { throw HouseholdError.wrongAccount }
            guard let binding = try membershipBinding(
                in: imported,
                location: location,
                participant: participant
            ) else {
                try validateRetainedMembershipAttempt(currentLock, location: location)
                return
            }
            if let localBinding = session.accountMembershipClaimBinding, localBinding != binding {
                throw HouseholdError.accountMembershipConflict
            }
            if let currentLock {
                if canReuseActiveOwnerMembership(
                    currentLock,
                    binding: binding,
                    imported: imported,
                    location: location,
                    participant: participant
                ) {
                    let active = try await transport.activateAccountMembershipLock(
                        householdID: location.householdID,
                        attemptID: currentLock.attemptID,
                        claimBinding: binding,
                        ownerAuthorityBinding: ownerAuthorityBinding(for: location, participant: participant),
                        now: clock()
                    )
                    guard transport.accountGeneration == expectedAccountGeneration,
                          try await transport.participantID() == participant,
                          transport.accountGeneration == expectedAccountGeneration,
                          session.householdID == location.householdID,
                          session.location == location,
                          session.cloudParticipantID == participant else {
                        throw HouseholdError.wrongAccount
                    }
                    guard active == currentLock else { throw HouseholdError.accountMembershipConflict }
                    if session.accountMembershipLockAttemptID != active.attemptID
                        || session.accountMembershipClaimBinding != binding {
                        var updated = session
                        updated.accountMembershipLockAttemptID = active.attemptID
                        updated.accountMembershipClaimBinding = binding
                        try repository.commit(facts: [], session: updated)
                        session = updated
                    }
                    return
                }
                try validateRetainedMembershipAttempt(currentLock, location: location)
            }
            let lock = try await acquireAccountMembershipLock(
                householdID: location.householdID,
                attemptID: session.accountMembershipLockAttemptID,
                matching: binding
            )
            let active = try await transport.activateAccountMembershipLock(
                householdID: location.householdID,
                attemptID: lock.attemptID,
                claimBinding: binding,
                ownerAuthorityBinding: ownerAuthorityBinding(for: location, participant: participant),
                now: clock()
            )
            if session.accountMembershipLockAttemptID != active.attemptID
                || session.accountMembershipClaimBinding != binding {
                var updated = session
                updated.accountMembershipLockAttemptID = active.attemptID
                updated.accountMembershipClaimBinding = binding
                try repository.commit(facts: [], session: updated)
                session = updated
            }
        } catch HouseholdError.accountMembershipConflict {
            var updated = session
            updated.cloudCanWrite = false
            try repository.commit(facts: [], session: updated)
            session = updated
            cloudIsReadOnly = true
            throw HouseholdError.accountMembershipConflict
        }
    }

    private func validateRetainedMembershipAttempt(
        _ lock: AccountMembershipLock?,
        location: CloudLocation
    ) throws {
        guard let lock else { return }
        guard let localAttemptID = session.accountMembershipLockAttemptID else {
            throw HouseholdError.accountMembershipConflict
        }
        guard lock.householdID == location.householdID,
              lock.attemptID == localAttemptID,
              lock.state != .released else {
            throw HouseholdError.accountMembershipConflict
        }
    }

    private func canReuseActiveOwnerMembership(
        _ lock: AccountMembershipLock,
        binding: String,
        imported: HouseholdSnapshot,
        location: CloudLocation,
        participant: String
    ) -> Bool {
        guard location.isOwner,
              session.householdID == location.householdID,
              session.location == location,
              session.cloudParticipantID == participant,
              let parent = selectedMember,
              parent.role == .parent,
              imported.member(parent.id)?.role == .parent,
              binding == AccountMembershipBinding.owner(householdID: location.householdID),
              lock.householdID == location.householdID,
              lock.state == .active,
              lock.claimBinding == binding,
              lock.ownerAuthorityBinding == AccountMembershipBinding.ownerAuthority(participantID: participant) else {
            return false
        }
        return true
    }

    private func accessibleFacts(at location: CloudLocation) async throws -> [HouseholdFact]? {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        do { return try await transport.fetch(from: location) }
        catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound
            || error.code == .permissionFailure {
            return nil
        }
    }

    private func resumeAccountMembership(participant: String, requestedLocation: CloudLocation?,
                                         invitationCodeDigest: String?) async throws -> Bool {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        var located: [(CloudLocation, [HouseholdFact], AccountFamilyMembership)] = []
        for family in try await transport.discoverFamilies() {
            if let requestedLocation, family.location != requestedLocation { continue }
            let remote = try await transport.fetch(from: family.location)
            try validate(remote, householdID: family.location.householdID)
            let imported = HouseholdSnapshot(facts: remote)
            try validateCompleteFamily(imported, householdID: family.location.householdID)
            if let membership = try imported.committedAccountMembership(participantID: participant) {
                located.append((family.location, remote, membership))
            }
        }
        guard located.count <= 1 else { throw HouseholdError.accountMembershipConflict }
        guard let existing = located.first else { return false }
        let codeMatches = invitationCodeDigest.map { $0 == existing.2.claim.codeDigest } ?? true
        guard requestedLocation == nil || requestedLocation == existing.0, codeMatches else {
            throw HouseholdError.accountMembershipConflict
        }
        let canWrite = try await transport.canWrite(to: existing.0)
        guard canWrite else { throw HouseholdError.readOnly }
        let lock = try await activateAccountMembershipLock(
            location: existing.0, claimBinding: AccountMembershipBinding.invitation(existing.2)
        )
        try attach(remote: existing.1, location: existing.0, participant: participant,
                   membership: existing.2, cloudCanWrite: canWrite,
                   accountLockAttemptID: lock.attemptID)
        return true
    }

    private func pruneUnavailableInvitationAccess() async throws {
        guard let transport, let location = session.location, location.isOwner else { return }
        let validationTime = try await transport.invitationValidationTime(in: location, clientTime: clock())
        for invitation in snapshot.invitations where snapshot.invitationClaim(invitation.id) == nil
            && (snapshot.isInvitationRevoked(invitation.id) || validationTime >= invitation.expiresAt) {
            try await transport.revokeInvitationAccess(participantID: invitation.cloudShareParticipantID,
                                                       from: location)
        }
    }

    private func validateCompleteFamily(_ imported: HouseholdSnapshot, householdID: UUID) throws {
        guard imported.household?.id == householdID else { throw HouseholdError.invitation }
        guard imported.household?.isSetupComplete == true,
              imported.members.contains(where: { $0.role == .parent }),
              imported.members.contains(where: { $0.role == .child }),
              imported.revisions.allSatisfy({ revision in revision.memberIDs.allSatisfy { imported.member($0) != nil } }),
              imported.completions.allSatisfy({ contribution in
                  imported.member(contribution.memberID) != nil && imported.revisions.contains { $0.id == contribution.revisionID }
              }) else { throw HouseholdError.familyStillSyncing }
    }

    func synchronize() async throws {
        if let activeSync { return try await activeSync.value }
        let task = Task { try await performSynchronization() }
        activeSync = task
        defer { activeSync = nil }
        try await task.value
    }

    private func performSynchronization() async throws {
        guard let location = session.location else { return }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let expectedSession = session
        isSyncing = true
        syncMessage = "Syncing…"
        defer {
            isSyncing = false
            if syncAgain { syncAgain = false; scheduleSync() }
        }
        do {
            guard session.pendingFamilyDeletion != true else { throw HouseholdError.permission }
            let accountGeneration = transport.accountGeneration
            let participant = try await transport.participantID()
            guard participant == session.cloudParticipantID,
                  transport.accountGeneration == accountGeneration else { throw HouseholdError.wrongAccount }
            let remote = try await transport.fetch(from: location)
            try validate(remote, householdID: location.householdID)
            let remoteSnapshot = HouseholdSnapshot(facts: remote)
            try await reconcileAccountMembershipLock(imported: remoteSnapshot, location: location,
                                                      participant: participant,
                                                      expectedAccountGeneration: accountGeneration)
            cloudIsReadOnly = try await !transport.canWrite(to: location)
            var updated = session
            updated.cloudCanWrite = !cloudIsReadOnly
            updated.familyAccessLost = false
            try repository.commit(facts: remote, session: updated, uploaded: true)
            session = updated
            try reload()
            cloudAccessBlocked = false
            today = clock()
            let candidates = try repository.pending(householdID: location.householdID, includingRejected: true)
            var reasons: [UUID: String] = [:]
            var pending = candidates.filter { fact in
                do { try authorizePending([fact]); return true }
                catch { reasons[fact.id] = error.localizedDescription; return false }
            }
            while true {
                let available = HouseholdSnapshot(facts: remote + pending)
                let retained = pending.filter { fact in
                    guard hasUploadReferences(fact, in: available) else {
                        reasons[fact.id] = "Referenced family data is not shared yet. Ask a parent to review the retained changes, then refresh."
                        return false
                    }
                    return true
                }
                if retained.count == pending.count { break }
                pending = retained
            }
            try repository.setRejections(reasons, householdID: location.householdID)
            rejectedChanges = reasons
            if !pending.isEmpty {
                guard !cloudIsReadOnly else { throw HouseholdError.readOnly }
                try await transport.upload(pending, to: location)
                try repository.commit(facts: pending, uploaded: true)
            }
            lastSyncedAt = clock()
            syncMessage = "Up to date"
        } catch {
            var familyDeletionHandled = false
            var familyAccessLost = false
            if let cloudError = error as? CKError {
                cloudAccessBlocked = [.notAuthenticated, .permissionFailure, .zoneNotFound, .userDeletedZone].contains(cloudError.code)
                familyAccessLost = [.permissionFailure, .zoneNotFound, .userDeletedZone].contains(cloudError.code)
                if [.permissionFailure, .zoneNotFound, .userDeletedZone].contains(cloudError.code),
                   let attemptID = session.accountMembershipLockAttemptID,
                   let expectedParticipantID = session.cloudParticipantID {
                    do {
                        let accountGeneration = transport.accountGeneration
                        if try await transport.participantID() == expectedParticipantID,
                           transport.accountGeneration == accountGeneration,
                           let lock = try await transport.accountMembershipLock(),
                           lock.householdID == location.householdID,
                           lock.attemptID == attemptID {
                            familyDeletionHandled = try await transitionToOnboardingIfFamilyDeleted(
                                lock: lock,
                                location: location,
                                participant: expectedParticipantID,
                                expectedSession: expectedSession,
                                expectedAccountGeneration: accountGeneration
                            )
                        }
                    } catch {
                        familyDeletionHandled = false
                    }
                }
            } else {
                cloudAccessBlocked = error as? HouseholdError == .wrongAccount || error as? HouseholdError == .malformedData
            }
            if familyDeletionHandled { return }
            if cloudAccessBlocked {
                var updated = session
                updated.cloudCanWrite = false
                if familyAccessLost { updated.familyAccessLost = true }
                try? repository.commit(facts: [], session: updated)
                session = updated
                cloudIsReadOnly = true
            }
            syncMessage = "Sync needs attention. Changes are kept."
            throw error
        }
    }

    func scheduleSync() {
        guard automaticSync, session.location != nil else { return }
        if isSyncing { syncAgain = true; return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self else { return }
            do { try await self.synchronize() } catch { self.errorMessage = error.localizedDescription }
        }
    }

    func resetLocalData() throws {
        today = clock()
        guard !isSyncing else { throw HouseholdError.pendingChanges }
        guard session.pendingFamilyDeletion != true else { throw HouseholdError.pendingChanges }
        if !profiles.isEmpty { try PermissionService.requireParent(selectedMember) }
        if session.location != nil && pendingCount > 0 { throw HouseholdError.pendingChanges }
        syncTask?.cancel()
        try repository.clearLocalData(retainingRejected: session.location != nil)
        session = try repository.session()
        facts = []
        rejectedChanges = [:]
        snapshot = HouseholdSnapshot()
        syncMessage = "On this device"
        cloudAccessBlocked = false
        cloudIsReadOnly = false
        isCheckingAccountMembership = transport != nil
        requiresMembershipRecovery = false
    }

    func dismissFamilyDeletionNotice() throws {
        guard session.familyDeletionNoticeState == .pending else { return }
        var updated = session
        updated.familyDeletionNoticeState = .acknowledged
        try repository.commit(facts: [], session: updated)
        session = updated
    }

    func deleteFamily() async throws {
        guard !isSyncing else { throw HouseholdError.pendingChanges }
        guard let actor = selectedMember, actor.role == .parent,
              actor.id == snapshot.creatorMemberID,
              let location = session.location, location.isOwner,
              let participant = session.cloudParticipantID,
              let attemptID = session.accountMembershipLockAttemptID,
              let transport else { throw HouseholdError.permission }
        let deviceID = session.deviceID
        let householdID = location.householdID
        func requireDeletionSession(pending: Bool? = nil) throws {
            guard session.deviceID == deviceID,
                  session.householdID == householdID,
                  session.location == location,
                  session.cloudParticipantID == participant,
                  session.accountMembershipLockAttemptID == attemptID,
                  pending.map({ session.pendingFamilyDeletion == $0 }) ?? true else {
                throw HouseholdError.permission
            }
        }
        guard try await transport.participantID() == participant else { throw HouseholdError.wrongAccount }
        try requireDeletionSession()

        if session.pendingFamilyDeletion != true {
            var updated = session
            updated.pendingFamilyDeletion = true
            try repository.commit(facts: [], session: updated)
            session = updated
        }

        _ = try await transport.ensureFamilyLifecycleAuthority(
            householdID: householdID,
            expectedParticipantID: participant
        )
        try requireDeletionSession(pending: true)
        try await transport.beginFamilyDeletion(
            householdID: householdID,
            expectedParticipantID: participant
        )
        try requireDeletionSession(pending: true)
        // The durable owner intent is irreversible before the zone and share are removed.
        // Local state remains available so every incomplete phase can resume idempotently.
        try await transport.deleteFamilyData(at: location, expectedParticipantID: participant)
        try requireDeletionSession(pending: true)
        try await transport.finalizeFamilyDeletion(
            householdID: householdID,
            expectedParticipantID: participant
        )
        try requireDeletionSession(pending: true)
        guard try await transport.releaseAccountMembershipLock(
            householdID: location.householdID, attemptID: attemptID,
            expectedParticipantID: participant, now: clock()
        ) else { throw HouseholdError.cloudUnavailable }
        try requireDeletionSession(pending: true)
        syncTask?.cancel()
        try requireDeletionSession(pending: true)
        try purgeDeletedFamily(householdID: householdID)
    }

    func removeUnavailableFamilyFromDevice() throws {
        guard canRemoveUnavailableFamilyFromDevice else { throw HouseholdError.cloudUnavailable }
        syncTask?.cancel()
        try repository.clearLocalData()
        try resetAfterLocalRemoval()
    }

    private func resetAfterLocalRemoval() throws {
        session = try repository.session()
        facts = []
        rejectedChanges = [:]
        snapshot = HouseholdSnapshot()
        syncMessage = "On this device"
        cloudAccessBlocked = false
        cloudIsReadOnly = false
        isCheckingAccountMembership = transport != nil
        requiresMembershipRecovery = false
    }

    private func purgeDeletedFamily(householdID: UUID) throws {
        guard session.householdID == nil || session.householdID == householdID else {
            throw HouseholdError.accountMembershipConflict
        }
        let showNotice = session.householdID == householdID
            || session.familyDeletionNoticeState != .acknowledged
        var replacement = DeviceSession()
        replacement.deviceID = session.deviceID
        replacement.familyDeletionNoticeState = showNotice ? .pending : .acknowledged
        syncTask?.cancel()
        try repository.purgeHouseholdData(householdID: householdID, replacementSession: replacement)
        session = replacement
        facts = []
        rejectedChanges = [:]
        snapshot = HouseholdSnapshot()
        syncMessage = "On this device"
        lastSyncedAt = nil
        cloudAccessBlocked = false
        cloudIsReadOnly = false
        isCheckingAccountMembership = false
        requiresMembershipRecovery = false
    }

    private func requireWriteAccess() throws {
        today = clock()
        if cloudAccessBlocked { throw HouseholdError.cloudUnavailable }
        if cloudIsReadOnly { throw HouseholdError.readOnly }
    }

    private func requireParent() throws {
        try requireWriteAccess()
        try PermissionService.requireParent(selectedMember)
    }

    private func append(_ body: HouseholdFactBody) throws {
        try append([body])
    }

    private func append(_ bodies: [HouseholdFactBody]) throws {
        guard let householdID = session.householdID else { throw HouseholdError.noHousehold }
        let previousSequence = facts.map(\.sequence).max() ?? 0
        guard bodies.count <= Int64.max - previousSequence else { throw HouseholdError.malformedData }
        let actorID = selectedMember?.id
        let appended = bodies.enumerated().map { index, body in
            HouseholdFact(id: UUID(), householdID: householdID, sequence: previousSequence + Int64(index) + 1,
                          authorDeviceID: session.deviceID, authorMemberID: actorID, body: body)
        }
        try repository.commit(facts: appended)
        try reload()
        scheduleSync()
    }

    private func reload() throws {
        facts = try session.householdID.map { try repository.facts(householdID: $0) } ?? []
        snapshot = HouseholdSnapshot(facts: facts)
        rejectedChanges = try session.householdID.map { try repository.rejections(householdID: $0) } ?? [:]
    }

    private func migrateLegacyProfileAccess() throws {
        guard household != nil, session.legacyProfileIDs == nil else { return }
        var updated = session
        if household?.creatorDeviceID != session.deviceID, session.location?.isOwner == true,
           let selected = session.selectedMemberID, snapshot.member(selected) != nil {
            updated.legacyProfileIDs = [selected]
        } else {
            updated.legacyProfileIDs = []
        }
        try repository.commit(facts: [], session: updated)
        session = updated
    }

    private func authorizePending(_ pending: [HouseholdFact]) throws {
        let approvedIDs = Set(profiles.map(\.id))
        for fact in pending {
            if case .request(let request) = fact.body {
                guard request.deviceID == session.deviceID, request.cloudParticipantID == session.cloudParticipantID else {
                    throw HouseholdError.permission
                }
                continue
            }
            if case .invitationClaim(let claim) = fact.body {
                guard claim.deviceID == session.deviceID,
                      claim.cloudParticipantID == session.cloudParticipantID else { throw HouseholdError.permission }
                continue
            }
            guard let memberID = fact.authorMemberID, approvedIDs.contains(memberID),
                  let author = snapshot.member(memberID) else { throw HouseholdError.missingProfile }
            switch fact.body {
            case .completion(let completion):
                guard author.role == .parent || completion.memberID == author.id else { throw HouseholdError.permission }
            default: try PermissionService.requireParent(author)
            }
        }
    }

    private func hasUploadReferences(_ fact: HouseholdFact, in available: HouseholdSnapshot) -> Bool {
        guard available.household?.id == fact.householdID else { return false }
        if let author = fact.authorMemberID, available.member(author) == nil { return false }
        func hasMembers(_ ids: [UUID]) -> Bool { ids.allSatisfy { available.member($0) != nil } }
        switch fact.body {
        case .household, .member: return true
        case .chore(let value): return hasMembers(value.memberIDs)
        case .choreDeletion(let value):
            return hasMembers([value.recordedByMemberID] + (value.eligibleMemberIDs ?? [])
                + [value.turnOwnerID].compactMap { $0 }
                + (value.resolvedExcusedMemberIDs ?? [])
                + (value.resolvedContributions ?? []).flatMap {
                    $0.eligibleMemberIDs + [$0.memberID, $0.recordedByMemberID]
                })
                && available.revisions.contains {
                    $0.choreID == value.choreID && (value.revisionID == nil || $0.id == value.revisionID)
                }
        case .completion(let value):
            return hasMembers(value.eligibleMemberIDs + [value.memberID, value.recordedByMemberID])
                && available.revisions.contains { $0.id == value.revisionID && $0.choreID == value.choreID }
        case .occurrence(let value):
            return hasMembers([value.recordedByMemberID])
                && available.revisions.contains { $0.id == value.revisionID && $0.choreID == value.choreID }
        case .alternatingTurnAdvance(let value):
            return hasMembers([value.expectedMemberID, value.recordedByMemberID])
                && available.revisions.contains { $0.id == value.revisionID && $0.choreID == value.choreID }
        case .allowance(let value): return available.member(value.memberID)?.role == .child
        case .excuse(let value): return hasMembers([value.memberID])
        case .request(let value): return hasMembers(value.memberIDs)
        case .grant(let value):
            return hasMembers(value.memberIDs + [value.approvedBy])
                && available.requests.contains { $0.id == value.requestID }
        case .invitation(let value): return hasMembers([value.memberID, value.createdByMemberID])
        case .invitationClaim(let value):
            return hasMembers([value.memberID]) && available.invitation(value.invitationID) != nil
        case .invitationRevocation(let value):
            return hasMembers([value.revokedByMemberID]) && available.invitation(value.invitationID) != nil
        }
    }

    private func validatedName(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 50 else { throw HouseholdError.invalidName }
        return value
    }

    private func validate(_ facts: [HouseholdFact], householdID: UUID) throws {
        guard Set(facts.map(\.id)).count == facts.count,
              facts.allSatisfy({ $0.householdID == householdID && $0.sequence > 0 }) else {
            throw HouseholdError.malformedData
        }
        for fact in facts {
            switch fact.body {
            case .household(let value):
                guard value.id == householdID, TimeZone(identifier: value.timeZoneID) != nil else { throw HouseholdError.malformedData }
            case .allowance(let value):
                guard value.amount?.isValid != false,
                      CivilDay(AppCalendar.weekStart(containing: value.effectiveWeek.date(in: AppCalendar.current)),
                               calendar: AppCalendar.current) == value.effectiveWeek else { throw HouseholdError.malformedData }
            case .member(let value):
                guard value.householdID == householdID else { throw HouseholdError.malformedData }
            case .chore(let value):
                guard value.householdID == householdID else { throw HouseholdError.malformedData }
            case .choreDeletion(let value):
                guard fact.authorMemberID == value.recordedByMemberID,
                      value.turnOwnerID.map({ value.eligibleMemberIDs?.contains($0) == true }) ?? true,
                      value.resolvedExcusedMemberIDs.map({
                          Set($0).isSubset(of: Set(value.eligibleMemberIDs ?? []))
                      }) ?? true,
                      value.resolvedContributions?.allSatisfy({
                          $0.choreID == value.choreID && $0.day == value.day
                              && $0.revisionID == value.revisionID && $0.state != .unmarked
                      }) ?? true,
                      value.revisionID == nil || facts.contains(where: {
                          if case .chore(let revision) = $0.body {
                              return revision.id == value.revisionID && revision.choreID == value.choreID
                          }
                          return false
                      }) else {
                    throw HouseholdError.malformedData
                }
            case .occurrence(let value):
                guard fact.authorMemberID == value.recordedByMemberID,
                      value.state == .notNeeded || value.alternatingSkipBehavior == nil,
                      value.state == .available || value.assignedMemberID == nil else {
                    throw HouseholdError.malformedData
                }
            case .alternatingTurnAdvance(let value):
                guard fact.authorMemberID == value.recordedByMemberID else {
                    throw HouseholdError.malformedData
                }
            case .invitation(let value):
                guard value.householdID == householdID, value.createdAt < value.expiresAt,
                      value.expiresAt.timeIntervalSince(value.createdAt) <= InvitationCode.lifetime,
                      value.codeDigest.count == 64, !value.cloudShareParticipantID.isEmpty,
                      value.cloudShareURLDigest == nil || value.cloudShareURLDigest?.count == 64,
                      fact.authorMemberID == value.createdByMemberID else {
                    throw HouseholdError.malformedData
                }
            case .invitationClaim(let value):
                guard fact.authorMemberID == nil, fact.authorDeviceID == value.deviceID,
                      !value.cloudParticipantID.isEmpty, value.codeDigest.count == 64 else {
                    throw HouseholdError.malformedData
                }
            case .invitationRevocation(let value):
                guard fact.authorMemberID == value.revokedByMemberID else { throw HouseholdError.malformedData }
            default: break
            }
        }
        let resolved = HouseholdSnapshot(facts: facts)
        let revisions = facts.compactMap { fact -> ChoreRevision? in
            if case .chore(let revision) = fact.body { return revision }
            return nil
        }
        let deletions = facts.compactMap { fact -> ChoreDeletion? in
            if case .choreDeletion(let deletion) = fact.body { return deletion }
            return nil
        }
        for deletion in deletions {
            guard revisions.contains(where: {
                $0.choreID == deletion.choreID && $0.effectiveDay <= deletion.day
            }), resolved.member(deletion.recordedByMemberID)?.role == .parent else {
                throw HouseholdError.malformedData
            }
        }
        for occurrence in resolved.occurrenceDispositions {
            guard let resolvedCalendar = resolved.household?.calendar else { throw HouseholdError.malformedData }
            guard let revision = resolved.revisions.first(where: {
                $0.id == occurrence.revisionID && $0.choreID == occurrence.choreID
            }), revision.effectiveDay <= occurrence.day, !revision.isArchived,
                  resolved.member(occurrence.recordedByMemberID)?.role == .parent else {
                throw HouseholdError.malformedData
            }
            switch occurrence.state {
            case .available:
                guard revision.schedulingMode == .asNeeded,
                      occurrence.alternatingSkipBehavior == nil else {
                    throw HouseholdError.malformedData
                }
                if let assigned = occurrence.assignedMemberID {
                    guard revision.mode == .alternating, revision.memberIDs.contains(assigned),
                          resolved.member(assigned)?.role == .child else {
                        throw HouseholdError.malformedData
                    }
                }
            case .notNeeded:
                guard revision.schedulingMode == .scheduled,
                      resolvedCalendar.component(.weekday, from: occurrence.day.date(in: resolvedCalendar))
                        == revision.weekday.rawValue,
                      (revision.mode == .alternating) == (occurrence.alternatingSkipBehavior != nil) else {
                    throw HouseholdError.malformedData
                }
            }
        }
        for advance in resolved.alternatingTurnAdvances {
            guard let revision = resolved.revisions.first(where: {
                $0.id == advance.revisionID && $0.choreID == advance.choreID
            }), revision.effectiveDay <= advance.day, !revision.isArchived,
                  revision.mode == .alternating, revision.schedulingMode == .asNeeded,
                  revision.memberIDs.contains(advance.expectedMemberID),
                  resolved.member(advance.recordedByMemberID)?.role == .parent else {
                throw HouseholdError.malformedData
            }
        }
        guard Set(resolved.invitations.map(\.claimFactID)).count == resolved.invitations.count else {
            throw HouseholdError.malformedData
        }
        for invitation in resolved.invitations {
            guard let member = resolved.member(invitation.memberID), member.role == invitation.role,
                  resolved.member(invitation.createdByMemberID)?.role == .parent else {
                throw HouseholdError.malformedData
            }
            if let claim = resolved.invitationClaim(invitation.id) {
                guard claim.memberID == invitation.memberID, claim.codeDigest == invitation.codeDigest,
                      facts.contains(where: { $0.id == invitation.claimFactID && $0.body == .invitationClaim(claim) }) else {
                    throw HouseholdError.malformedData
                }
            }
        }
        guard resolved.invitationClaims.allSatisfy({ resolved.invitation($0.invitationID) != nil }),
              resolved.invitationRevocations.allSatisfy({ revocation in
                  resolved.invitation(revocation.invitationID) != nil
                      && resolved.member(revocation.revokedByMemberID)?.role == .parent
              }) else { throw HouseholdError.malformedData }
    }
}

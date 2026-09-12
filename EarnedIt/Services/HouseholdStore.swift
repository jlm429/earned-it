import Foundation
import Observation
import CloudKit

@MainActor
@Observable
final class HouseholdStore {
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
    private(set) var rejectedChanges: [UUID: String] = [:]
    var errorMessage: String?
    private var syncTask: Task<Void, Never>?
    private var activeSync: Task<Void, Error>?
    private var syncAgain = false
    private var facts: [HouseholdFact] = []

    init(repository: HouseholdRepository, transport: (any HouseholdTransport)? = nil,
         clock: @escaping () -> Date = { .now }, automaticSync: Bool = true) throws {
        self.repository = repository
        self.transport = transport
        self.clock = clock
        self.automaticSync = automaticSync
        session = try repository.session()
        today = clock()
        cloudIsReadOnly = session.location != nil && session.cloudCanWrite != true
        try reload()
        try migrateLegacyProfileAccess()
    }

    var household: Household? { snapshot.household }
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
    var pendingInvitationExpiration: Date? {
        session.pendingInvitationAcceptance?.phase == .awaitingRedemption
            ? session.pendingInvitationAcceptance?.expiresAt : nil
    }

    func dailyList(on date: Date? = nil) -> [DailyChore] {
        ChoreRules.dailyList(snapshot: snapshot, day: CivilDay(date ?? today, calendar: calendar), today: day)
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
                   category: ResponsibilityCategory = .home, mode: RequirementMode, memberIDs: [UUID]) throws -> UUID {
        try requireParent()
        guard let household else { throw HouseholdError.noHousehold }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80, notes.count <= 300 else { throw HouseholdError.invalidAssignment }
        let effective = choreAssignmentDay(choreID: choreID)
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
        let orderedIDs = preservesLegacy ? memberIDs
            : orderedEligibleChildren(choreID: choreID, selectedMemberIDs: ids).map(\.id)
        let revision = ChoreRevision(id: UUID(), householdID: household.id, choreID: choreID, weekday: weekday,
                                     effectiveDay: effective, title: title, notes: notes, category: category, mode: mode,
                                     memberIDs: mode == .all ? [] : orderedIDs, isArchived: false)
        try append(.chore(revision))
        return choreID
    }

    func archiveChore(_ choreID: UUID) throws {
        try requireParent()
        guard let old = snapshot.configuration(choreID: choreID, on: tomorrow) else { throw HouseholdError.invalidAssignment }
        try append(.chore(ChoreRevision(id: UUID(), householdID: old.householdID, choreID: choreID,
                                       weekday: old.weekday, effectiveDay: tomorrow, title: old.title, notes: old.notes,
                                       category: old.category, mode: old.mode, memberIDs: old.memberIDs, isArchived: true)))
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

    private func issueInvitation(for member: FamilyMember, adding newMember: FamilyMember?) async throws
        -> IssuedFamilyInvitation {
        try requireParent()
        guard let household, member.householdID == household.id, member.role == .parent || newMember == nil else {
            throw HouseholdError.permission
        }
        if session.location?.isOwner == true {
            try await pruneUnavailableInvitationAccess()
        }
        let code = try InvitationCode.generate()
        if session.location == nil { try await connect() }
        try await synchronize()
        guard let transport, let location = session.location, let parent = selectedMember else {
            throw HouseholdError.cloudUnavailable
        }
        let now = try await transport.invitationValidationTime(in: location, clientTime: clock())
        let access = try await transport.createInvitationAccess(for: location, title: household.name, role: member.role)
        let invitation = FamilyInvitation(id: UUID(), householdID: household.id, claimFactID: UUID(),
                                          memberID: member.id, role: member.role,
                                          codeDigest: InvitationCode.digest(code)!, createdAt: now,
                                          expiresAt: now.addingTimeInterval(InvitationCode.lifetime),
                                          createdByMemberID: parent.id,
                                          cloudShareParticipantID: access.participantID)
        do {
            var bodies: [HouseholdFactBody] = []
            if let newMember { bodies.append(.member(newMember)) }
            bodies.append(.invitation(invitation))
            try append(bodies)
            try await synchronize()
            return IssuedFamilyInvitation(invitation: invitation, code: code, shareURL: access.url)
        } catch {
            try? await transport.revokeInvitationAccess(participantID: access.participantID, from: location)
            if snapshot.invitation(invitation.id) != nil {
                var cleanup: [HouseholdFactBody] = [
                    .invitationRevocation(InvitationRevocation(invitationID: invitation.id,
                                                               revokedByMemberID: parent.id))
                ]
                if var unsharedParent = newMember {
                    unsharedParent.archivedFrom = day
                    cleanup.append(.member(unsharedParent))
                }
                try? append(cleanup)
            }
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
        let participant = try await transport.participantID()
        guard session.deviceID == connectingSession.deviceID,
              session.householdID == connectingSession.householdID, session.location == nil else {
            throw HouseholdError.noHousehold
        }
        let binding = AccountMembershipBinding.owner(householdID: household.id)
        let lock = try await acquireAccountMembershipLock(householdID: household.id,
                                                          attemptID: session.accountMembershipLockAttemptID,
                                                          matching: binding)
        var provisional = session
        provisional.cloudParticipantID = participant
        provisional.accountMembershipLockAttemptID = lock.attemptID
        try repository.commit(facts: [], session: provisional)
        session = provisional
        let location = try await transport.createZone(for: household)
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
                                                                        claimBinding: binding, now: clock())
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
        let candidates = try await ownerRecoveryCandidates()
        guard candidates.count == 1 else { return [] }
        return [candidates[0].family]
    }

    func recoverOwnerFamily(_ location: CloudLocation) async throws {
        guard session.householdID == nil, location.isOwner else { throw HouseholdError.invitationUnavailable }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let participant = try await transport.participantID()
        let candidates = try await ownerRecoveryCandidates()
        guard candidates.count == 1, candidates[0].family.location == location else {
            throw HouseholdError.invitationUnavailable
        }
        let member = candidates[0].member
        let binding = AccountMembershipBinding.owner(householdID: location.householdID)
        let attemptID = UUID()
        let lock = try await acquireAccountMembershipLock(householdID: location.householdID,
                                                          attemptID: attemptID, matching: binding)
        let refreshed: (family: CloudFamily, member: FamilyMember, facts: [HouseholdFact])
        do {
            let refreshedCandidates = try await ownerRecoveryCandidates()
            guard refreshedCandidates.count == 1, let candidate = refreshedCandidates.first,
                  candidate.family.location == location,
                  candidate.member.id == member.id else { throw HouseholdError.invitationUnavailable }
            refreshed = candidate
        } catch {
            if lock.state == .provisional, lock.attemptID == attemptID {
                _ = try? await transport.releaseAccountMembershipLock(householdID: location.householdID,
                                                                       attemptID: attemptID, now: clock())
            }
            throw error
        }
        let active = try await transport.activateAccountMembershipLock(householdID: location.householdID,
                                                                        attemptID: lock.attemptID,
                                                                        claimBinding: binding, now: clock())
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
        guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        try await retryInvitationCleanup()
        let participant = try await transport.participantID()
        let location = try await transport.invitationLocation(for: url)
        if try await resumeAccountMembership(participant: participant, requestedLocation: location,
                                             invitationCode: invitationCode) { return }
        try await prepareInvitationAcceptance(url: url, location: location, participant: participant)
        do { try await redeemInvitation(invitationCode, in: location, participant: participant) }
        catch let cloudError as CKError where Self.isRetryableInvitationError(cloudError) { throw cloudError }
        catch {
            let redemptionError = error
            try await abandonPendingInvitationAcceptance(preserving: redemptionError)
        }
    }

    func redeemInvitation(_ text: String) async throws {
        guard let credential = InvitationCredential(text: text) else { throw HouseholdError.invitationNotFound }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        if let location = session.location, let participant = session.cloudParticipantID {
            do {
                if let shareURL = credential.shareURL,
                   session.pendingInvitationAcceptance?.phase == .awaitingRedemption {
                    guard try await transport.invitationLocation(for: shareURL) == location else {
                        throw HouseholdError.invitationNotFound
                    }
                }
                try await redeemInvitation(credential.code, in: location, participant: participant)
            }
            catch {
                guard session.pendingInvitationAcceptance?.phase == .awaitingRedemption else { throw error }
                if let cloudError = error as? CKError, Self.isRetryableInvitationError(cloudError) { throw error }
                try await abandonPendingInvitationAcceptance(preserving: error)
            }
            return
        }
        guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
        try await retryInvitationCleanup()
        let participant = try await transport.participantID()
        if let shareURL = credential.shareURL {
            let location = try await transport.invitationLocation(for: shareURL)
            if try await resumeAccountMembership(participant: participant, requestedLocation: location,
                                                 invitationCode: credential.code) { return }
            try await prepareInvitationAcceptance(url: shareURL, location: location, participant: participant)
            do { try await redeemInvitation(credential.code, in: location, participant: participant) }
            catch let cloudError as CKError where Self.isRetryableInvitationError(cloudError) { throw cloudError }
            catch {
                try await abandonPendingInvitationAcceptance(preserving: error)
            }
            return
        }
        if try await resumeAccountMembership(participant: participant, requestedLocation: nil,
                                             invitationCode: credential.code) { return }
        let families = try await transport.discoverFamilies()
        for family in families {
            let remote = try await transport.fetch(from: family.location)
            let imported = HouseholdSnapshot(facts: remote)
            if imported.invitation(matchingCode: credential.code) != nil {
                try await redeemInvitation(credential.code, in: family.location, participant: participant, remote: remote)
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
        guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        try await retryInvitationCleanup()
        let participant = try await transport.participantID()
        if try await resumeAccountMembership(participant: participant, requestedLocation: location,
                                             invitationCode: nil) { return }
        let accessExisted = try await transport.hasAcceptedAccess(to: location)
        let lock = try await acquireAccountMembershipLock(householdID: location.householdID)
        try beginPendingInvitationAcceptance(location: location, participant: participant,
                                             accessExistedBeforeAttempt: accessExisted, attemptID: lock.attemptID)
        do {
            try await acceptance()
            try confirmPendingInvitationAcceptance(location: location, participant: participant)
            try await identifyPendingInvitation(in: location)
            try await importFamily(location, participant: participant, accountLockAttemptID: lock.attemptID)
        }
        catch { try await abandonPendingInvitationAcceptance(preserving: error) }
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

    private func redeemInvitation(_ code: String, in location: CloudLocation, participant: String,
                                  remote suppliedFacts: [HouseholdFact]? = nil) async throws {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        guard session.householdID == nil || session.householdID == location.householdID else {
            throw HouseholdError.alreadyHasHousehold
        }
        let remote: [HouseholdFact]
        if let suppliedFacts { remote = suppliedFacts }
        else { remote = try await transport.fetch(from: location) }
        try validate(remote, householdID: location.householdID)
        let imported = HouseholdSnapshot(facts: remote)
        try validateCompleteFamily(imported, householdID: location.householdID)
        if let membership = try imported.accountMembership(participantID: participant, now: clock()) {
            guard InvitationCode.digest(code) == membership.claim.codeDigest else {
                throw HouseholdError.accountMembershipConflict
            }
            let canWrite = try await transport.canWrite(to: location)
            guard canWrite else { throw HouseholdError.readOnly }
            let lock = try await activateAccountMembershipLock(
                location: location, claimBinding: AccountMembershipBinding.invitation(membership)
            )
            try attach(remote: remote, location: location, participant: participant,
                       selectedMemberID: membership.member.id, cloudCanWrite: canWrite,
                       accountLockAttemptID: lock.attemptID)
            return
        }
        guard let invitation = imported.invitation(matchingCode: code),
              let member = imported.member(invitation.memberID), member.role == invitation.role,
              invitation.householdID == location.householdID else { throw HouseholdError.invitationNotFound }
        if imported.isInvitationRevoked(invitation.id) { throw HouseholdError.invitationRevoked }
        guard try await transport.hasInvitationAccess(participantID: invitation.cloudShareParticipantID,
                                                      in: location) else {
            throw HouseholdError.invitationNotFound
        }
        let validationTime = try await transport.invitationValidationTime(in: location, clientTime: clock())
        guard let importedHousehold = imported.household,
              imported.isActive(member, on: CivilDay(validationTime, calendar: importedHousehold.calendar)) else {
            throw HouseholdError.invitationUnavailable
        }
        if let existing = imported.invitationClaim(invitation.id) {
            _ = existing
            throw HouseholdError.invitationConsumed
        }
        guard validationTime < invitation.expiresAt else { throw HouseholdError.invitationExpired }
        guard try await transport.canWrite(to: location) else { throw HouseholdError.readOnly }
        let attemptID: UUID
        if let pending = session.pendingInvitationAcceptance, pending.location == location,
           let pendingAttemptID = pending.accountLockAttemptID {
            attemptID = pendingAttemptID
        } else {
            attemptID = try await acquireAccountMembershipLock(householdID: location.householdID).attemptID
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
            if let membership = try refreshedSnapshot.accountMembership(participantID: participant, now: clock()),
               membership.claim.codeDigest == invitation.codeDigest {
                let canWrite = try await transport.canWrite(to: location)
                let lock = try await activateAccountMembershipLock(
                    location: location, claimBinding: AccountMembershipBinding.invitation(membership),
                    attemptID: attemptID
                )
                try attach(remote: refreshed, location: location, participant: participant,
                           selectedMemberID: membership.member.id, cloudCanWrite: canWrite,
                           accountLockAttemptID: lock.attemptID)
                return
            }
            throw HouseholdError.invitationConsumed
        }
        let membership = AccountFamilyMembership(invitation: invitation, claim: claim, member: member)
        let lock = try await activateAccountMembershipLock(
            location: location, claimBinding: AccountMembershipBinding.invitation(membership),
            attemptID: attemptID
        )
        try attach(remote: remote + confirmedClaims, location: location, participant: participant,
                   selectedMemberID: invitation.memberID, cloudCanWrite: true,
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
                        selectedMemberID: UUID, cloudCanWrite: Bool, accountLockAttemptID: UUID) throws {
        let imported = HouseholdSnapshot(facts: remote)
        guard let membership = try imported.accountMembership(participantID: participant, now: clock()),
              membership.member.id == selectedMemberID else { throw HouseholdError.malformedData }
        var updated = session
        updated.householdID = location.householdID
        updated.location = location
        updated.cloudParticipantID = participant
        updated.selectedMemberID = selectedMemberID
        updated.cloudCanWrite = cloudCanWrite
        updated.legacyProfileIDs = []
        updated.pendingInvitationAcceptance = nil
        updated.accountMembershipLockAttemptID = accountLockAttemptID
        updated.accountMembershipClaimBinding = AccountMembershipBinding.invitation(membership)
        try repository.commit(facts: remote, session: updated, uploaded: true)
        session = updated
        cloudIsReadOnly = !cloudCanWrite
        try reload()
    }

    private func acquireAccountMembershipLock(householdID: UUID, attemptID: UUID? = nil,
                                              matching claimBinding: String? = nil) async throws
        -> AccountMembershipLock {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let candidate = attemptID ?? UUID()
        var lock = try await transport.acquireAccountMembershipLock(
            householdID: householdID,
            attemptID: candidate,
            expiresAt: clock().addingTimeInterval(InvitationCode.lifetime),
            now: clock()
        )
        if lock.state == .provisional, lock.householdID == householdID, lock.attemptID == candidate {
            return lock
        }
        if lock.state == .active, lock.householdID == householdID,
           let claimBinding, lock.claimBinding == claimBinding {
            if let localBinding = session.accountMembershipClaimBinding, localBinding != claimBinding {
                throw HouseholdError.accountMembershipConflict
            }
            return lock
        }
        if lock.state == .active, session.householdID == nil {
            try await reconcileInactiveAccountMembershipLock(lock)
            lock = try await transport.acquireAccountMembershipLock(
                householdID: householdID,
                attemptID: candidate,
                expiresAt: clock().addingTimeInterval(InvitationCode.lifetime),
                now: clock()
            )
            if lock.state == .provisional, lock.householdID == householdID, lock.attemptID == candidate {
                return lock
            }
        }
        if lock.state == .provisional, lock.expiresAt <= clock() {
            try await reconcileExpiredAccountMembershipLock(lock)
            lock = try await transport.acquireAccountMembershipLock(
                householdID: householdID,
                attemptID: candidate,
                expiresAt: clock().addingTimeInterval(InvitationCode.lifetime),
                now: clock()
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

    private func reconcileInactiveAccountMembershipLock(_ lock: AccountMembershipLock) async throws {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        guard let location = try await transport.membershipLocation(householdID: lock.householdID) else {
            guard try await transport.releaseAccountMembershipLock(householdID: lock.householdID,
                                                                   attemptID: lock.attemptID, now: clock()) else {
                throw HouseholdError.accountMembershipConflict
            }
            return
        }
        let remote = try await transport.fetch(from: location)
        try validate(remote, householdID: location.householdID)
        let imported = HouseholdSnapshot(facts: remote)
        let participant = try await transport.participantID()
        guard let current = try membershipBinding(in: imported, location: location, participant: participant),
              current == lock.claimBinding else { throw HouseholdError.accountMembershipConflict }
        throw HouseholdError.accountMembershipConflict
    }

    private func reconcileExpiredAccountMembershipLock(_ lock: AccountMembershipLock) async throws {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        guard let location = try await transport.membershipLocation(householdID: lock.householdID) else {
            guard try await transport.releaseAccountMembershipLock(householdID: lock.householdID,
                                                                   attemptID: lock.attemptID, now: clock()) else {
                throw HouseholdError.accountMembershipConflict
            }
            return
        }
        let remote = try await transport.fetch(from: location)
        do {
            try validate(remote, householdID: location.householdID)
            let imported = HouseholdSnapshot(facts: remote)
            let participant = try await transport.participantID()
            if let binding = try membershipBinding(in: imported, location: location,
                                                   participant: participant) {
                _ = try await transport.activateAccountMembershipLock(householdID: lock.householdID,
                                                                       attemptID: lock.attemptID,
                                                                       claimBinding: binding, now: clock())
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
        if let membership = try imported.accountMembership(participantID: participant, now: clock()) {
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

    private func ownerRecoveryMember(in imported: HouseholdSnapshot) -> FamilyMember? {
        guard imported.household != nil else { return nil }
        let claimedParentIDs = Set(imported.invitationClaims.compactMap { claim -> UUID? in
            guard let invitation = imported.invitation(claim.invitationID), invitation.role == .parent else { return nil }
            return claim.memberID
        })
        let candidates = imported.members.filter {
            $0.role == .parent && $0.archivedFrom == nil && !claimedParentIDs.contains($0.id)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func ownerRecoveryCandidates() async throws
        -> [(family: CloudFamily, member: FamilyMember, facts: [HouseholdFact])] {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        var candidates: [(family: CloudFamily, member: FamilyMember, facts: [HouseholdFact])] = []
        for family in try await transport.discoverFamilies() where family.location.isOwner {
            if let candidate = try await ownerRecoveryCandidate(for: family) {
                candidates.append(candidate)
            }
        }
        return candidates
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
            now: clock()
        )
    }

    private func prepareInvitationAcceptance(url: URL, location: CloudLocation, participant: String) async throws {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let accessExisted = try await transport.hasAcceptedAccess(to: location)
        let lock = try await acquireAccountMembershipLock(householdID: location.householdID)
        try beginPendingInvitationAcceptance(location: location, participant: participant,
                                             accessExistedBeforeAttempt: accessExisted, attemptID: lock.attemptID)
        do {
            try await transport.accept(url: url, expected: location)
            try confirmPendingInvitationAcceptance(location: location, participant: participant)
            try await identifyPendingInvitation(in: location)
        } catch {
            try await abandonPendingInvitationAcceptance(preserving: error)
        }
    }

    private func beginPendingInvitationAcceptance(location: CloudLocation, participant: String,
                                                  accessExistedBeforeAttempt: Bool, attemptID: UUID) throws {
        guard session.householdID == nil, session.pendingInvitationAcceptance == nil else {
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
        let remote = try await transport.fetch(from: location)
        try validate(remote, householdID: location.householdID)
        let imported = HouseholdSnapshot(facts: remote)
        try validateCompleteFamily(imported, householdID: location.householdID)
        let invitation = try await matchedPendingInvitation(in: imported, location: location)
        pending.invitationID = invitation.id
        pending.expiresAt = invitation.expiresAt
        try persistPendingInvitation(pending)
        switch imported.invitationStatus(invitation, now: clock()) {
        case .available: return
        case .expired: throw HouseholdError.invitationExpired
        case .revoked: throw HouseholdError.invitationRevoked
        case .consumed: throw HouseholdError.invitationConsumed
        }
    }

    private func matchedPendingInvitation(in imported: HouseholdSnapshot,
                                          location: CloudLocation) async throws -> FamilyInvitation {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        var matches: [FamilyInvitation] = []
        for invitation in imported.invitations {
            if try await transport.hasInvitationAccess(participantID: invitation.cloudShareParticipantID,
                                                       in: location) {
                matches.append(invitation)
            }
        }
        guard matches.count == 1, let invitation = matches.first else {
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

    func retryInvitationCleanup() async throws {
        guard var pending = session.pendingInvitationAcceptance else { return }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        guard try await transport.participantID() == pending.cloudParticipantID else {
            throw HouseholdError.wrongAccount
        }
        if pending.accountLockAttemptID == nil {
            pending.accountLockAttemptID = try await acquireAccountMembershipLock(
                householdID: pending.location.householdID
            ).attemptID
            try persistPendingInvitation(pending)
        }
        let remote = try await accessibleFacts(at: pending.location)
        if let remote {
            try validate(remote, householdID: pending.location.householdID)
            let imported = HouseholdSnapshot(facts: remote)
            try validateCompleteFamily(imported, householdID: pending.location.householdID)
            if let membership = try imported.accountMembership(participantID: pending.cloudParticipantID,
                                                               now: clock()) {
                let canWrite = try await transport.canWrite(to: pending.location)
                let lock = try await activateAccountMembershipLock(
                    location: pending.location, claimBinding: AccountMembershipBinding.invitation(membership),
                    attemptID: pending.accountLockAttemptID
                )
                try attach(remote: remote, location: pending.location, participant: pending.cloudParticipantID,
                           selectedMemberID: membership.member.id, cloudCanWrite: canWrite,
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
                if let invitationID = pending.invitationID,
                   let invitation = imported.invitation(invitationID),
                   !imported.isInvitationRevoked(invitationID),
                   imported.invitationClaim(invitationID) == nil,
                   clock() < (pending.expiresAt ?? invitation.expiresAt) {
                    if session.householdID == nil {
                        try await importFamily(pending.location, participant: pending.cloudParticipantID,
                                               accountLockAttemptID: pending.accountLockAttemptID)
                    }
                    return
                }
            }
        }
        try markPendingInvitationForCleanup(pending)
        if pending.accessExistedBeforeAttempt == false {
            try await transport.leave(pending.location)
        }
        if let attemptID = pending.accountLockAttemptID {
            guard try await transport.releaseAccountMembershipLock(householdID: pending.location.householdID,
                                                                   attemptID: attemptID, now: clock()) else {
                throw HouseholdError.accountMembershipConflict
            }
        }
        var updated = session
        updated.pendingInvitationAcceptance = nil
        try repository.commit(facts: [], session: updated)
        session = updated
    }

    func reconcileAccountMembershipLock() async throws {
        guard session.pendingInvitationAcceptance == nil,
              let location = session.location,
              let participant = session.cloudParticipantID,
              let transport else { return }
        guard try await transport.participantID() == participant else { throw HouseholdError.wrongAccount }
        let remote = try await transport.fetch(from: location)
        try validate(remote, householdID: location.householdID)
        let imported = HouseholdSnapshot(facts: remote)
        try await reconcileAccountMembershipLock(imported: imported, location: location,
                                                  participant: participant)
    }

    private func reconcileAccountMembershipLock(imported: HouseholdSnapshot, location: CloudLocation,
                                                participant: String) async throws {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        guard let binding = try membershipBinding(in: imported, location: location, participant: participant) else {
            return
        }
        do {
            if let localBinding = session.accountMembershipClaimBinding, localBinding != binding {
                throw HouseholdError.accountMembershipConflict
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

    private func accessibleFacts(at location: CloudLocation) async throws -> [HouseholdFact]? {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        do { return try await transport.fetch(from: location) }
        catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound
            || error.code == .permissionFailure {
            return nil
        }
    }

    private func resumeAccountMembership(participant: String, requestedLocation: CloudLocation?,
                                         invitationCode: String?) async throws -> Bool {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        var located: [(CloudLocation, [HouseholdFact], AccountFamilyMembership)] = []
        for family in try await transport.discoverFamilies() {
            if let requestedLocation, family.location != requestedLocation { continue }
            let remote = try await transport.fetch(from: family.location)
            try validate(remote, householdID: family.location.householdID)
            let imported = HouseholdSnapshot(facts: remote)
            try validateCompleteFamily(imported, householdID: family.location.householdID)
            if let membership = try imported.accountMembership(participantID: participant, now: clock()) {
                located.append((family.location, remote, membership))
            }
        }
        guard located.count <= 1 else { throw HouseholdError.accountMembershipConflict }
        guard let existing = located.first else { return false }
        let codeMatches = invitationCode.map { InvitationCode.digest($0) == existing.2.claim.codeDigest } ?? true
        guard requestedLocation == nil || requestedLocation == existing.0, codeMatches else {
            throw HouseholdError.accountMembershipConflict
        }
        let canWrite = try await transport.canWrite(to: existing.0)
        guard canWrite else { throw HouseholdError.readOnly }
        let lock = try await activateAccountMembershipLock(
            location: existing.0, claimBinding: AccountMembershipBinding.invitation(existing.2)
        )
        try attach(remote: existing.1, location: existing.0, participant: participant,
                   selectedMemberID: existing.2.member.id, cloudCanWrite: canWrite,
                   accountLockAttemptID: lock.attemptID)
        return true
    }

    private func pruneUnavailableInvitationAccess() async throws {
        guard let transport, let location = session.location, location.isOwner else { return }
        for invitation in snapshot.invitations where snapshot.invitationClaim(invitation.id) == nil
            && (snapshot.isInvitationRevoked(invitation.id) || clock() >= invitation.expiresAt) {
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
        isSyncing = true
        syncMessage = "Syncing…"
        defer {
            isSyncing = false
            if syncAgain { syncAgain = false; scheduleSync() }
        }
        do {
            let participant = try await transport.participantID()
            guard participant == session.cloudParticipantID else { throw HouseholdError.wrongAccount }
            let remote = try await transport.fetch(from: location)
            try validate(remote, householdID: location.householdID)
            let remoteSnapshot = HouseholdSnapshot(facts: remote)
            try await reconcileAccountMembershipLock(imported: remoteSnapshot, location: location,
                                                      participant: participant)
            cloudIsReadOnly = try await !transport.canWrite(to: location)
            var updated = session
            updated.cloudCanWrite = !cloudIsReadOnly
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
            var accountLockReleased = false
            if let cloudError = error as? CKError {
                cloudAccessBlocked = [.notAuthenticated, .permissionFailure, .zoneNotFound, .userDeletedZone].contains(cloudError.code)
                if [.permissionFailure, .zoneNotFound, .userDeletedZone].contains(cloudError.code),
                   let attemptID = session.accountMembershipLockAttemptID {
                    do {
                        if try await transport.participantID() == session.cloudParticipantID {
                            accountLockReleased = try await transport.releaseAccountMembershipLock(
                                householdID: location.householdID, attemptID: attemptID, now: clock()
                            )
                        }
                    } catch {
                        accountLockReleased = false
                    }
                }
            } else {
                cloudAccessBlocked = error as? HouseholdError == .wrongAccount || error as? HouseholdError == .malformedData
            }
            if cloudAccessBlocked {
                var updated = session
                updated.cloudCanWrite = false
                if accountLockReleased {
                    updated.accountMembershipLockAttemptID = nil
                    updated.accountMembershipClaimBinding = nil
                }
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
        case .completion(let value):
            return hasMembers(value.eligibleMemberIDs + [value.memberID, value.recordedByMemberID])
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
            case .invitation(let value):
                guard value.householdID == householdID, value.createdAt < value.expiresAt,
                      value.expiresAt.timeIntervalSince(value.createdAt) <= InvitationCode.lifetime,
                      value.codeDigest.count == 64, !value.cloudShareParticipantID.isEmpty,
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

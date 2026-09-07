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
        let eligible = eligibleChildren(choreID: choreID).map(\.id)
        let ids = Set(memberIDs)
        guard mode == .all || ids.isSubset(of: Set(eligible)) else { throw HouseholdError.invalidAssignment }
        switch mode {
        case .particular: guard ids.count == 1 else { throw HouseholdError.invalidAssignment }
        case .multiple: guard ids.count >= 2 else { throw HouseholdError.invalidAssignment }
        case .anyOne: guard !ids.isEmpty else { throw HouseholdError.invalidAssignment }
        case .all: guard !eligible.isEmpty else { throw HouseholdError.invalidAssignment }
        }
        let revision = ChoreRevision(id: UUID(), householdID: household.id, choreID: choreID, weekday: weekday,
                                     effectiveDay: effective, title: title, notes: notes, category: category, mode: mode,
                                     memberIDs: mode == .all ? [] : ids.sorted { $0.uuidString < $1.uuidString }, isArchived: false)
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

    func connect() async throws {
        try requireParent()
        guard let household, let transport else { throw HouseholdError.cloudUnavailable }
        guard session.location == nil else { try await synchronize(); return }
        let connectingSession = session
        let participant = try await transport.participantID()
        guard session.deviceID == connectingSession.deviceID,
              session.householdID == connectingSession.householdID, session.location == nil else {
            throw HouseholdError.noHousehold
        }
        let location = try await transport.createZone(for: household)
        guard session.deviceID == connectingSession.deviceID,
              session.householdID == connectingSession.householdID, session.location == nil else {
            throw HouseholdError.noHousehold
        }
        var updated = session
        updated.location = location
        updated.cloudParticipantID = participant
        try repository.commit(facts: [], session: updated)
        session = updated
        try await synchronize()
    }

    func discoverFamilies() async throws -> [CloudFamily] {
        guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        _ = try await transport.participantID()
        return try await transport.discoverFamilies()
    }

    func join(url: URL) async throws {
        guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let participant = try await transport.participantID()
        let location = try await transport.accept(url: url)
        try await importFamily(location, participant: participant)
    }

    func accept(metadata: CKShare.Metadata) async {
        do {
            guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
            guard let transport else { throw HouseholdError.cloudUnavailable }
            let participant = try await transport.participantID()
            let location = try await transport.accept(metadata: metadata)
            try await importFamily(location, participant: participant)
        } catch { errorMessage = error.localizedDescription }
    }

    func joinExisting(_ location: CloudLocation) async throws {
        guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
        guard let transport else { throw HouseholdError.cloudUnavailable }
        try await importFamily(location, participant: transport.participantID())
    }

    private func importFamily(_ location: CloudLocation, participant: String) async throws {
        guard let transport else { throw HouseholdError.cloudUnavailable }
        let remote = try await transport.fetch(from: location)
        try validate(remote, householdID: location.householdID)
        let imported = HouseholdSnapshot(facts: remote)
        guard imported.household?.id == location.householdID else { throw HouseholdError.invitation }
        guard imported.household?.isSetupComplete == true,
              imported.members.contains(where: { $0.role == .parent }),
              imported.members.contains(where: { $0.role == .child }),
              imported.revisions.allSatisfy({ revision in revision.memberIDs.allSatisfy { imported.member($0) != nil } }),
              imported.completions.allSatisfy({ contribution in
                  imported.member(contribution.memberID) != nil && imported.revisions.contains { $0.id == contribution.revisionID }
              }) else { throw HouseholdError.familyStillSyncing }
        let canWrite = try await transport.canWrite(to: location)
        guard session.householdID == nil else { throw HouseholdError.alreadyHasHousehold }
        var updated = session
        updated.householdID = location.householdID
        updated.location = location
        updated.cloudParticipantID = participant
        updated.selectedMemberID = nil
        updated.cloudCanWrite = canWrite
        try repository.commit(facts: remote, session: updated, uploaded: true)
        session = updated
        cloudIsReadOnly = !canWrite
        try reload()
        syncMessage = "Family connected"
    }

    func makeShare() async throws -> CKShare {
        try requireParent()
        if session.location == nil { try await connect() }
        try await synchronize()
        guard let transport, let location = session.location, location.isOwner else { throw HouseholdError.permission }
        return try await transport.share(for: location, title: household?.name ?? "Earned It Family")
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
            if let cloudError = error as? CKError {
                cloudAccessBlocked = [.notAuthenticated, .permissionFailure, .zoneNotFound, .userDeletedZone].contains(cloudError.code)
            } else {
                cloudAccessBlocked = error as? HouseholdError == .wrongAccount || error as? HouseholdError == .malformedData
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
        guard let householdID = session.householdID else { throw HouseholdError.noHousehold }
        let previousSequence = facts.map(\.sequence).max() ?? 0
        guard previousSequence < Int64.max else { throw HouseholdError.malformedData }
        let sequence = previousSequence + 1
        let fact = HouseholdFact(id: UUID(), householdID: householdID, sequence: sequence,
                                 authorDeviceID: session.deviceID, authorMemberID: selectedMember?.id, body: body)
        try repository.commit(facts: [fact])
        try reload()
        scheduleSync()
    }

    private func reload() throws {
        facts = try session.householdID.map { try repository.facts(householdID: $0) } ?? []
        snapshot = HouseholdSnapshot(facts: facts)
        rejectedChanges = try session.householdID.map { try repository.rejections(householdID: $0) } ?? [:]
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
        }
    }

    private func validatedName(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 50 else { throw HouseholdError.invalidName }
        return value
    }

    private func validate(_ facts: [HouseholdFact], householdID: UUID) throws {
        guard facts.allSatisfy({ $0.householdID == householdID && $0.sequence > 0 }) else { throw HouseholdError.malformedData }
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
            default: break
            }
        }
    }
}

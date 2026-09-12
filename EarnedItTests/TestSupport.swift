import Foundation
import CloudKit
@testable import EarnedIt

@MainActor
final class TestClock {
    var now: Date
    init(_ text: String = "2026-09-07T16:00:00Z") { now = ISO8601DateFormatter().date(from: text)! }
    func set(_ text: String) { now = ISO8601DateFormatter().date(from: text)! }
}

@MainActor
struct TestFamily {
    let clock: TestClock
    let repository: HouseholdRepository
    let store: HouseholdStore
    let parent: FamilyMember
    let hanna: FamilyMember
    let alek: FamilyMember

    init(transport: (any HouseholdTransport)? = nil, url: URL? = nil) throws {
        let clock = TestClock()
        self.clock = clock
        repository = try HouseholdRepository(url: url, inMemory: url == nil)
        store = try HouseholdStore(repository: repository, transport: transport, clock: { clock.now }, automaticSync: false)
        try store.createFamily(name: "Test Family", parentName: "Test Parent", timeZone: TimeZone(identifier: "America/New_York")!)
        parent = store.selectedMember!
        hanna = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
        alek = try store.saveMember(name: "Alek", role: .child, avatar: .rocket)
        try store.finishSetup()
    }

    func chore(_ mode: RequirementMode = .all, ids: [UUID] = [], weekday: Weekday = .monday) throws -> UUID {
        try store.saveChore(weekday: weekday, title: "Water plants", mode: mode, memberIDs: ids)
    }

    func complete(_ id: UUID, as member: FamilyMember, state: DailyStateKind = .done) throws {
        try store.selectProfile(member.id)
        try store.setCompletion(choreID: id, memberID: member.id, date: clock.now, state: state)
    }

    func move(to date: String) { clock.set(date); store.refreshDate() }
}

/// A shared server, with separate account-facing adapters. Never used in the app.
@MainActor
final class TestCloudServer {
    struct Zone {
        let householdID: UUID
        let name: String
        let owner: String
        var participants: Set<String> = []
        var pendingInvitationParticipants: Set<String> = []
        var claimedInvitationAccounts: [String: String] = [:]
        var facts: [UUID: HouseholdFact] = [:]
    }
    var zones: [String: Zone] = [:]
    var accountMembershipLocks: [String: AccountMembershipLock] = [:]
    var createCalls = 0
    var failUploadAfter: Int?
    var writeAllowed = true
}

@MainActor
final class TestTransport: HouseholdTransport {
    let server: TestCloudServer
    var account: String
    var fetchError: Error?
    var uploadedIDs: [UUID] = []
    var leaveFailures = 0
    var acceptErrorAfterHook: Error?
    private(set) var leaveAttempts = 0
    var beforeAccept: (() async -> Void)?
    var beforeCreateZone: (() async -> Void)?
    var beforeFetch: (() async -> Void)?

    init(server: TestCloudServer, account: String) { self.server = server; self.account = account }
    func participantID() async throws -> String { account }
    func acquireAccountMembershipLock(householdID: UUID, attemptID: UUID,
                                      expiresAt: Date, now: Date) async throws -> AccountMembershipLock {
        if let existing = server.accountMembershipLocks[account], existing.state == .active {
            guard existing.householdID == householdID else { throw HouseholdError.accountMembershipConflict }
            return existing
        }
        if let existing = server.accountMembershipLocks[account], existing.state == .provisional,
           existing.expiresAt > now {
            guard existing.householdID == householdID, existing.attemptID == attemptID else {
                throw HouseholdError.accountMembershipConflict
            }
            return existing
        }
        let lock = AccountMembershipLock(householdID: householdID, attemptID: attemptID, state: .provisional,
                                         expiresAt: expiresAt, invitationID: nil, memberID: nil, role: nil)
        server.accountMembershipLocks[account] = lock
        return lock
    }
    func activateAccountMembershipLock(householdID: UUID, attemptID: UUID, invitationID: UUID?,
                                       memberID: UUID, role: UserRole, now: Date) async throws -> AccountMembershipLock {
        guard var existing = server.accountMembershipLocks[account], existing.householdID == householdID else {
            throw HouseholdError.accountMembershipConflict
        }
        if existing.state == .active {
            guard existing.invitationID == invitationID, existing.memberID == memberID, existing.role == role else {
                throw HouseholdError.accountMembershipConflict
            }
            return existing
        }
        guard existing.state == .provisional, existing.attemptID == attemptID,
              existing.expiresAt > now else { throw HouseholdError.accountMembershipConflict }
        existing.state = .active
        existing.expiresAt = .distantFuture
        existing.invitationID = invitationID
        existing.memberID = memberID
        existing.role = role
        server.accountMembershipLocks[account] = existing
        return existing
    }
    func releaseAccountMembershipLock(householdID: UUID, attemptID: UUID, now: Date) async throws {
        guard var existing = server.accountMembershipLocks[account], existing.householdID == householdID,
              existing.attemptID == attemptID else { return }
        existing.state = .released
        existing.expiresAt = now
        existing.invitationID = nil
        existing.memberID = nil
        existing.role = nil
        server.accountMembershipLocks[account] = existing
    }
    func createZone(for household: Household) async throws -> CloudLocation {
        await beforeCreateZone?()
        server.createCalls += 1
        let zoneName = "EarnedIt-\(household.id)"
        server.zones[zoneName] = TestCloudServer.Zone(householdID: household.id, name: household.name, owner: account)
        return CloudLocation(householdID: household.id, zoneName: zoneName, ownerName: account, isOwner: true)
    }
    func discoverFamilies() async throws -> [CloudFamily] {
        server.zones.map { name, zone in
            CloudFamily(location: CloudLocation(householdID: zone.householdID, zoneName: name, ownerName: zone.owner,
                                               isOwner: zone.owner == account), name: zone.name)
        }.filter { $0.location.isOwner || server.zones[$0.location.zoneName]!.participants.contains(account) }
    }
    func accept(url: URL) async throws -> CloudLocation {
        let location = try await invitationLocation(for: url)
        try await accept(url: url, expected: location)
        return location
    }
    func invitationLocation(for url: URL) async throws -> CloudLocation {
        guard let zone = server.zones[url.lastPathComponent] else { throw HouseholdError.invitation }
        return CloudLocation(householdID: zone.householdID, zoneName: url.lastPathComponent,
                             ownerName: zone.owner, isOwner: zone.owner == account)
    }
    func invitationLocation(for metadata: CKShare.Metadata) throws -> CloudLocation { throw HouseholdError.invitation }
    func hasAcceptedAccess(to location: CloudLocation) async throws -> Bool {
        guard let zone = server.zones[location.zoneName] else { return false }
        return zone.owner == account || zone.participants.contains(account)
    }
    func accept(url: URL, expected location: CloudLocation) async throws {
        guard try await invitationLocation(for: url) == location,
              let zone = server.zones[url.lastPathComponent] else { throw HouseholdError.invitationNotFound }
        await beforeAccept?()
        if let acceptErrorAfterHook { throw acceptErrorAfterHook }
        if let participantID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "invitation" })?.value {
            guard zone.pendingInvitationParticipants.contains(participantID) else { throw HouseholdError.invitationConsumed }
            server.zones[url.lastPathComponent]?.pendingInvitationParticipants.remove(participantID)
            server.zones[url.lastPathComponent]?.claimedInvitationAccounts[participantID] = account
        }
        server.zones[url.lastPathComponent]?.participants.insert(account)
    }
    func accept(metadata: CKShare.Metadata) async throws -> CloudLocation { throw HouseholdError.invitation }
    func accept(metadata: CKShare.Metadata, expected location: CloudLocation) async throws {
        throw HouseholdError.invitation
    }
    func leave(_ location: CloudLocation) async throws {
        leaveAttempts += 1
        if leaveFailures > 0 {
            leaveFailures -= 1
            throw CKError(.networkFailure)
        }
        guard server.zones[location.zoneName]?.owner != account else { return }
        server.zones[location.zoneName]?.participants.remove(account)
        let participantIDs = server.zones[location.zoneName]?.claimedInvitationAccounts
            .filter { $0.value == account }.map(\.key) ?? []
        for participantID in participantIDs {
            server.zones[location.zoneName]?.claimedInvitationAccounts.removeValue(forKey: participantID)
        }
    }
    func fetch(from location: CloudLocation) async throws -> [HouseholdFact] {
        await beforeFetch?()
        if let fetchError { throw fetchError }
        guard let zone = server.zones[location.zoneName], zone.owner == account || zone.participants.contains(account) else {
            throw CKError(.permissionFailure)
        }
        return Array(zone.facts.values)
    }
    func upload(_ facts: [HouseholdFact], to location: CloudLocation) async throws {
        guard server.writeAllowed else { throw HouseholdError.readOnly }
        for (index, fact) in facts.enumerated() {
            if server.failUploadAfter == index { throw CKError(.networkFailure) }
            server.zones[location.zoneName]?.facts[fact.id] = fact
            uploadedIDs.append(fact.id)
        }
    }
    func share(for location: CloudLocation, title: String) async throws -> CKShare { throw HouseholdError.cloudUnavailable }
    func createInvitationAccess(for location: CloudLocation, title: String,
                                role: UserRole) async throws -> CloudInvitationAccess {
        guard let zone = server.zones[location.zoneName],
              zone.owner == account || zone.participants.contains(account) else { throw HouseholdError.permission }
        let participantID = UUID().uuidString
        server.zones[location.zoneName]?.pendingInvitationParticipants.insert(participantID)
        let url = URL(string: "https://test.invalid/\(location.zoneName)?invitation=\(participantID)")!
        return CloudInvitationAccess(participantID: participantID, url: url)
    }
    func revokeInvitationAccess(participantID: String, from location: CloudLocation) async throws {
        server.zones[location.zoneName]?.pendingInvitationParticipants.remove(participantID)
        if let account = server.zones[location.zoneName]?.claimedInvitationAccounts.removeValue(forKey: participantID) {
            server.zones[location.zoneName]?.participants.remove(account)
        }
    }
    func hasInvitationAccess(participantID: String, in location: CloudLocation) async throws -> Bool {
        server.zones[location.zoneName]?.claimedInvitationAccounts[participantID] == account
    }
    func claimInvitation(_ facts: [HouseholdFact], in location: CloudLocation) async throws -> [HouseholdFact] {
        guard server.writeAllowed, facts.count == 2,
              facts.allSatisfy({ if case .invitationClaim = $0.body { return true }; return false }) else {
            throw HouseholdError.readOnly
        }
        for fact in facts {
            if let existing = server.zones[location.zoneName]?.facts[fact.id],
               !Self.isSameInvitationClaim(existing, as: fact) {
                throw HouseholdError.invitationConsumed
            }
        }
        for fact in facts {
            server.zones[location.zoneName]?.facts[fact.id] = fact
            uploadedIDs.append(fact.id)
        }
        return facts
    }
    func canWrite(to location: CloudLocation) async throws -> Bool { server.writeAllowed }

    private static func isSameInvitationClaim(_ lhs: HouseholdFact, as rhs: HouseholdFact) -> Bool {
        guard lhs.id == rhs.id, lhs.householdID == rhs.householdID,
              lhs.authorDeviceID == rhs.authorDeviceID, lhs.authorMemberID == nil, rhs.authorMemberID == nil,
              case .invitationClaim(let left) = lhs.body,
              case .invitationClaim(let right) = rhs.body else { return false }
        return left.invitationID == right.invitationID && left.deviceID == right.deviceID
            && left.cloudParticipantID == right.cloudParticipantID && left.memberID == right.memberID
            && left.codeDigest == right.codeDigest
    }
}

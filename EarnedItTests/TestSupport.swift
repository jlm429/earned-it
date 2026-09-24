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
final class TestSuspensionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
        isWaiting = false
    }

    func waitForCancellation() async {
        isWaiting = true
        while !Task.isCancelled { await Task.yield() }
        isWaiting = false
    }
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
    struct LifecycleAuthority {
        var state: FamilyLifecycleState
        let creator: String
        var lastModifier: String
    }

    struct Zone {
        let householdID: UUID
        let name: String
        let owner: String
        var participants: Set<String> = []
        var pendingInvitationParticipants: Set<String> = []
        var claimedInvitationAccounts: [String: String] = [:]
        var facts: [UUID: HouseholdFact] = [:]
        var shareExists = false
    }
    var zones: [String: Zone] = [:]
    var accountMembershipLocks: [String: AccountMembershipLock] = [:]
    var privateAccountResetRecords: [String: Set<CloudAccountResetTarget>] = [:]
    var lifecycleAuthorities: [UUID: LifecycleAuthority] = [:]
    var authoritativeTime: Date?
    var createCalls = 0
    var failUploadAfter: Int?
    var writeAllowed = true
}

@MainActor
final class TestTransport: HouseholdTransport {
    let server: TestCloudServer
    let familyTransitionDiagnostics: FamilyTransitionDiagnostics
    var account: String {
        didSet {
            if account != oldValue { accountGeneration &+= 1 }
        }
    }
    private(set) var accountGeneration: UInt64 = 0
    var fetchError: Error?
    var invitationLocationError: Error?
    var invitationAccessVisible = true
    var acceptedParticipantIDTransforms = false
    private(set) var invitationLocationURLs: [URL] = []
    private(set) var acceptedURLs: [URL] = []
    var uploadedIDs: [UUID] = []
    var leaveFailures = 0
    var deleteFamilyFailures = 0
    var accountLockReleaseFailures = 0
    var accountLockActivationFailures = 0
    var accountLockReplacementFailures = 0
    var accountLockReplacementPostCommitFailures = 0
    var lifecycleBeginFailures = 0
    var lifecycleFinalizeFailures = 0
    var lifecycleStateError: Error?
    var accountMembershipValidationTimeError: Error?
    var membershipLocationError: Error?
    var preflightAccountLockReadError: Error?
    var preflightSharedZoneReadError: Error?
    var claimError: Error?
    var leaveError: Error?
    var acceptErrorAfterHook: Error?
    var invitationValidationTimeFailures = 0
    var invitationValidationTimeError: Error?
    var invitationAccessError: Error?
    var accountResetDiscoveryError: Error?
    var accountResetDeletionFailures = 0
    private(set) var invitationValidationTimeCalls = 0
    var extendedShareAccess: Set<String> = ["InProcessOneTimeLinks"]
    private(set) var leaveAttempts = 0
    private(set) var deleteFamilyAttempts = 0
    private(set) var leaveMutationEnqueues = 0
    private(set) var accountLockMutationEnqueues = 0
    private(set) var accountLockAcquireMutationEnqueues = 0
    private(set) var accountLockActivationMutationEnqueues = 0
    private(set) var accountLockReplacementMutationEnqueues = 0
    private(set) var lifecycleMutationEnqueues = 0
    private(set) var lifecycleReadCount = 0
    private(set) var invitationAccessCreationCalls = 0
    private(set) var accountResetDeletionAttempts = 0
    var beforeParticipantIDReturn: (() async -> Void)?
    var beforeAccept: (() async -> Void)?
    var beforeLeave: (() async -> Void)?
    var beforeLeaveSubmission: (() async -> Void)?
    var beforeAccountLockRelease: (() async -> Void)?
    var beforeAccountLockReleaseSubmission: (() async -> Void)?
    var afterAccountMembershipLockRead: (() async -> Void)?
    var beforeAccountLockAcquireSubmission: (() async -> Void)?
    var afterAccountLockAcquireSubmission: (() async -> Void)?
    var beforeAccountMembershipValidationTime: (() async -> Void)?
    var beforeAccountLockActivationSubmission: (() async -> Void)?
    var beforeAccountLockReplacementSubmission: (() async -> Void)?
    var afterAccountLockReplacementSubmission: (() async -> Void)?
    var beforeDeleteFamilyData: (() async -> Void)?
    var beforeLifecycleBegin: (() async -> Void)?
    var beforeLifecycleFinalize: (() async -> Void)?
    var beforeCreateZone: (() async -> Void)?
    var beforeFetch: (() async -> Void)?
    var beforeMembershipLocation: (() async -> Void)?
    var beforeAccountResetDeletion: (() async -> Void)?
    var afterAccountResetDeletion: (() async -> Void)?

    init(server: TestCloudServer, account: String,
         familyTransitionDiagnostics: FamilyTransitionDiagnostics? = nil) {
        self.server = server
        self.account = account
        self.familyTransitionDiagnostics = familyTransitionDiagnostics ?? FamilyTransitionDiagnostics()
    }
    func accountDidChange() { accountGeneration &+= 1 }
    func participantID() async throws -> String {
        let participant = account
        await beforeParticipantIDReturn?()
        return participant
    }
    func accountDataResetTargets(
        expectedParticipantID: String,
        expectedAccountGeneration: UInt64
    ) async throws -> [CloudAccountResetTarget] {
        guard account == expectedParticipantID,
              accountGeneration == expectedAccountGeneration else { throw HouseholdError.wrongAccount }
        if let accountResetDiscoveryError { throw accountResetDiscoveryError }
        var targets = server.zones.compactMap { zoneName, zone -> CloudAccountResetTarget? in
            guard Self.isEarnedItZoneName(zoneName) else { return nil }
            let resetZone = CloudResetZone(zoneName: zoneName, ownerName: zone.owner)
            if zone.owner == account { return .ownedZone(resetZone) }
            if zone.participants.contains(account) { return .sharedParticipation(resetZone) }
            return nil
        }
        if server.accountMembershipLocks[account] != nil {
            targets.append(.privateRecord(
                recordType: "AccountMembershipLock",
                recordName: "current-membership"
            ))
        }
        targets += server.privateAccountResetRecords[account] ?? []
        targets += server.lifecycleAuthorities.compactMap { householdID, authority in
            guard authority.creator == account else { return nil }
            return .publicRecord(
                recordType: "FamilyLifecycleAuthority",
                recordName: AccountMembershipBinding.lifecycleRecordName(householdID: householdID)
            )
        }
        guard account == expectedParticipantID,
              accountGeneration == expectedAccountGeneration else { throw HouseholdError.wrongAccount }
        return CloudAccountResetTarget.ordered(targets)
    }

    func deleteAccountDataResetTarget(
        _ target: CloudAccountResetTarget,
        expectedParticipantID: String,
        expectedAccountGeneration: UInt64
    ) async throws {
        try await requireAccountForReset(expectedParticipantID, generation: expectedAccountGeneration)
        accountResetDeletionAttempts += 1
        await beforeAccountResetDeletion?()
        guard account == expectedParticipantID,
              accountGeneration == expectedAccountGeneration else { throw HouseholdError.wrongAccount }
        if accountResetDeletionFailures > 0 {
            accountResetDeletionFailures -= 1
            throw CKError(.networkFailure)
        }
        switch target {
        case .ownedZone(let zone):
            guard Self.isEarnedItZoneName(zone.zoneName) else { throw HouseholdError.permission }
            if let existing = server.zones[zone.zoneName] {
                guard existing.owner == expectedParticipantID,
                      existing.owner == zone.ownerName else { throw HouseholdError.permission }
                server.zones.removeValue(forKey: zone.zoneName)
            }
        case .sharedParticipation(let zone):
            guard Self.isEarnedItZoneName(zone.zoneName) else { throw HouseholdError.permission }
            if let existing = server.zones[zone.zoneName] {
                guard existing.owner == zone.ownerName else { throw HouseholdError.permission }
                server.zones[zone.zoneName]?.participants.remove(expectedParticipantID)
                let claims = existing.claimedInvitationAccounts.filter {
                    $0.value == expectedParticipantID
                }.map(\.key)
                for claim in claims {
                    server.zones[zone.zoneName]?.claimedInvitationAccounts.removeValue(forKey: claim)
                }
            }
        case .privateRecord(let recordType, let recordName):
            if recordType == "AccountMembershipLock", recordName == "current-membership" {
                server.accountMembershipLocks.removeValue(forKey: expectedParticipantID)
            }
            server.privateAccountResetRecords[expectedParticipantID]?.remove(target)
        case .publicRecord(let recordType, let recordName):
            guard recordType == "FamilyLifecycleAuthority" else { throw HouseholdError.permission }
            if let match = server.lifecycleAuthorities.first(where: {
                AccountMembershipBinding.lifecycleRecordName(householdID: $0.key) == recordName
            }) {
                guard match.value.creator == expectedParticipantID else { throw HouseholdError.permission }
                server.lifecycleAuthorities.removeValue(forKey: match.key)
            }
        }
        await afterAccountResetDeletion?()
        guard account == expectedParticipantID,
              accountGeneration == expectedAccountGeneration else { throw HouseholdError.wrongAccount }
    }

    private static func isEarnedItZoneName(_ name: String) -> Bool {
        let prefix = "EarnedIt-"
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    func accountMembershipLock() async throws -> AccountMembershipLock? {
        let lock = server.accountMembershipLocks[account]
        await afterAccountMembershipLockRead?()
        return lock
    }
    func accountMembershipValidationTime(clientTime: Date) async throws -> Date {
        familyTransitionDiagnostics.record(stage: .membershipValidationTimeWrite, outcome: .started)
        await beforeAccountMembershipValidationTime?()
        if let accountMembershipValidationTimeError {
            familyTransitionDiagnostics.record(stage: .membershipValidationTimeWrite, outcome: .failed,
                                               error: accountMembershipValidationTimeError)
            throw accountMembershipValidationTimeError
        }
        familyTransitionDiagnostics.record(stage: .membershipValidationTimeWrite, outcome: .succeeded)
        return server.authoritativeTime ?? clientTime
    }
    func acquireAccountMembershipLock(householdID: UUID, attemptID: UUID,
                                      leaseDuration: TimeInterval, clientTime: Date) async throws
        -> AccountMembershipLock {
        let startingGeneration = accountGeneration
        let observedParticipantID = account
        familyTransitionDiagnostics.record(
            stage: .membershipLockAcquire, outcome: .started, householdID: householdID,
            attemptID: attemptID, participantID: observedParticipantID, accountGenerationStable: true
        )
        let now = try await accountMembershipValidationTime(clientTime: clientTime)
        await beforeAccountLockAcquireSubmission?()
        guard account == observedParticipantID,
              accountGeneration == startingGeneration else { throw HouseholdError.wrongAccount }
        accountLockAcquireMutationEnqueues += 1
        let lock: AccountMembershipLock
        if let existing = server.accountMembershipLocks[account],
           existing.state == .active || existing.state == .provisional {
            lock = existing
        } else {
            lock = AccountMembershipLock(householdID: householdID, attemptID: attemptID, state: .provisional,
                                         expiresAt: now.addingTimeInterval(min(max(leaseDuration, 0),
                                                                               InvitationCode.lifetime)),
                                         claimBinding: nil)
            server.accountMembershipLocks[account] = lock
        }
        await afterAccountLockAcquireSubmission?()
        try Task.checkCancellation()
        familyTransitionDiagnostics.record(
            stage: .membershipLockAcquire, outcome: .succeeded, lock: lock,
            participantID: observedParticipantID, accountGenerationStable: accountGeneration == startingGeneration
        )
        return lock
    }
    func replaceActiveRevokedAccountMembershipLock(
        householdID: UUID,
        revokedAttemptID: UUID,
        revokedClaimBinding: String,
        replacementAttemptID: UUID,
        expectedParticipantID: String,
        leaseDuration: TimeInterval,
        validatedAt: Date
    ) async throws -> AccountMembershipLock {
        let startingGeneration = accountGeneration
        let observedParticipantID = account
        familyTransitionDiagnostics.record(
            stage: .membershipLockReplace,
            outcome: .started,
            householdID: householdID,
            attemptID: replacementAttemptID,
            participantID: observedParticipantID,
            accountGenerationStable: true
        )
        do {
            guard revokedAttemptID != replacementAttemptID,
                  !revokedClaimBinding.isEmpty else {
                throw HouseholdError.accountMembershipConflict
            }
            guard observedParticipantID == expectedParticipantID else { throw HouseholdError.wrongAccount }
            guard
                  let existing = server.accountMembershipLocks[observedParticipantID],
                  existing.householdID == householdID,
                  existing.attemptID == revokedAttemptID,
                  existing.state == .active,
                  existing.claimBinding == revokedClaimBinding else {
                throw HouseholdError.accountMembershipConflict
            }
            await beforeAccountLockReplacementSubmission?()
            guard account == expectedParticipantID,
                  accountGeneration == startingGeneration else { throw HouseholdError.wrongAccount }
            if accountLockReplacementFailures > 0 {
                accountLockReplacementFailures -= 1
                throw CKError(.networkFailure)
            }
            guard server.accountMembershipLocks[observedParticipantID] == existing else {
                throw HouseholdError.accountMembershipConflict
            }
            accountLockReplacementMutationEnqueues += 1
            let replacement = AccountMembershipLock(
                householdID: householdID,
                attemptID: replacementAttemptID,
                state: .provisional,
                expiresAt: validatedAt.addingTimeInterval(min(max(leaseDuration, 0), InvitationCode.lifetime)),
                claimBinding: nil
            )
            server.accountMembershipLocks[observedParticipantID] = replacement
            if accountLockReplacementPostCommitFailures > 0 {
                accountLockReplacementPostCommitFailures -= 1
                throw CKError(.networkFailure)
            }
            await afterAccountLockReplacementSubmission?()
            guard account == expectedParticipantID,
                  accountGeneration == startingGeneration else { throw HouseholdError.wrongAccount }
            familyTransitionDiagnostics.record(
                stage: .membershipLockReplace,
                outcome: .succeeded,
                lock: replacement,
                participantID: observedParticipantID,
                accountGenerationStable: accountGeneration == startingGeneration
            )
            return replacement
        } catch {
            familyTransitionDiagnostics.record(
                stage: .membershipLockReplace,
                outcome: .failed,
                householdID: householdID,
                attemptID: replacementAttemptID,
                participantID: observedParticipantID,
                accountGenerationStable: accountGeneration == startingGeneration,
                error: error
            )
            throw error
        }
    }
    func activateAccountMembershipLock(householdID: UUID, attemptID: UUID,
                                       claimBinding: String, ownerAuthorityBinding: String,
                                       now: Date) async throws -> AccountMembershipLock {
        let startingGeneration = accountGeneration
        let observedParticipantID = account
        familyTransitionDiagnostics.record(
            stage: .membershipLockActivate, outcome: .started, householdID: householdID,
            attemptID: attemptID, participantID: observedParticipantID, accountGenerationStable: true
        )
        if accountLockActivationFailures > 0 {
            accountLockActivationFailures -= 1
            let error = CKError(.networkFailure)
            familyTransitionDiagnostics.record(stage: .membershipLockActivate, outcome: .failed,
                                               householdID: householdID, attemptID: attemptID,
                                               accountGenerationStable: true, error: error)
            throw error
        }
        await beforeAccountLockActivationSubmission?()
        guard account == observedParticipantID,
              accountGeneration == startingGeneration else { throw HouseholdError.wrongAccount }
        accountLockActivationMutationEnqueues += 1
        do {
            guard var existing = server.accountMembershipLocks[account], existing.householdID == householdID else {
                throw HouseholdError.accountMembershipConflict
            }
            if existing.state == .active {
                guard existing.claimBinding == claimBinding,
                      existing.ownerAuthorityBinding == nil
                        || existing.ownerAuthorityBinding == ownerAuthorityBinding else {
                    throw HouseholdError.accountMembershipConflict
                }
                existing.ownerAuthorityBinding = ownerAuthorityBinding
                server.accountMembershipLocks[account] = existing
            } else {
                guard existing.state == .provisional,
                      existing.attemptID == attemptID else { throw HouseholdError.accountMembershipConflict }
                existing.state = .active
                existing.expiresAt = .distantFuture
                existing.claimBinding = claimBinding
                existing.ownerAuthorityBinding = ownerAuthorityBinding
                server.accountMembershipLocks[account] = existing
            }
            familyTransitionDiagnostics.record(
                stage: .membershipLockActivate, outcome: .succeeded, lock: existing,
                participantID: observedParticipantID,
                accountGenerationStable: accountGeneration == startingGeneration
            )
            return existing
        } catch {
            familyTransitionDiagnostics.record(
                stage: .membershipLockActivate, outcome: .failed,
                householdID: householdID, attemptID: attemptID,
                participantID: observedParticipantID,
                accountGenerationStable: accountGeneration == startingGeneration, error: error
            )
            throw error
        }
    }
    func releaseAccountMembershipLock(householdID: UUID, attemptID: UUID, expectedParticipantID: String,
                                      now: Date) async throws -> Bool {
        let expectedGeneration = accountGeneration
        await beforeAccountLockRelease?()
        try Task.checkCancellation()
        guard account == expectedParticipantID else { throw HouseholdError.wrongAccount }
        await beforeAccountLockReleaseSubmission?()
        try Task.checkCancellation()
        guard account == expectedParticipantID,
              accountGeneration == expectedGeneration else { throw HouseholdError.wrongAccount }
        accountLockMutationEnqueues += 1
        if accountLockReleaseFailures > 0 {
            accountLockReleaseFailures -= 1
            throw CKError(.networkFailure)
        }
        guard var existing = server.accountMembershipLocks[account], existing.householdID == householdID,
              existing.attemptID == attemptID else { return false }
        existing.state = .released
        existing.expiresAt = now
        server.accountMembershipLocks[account] = existing
        return true
    }
    func releaseAccountMembershipLock(expectedLock: AccountMembershipLock, expectedParticipantID: String,
                                      reason: AccountMembershipLockReleaseReason,
                                      clientTime: Date, expectedAccountGeneration: UInt64) async throws -> Bool {
        let expectedGeneration = expectedAccountGeneration
        await beforeAccountLockRelease?()
        try Task.checkCancellation()
        guard account == expectedParticipantID,
              accountGeneration == expectedGeneration else { throw HouseholdError.wrongAccount }
        let releaseTime: Date
        switch reason {
        case .expiredProvisional:
            guard expectedLock.state == .provisional,
                  expectedLock.claimBinding == nil else { return false }
            releaseTime = try await accountMembershipValidationTime(clientTime: clientTime)
            guard account == expectedParticipantID,
                  accountGeneration == expectedGeneration else { throw HouseholdError.wrongAccount }
            guard releaseTime >= expectedLock.expiresAt else { return false }
        case .confirmedFamilyDeletion:
            guard expectedLock.state == .active else { return false }
            releaseTime = clientTime
        case .ownerSelfRelease:
            let ownerAuthority = AccountMembershipBinding.ownerAuthority(participantID: expectedParticipantID)
            guard expectedLock.state == .active,
                  expectedLock.claimBinding == AccountMembershipBinding.owner(
                    householdID: expectedLock.householdID
                  ),
                  expectedLock.ownerAuthorityBinding == nil
                    || expectedLock.ownerAuthorityBinding == ownerAuthority else { return false }
            releaseTime = clientTime
        }
        guard try await membershipLocation(householdID: expectedLock.householdID) == nil else { return false }
        guard account == expectedParticipantID,
              accountGeneration == expectedGeneration else { throw HouseholdError.wrongAccount }
        await beforeAccountLockReleaseSubmission?()
        try Task.checkCancellation()
        guard account == expectedParticipantID,
              accountGeneration == expectedGeneration else { throw HouseholdError.wrongAccount }
        accountLockMutationEnqueues += 1
        if accountLockReleaseFailures > 0 {
            accountLockReleaseFailures -= 1
            throw CKError(.networkFailure)
        }
        guard var existing = server.accountMembershipLocks[account], existing == expectedLock else { return false }
        existing.state = .released
        existing.expiresAt = releaseTime
        server.accountMembershipLocks[account] = existing
        return true
    }
    func membershipLocation(householdID: UUID) async throws -> CloudLocation? {
        await beforeMembershipLocation?()
        if let membershipLocationError { throw membershipLocationError }
        let matches = server.zones.filter { $0.value.householdID == householdID
            && ($0.value.owner == account || $0.value.participants.contains(account)) }.map { name, zone in
                CloudLocation(householdID: householdID, zoneName: name, ownerName: zone.owner,
                              isOwner: zone.owner == account)
            }
        return try CloudKitHouseholdTransport.uniqueMembershipLocation(matches)
    }

    func createZone(for household: Household) async throws -> CloudLocation {
        familyTransitionDiagnostics.record(stage: .zoneCreate, outcome: .started, householdID: household.id)
        await beforeCreateZone?()
        server.createCalls += 1
        let zoneName = "EarnedIt-\(household.id)"
        server.zones[zoneName] = TestCloudServer.Zone(householdID: household.id, name: household.name, owner: account)
        let location = CloudLocation(householdID: household.id, zoneName: zoneName, ownerName: account, isOwner: true)
        familyTransitionDiagnostics.record(stage: .zoneCreate, outcome: .succeeded, householdID: household.id)
        return location
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
        invitationLocationURLs.append(url)
        if let invitationLocationError { throw invitationLocationError }
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
        acceptedURLs.append(url)
        guard try await invitationLocation(for: url) == location,
              let zone = server.zones[url.lastPathComponent] else { throw HouseholdError.invitationNotFound }
        await beforeAccept?()
        if let acceptErrorAfterHook { throw acceptErrorAfterHook }
        if let participantID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "invitation" })?.value {
            // An accepted one-time URL acts like the regular private share URL.
            if zone.claimedInvitationAccounts[participantID] != nil,
               zone.owner == account || zone.participants.contains(account) { return }
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
    func leave(_ location: CloudLocation, expectedParticipantID: String) async throws {
        let expectedGeneration = accountGeneration
        leaveAttempts += 1
        await beforeLeave?()
        try Task.checkCancellation()
        guard account == expectedParticipantID else { throw HouseholdError.wrongAccount }
        await beforeLeaveSubmission?()
        try Task.checkCancellation()
        guard account == expectedParticipantID,
              accountGeneration == expectedGeneration else { throw HouseholdError.wrongAccount }
        leaveMutationEnqueues += 1
        if let leaveError { throw leaveError }
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
    func deleteFamilyData(at location: CloudLocation, expectedParticipantID: String) async throws {
        deleteFamilyAttempts += 1
        guard account == expectedParticipantID else { throw HouseholdError.wrongAccount }
        await beforeDeleteFamilyData?()
        guard location.isOwner,
              let zone = server.zones[location.zoneName],
              zone.householdID == location.householdID,
              zone.owner == account else {
            if server.zones[location.zoneName] == nil { return }
            throw HouseholdError.permission
        }
        if deleteFamilyFailures > 0 {
            deleteFamilyFailures -= 1
            throw CKError(.networkFailure)
        }
        server.zones.removeValue(forKey: location.zoneName)
    }
    func ensureFamilyLifecycleAuthority(householdID: UUID, expectedParticipantID: String) async throws
        -> FamilyLifecycleState {
        familyTransitionDiagnostics.record(stage: .lifecycleAuthorityPrepare, outcome: .started,
                                            householdID: householdID)
        let generation = accountGeneration
        guard account == expectedParticipantID else {
            familyTransitionDiagnostics.record(stage: .lifecycleAuthorityPrepare, outcome: .failed,
                                                householdID: householdID, error: HouseholdError.wrongAccount)
            throw HouseholdError.wrongAccount
        }
        if let existing = server.lifecycleAuthorities[householdID] {
            let comparison = CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
                recordTypeMatches: true,
                formatVersion: 1,
                rawState: existing.state.rawValue,
                creatorParticipantID: existing.creator,
                modifierParticipantID: existing.lastModifier,
                ownerAuthorityBinding: AccountMembershipBinding.ownerAuthority(participantID: account)
            )
            familyTransitionDiagnostics.recordLifecycleAuthority(
                attempt: 1,
                phase: .existingFetch,
                result: comparison.isAccepted ? .recordAccepted : .recordRejected,
                comparison: comparison
            )
            guard comparison.isAccepted else {
                familyTransitionDiagnostics.record(stage: .lifecycleAuthorityPrepare, outcome: .failed,
                                                    householdID: householdID,
                                                    error: HouseholdError.accountMembershipConflict)
                throw HouseholdError.accountMembershipConflict
            }
            familyTransitionDiagnostics.record(stage: .lifecycleAuthorityPrepare, outcome: .succeeded,
                                                householdID: householdID)
            return existing.state
        }
        familyTransitionDiagnostics.recordLifecycleAuthority(
            attempt: 1,
            phase: .existingFetch,
            result: .recordAbsent
        )
        guard accountGeneration == generation else { throw HouseholdError.wrongAccount }
        lifecycleMutationEnqueues += 1
        server.lifecycleAuthorities[householdID] = TestCloudServer.LifecycleAuthority(
            state: .active,
            creator: account,
            lastModifier: account
        )
        let comparison = CloudKitHouseholdTransport.familyLifecycleAuthorityComparison(
            recordTypeMatches: true,
            formatVersion: 1,
            rawState: FamilyLifecycleState.active.rawValue,
            creatorParticipantID: account,
            modifierParticipantID: account,
            ownerAuthorityBinding: AccountMembershipBinding.ownerAuthority(participantID: account)
        )
        familyTransitionDiagnostics.recordLifecycleAuthority(
            attempt: 1,
            phase: .save,
            result: .recordAccepted,
            comparison: comparison,
            stateMatchesRequested: true
        )
        familyTransitionDiagnostics.record(stage: .lifecycleAuthorityPrepare, outcome: .succeeded,
                                            householdID: householdID)
        return .active
    }
    func beginFamilyDeletion(householdID: UUID, expectedParticipantID: String) async throws {
        familyTransitionDiagnostics.record(stage: .lifecycleDeletionPublish, outcome: .started,
                                            householdID: householdID)
        let generation = accountGeneration
        guard account == expectedParticipantID else { throw HouseholdError.wrongAccount }
        await beforeLifecycleBegin?()
        guard account == expectedParticipantID,
              accountGeneration == generation else { throw HouseholdError.wrongAccount }
        if lifecycleBeginFailures > 0 {
            lifecycleBeginFailures -= 1
            throw CKError(.networkFailure)
        }
        guard var authority = server.lifecycleAuthorities[householdID],
              authority.creator == account,
              authority.lastModifier == account else { throw HouseholdError.accountMembershipConflict }
        lifecycleMutationEnqueues += 1
        if authority.state == .active { authority.state = .deleting }
        authority.lastModifier = account
        server.lifecycleAuthorities[householdID] = authority
        familyTransitionDiagnostics.record(stage: .lifecycleDeletionPublish, outcome: .succeeded,
                                            householdID: householdID)
    }
    func finalizeFamilyDeletion(householdID: UUID, expectedParticipantID: String) async throws {
        familyTransitionDiagnostics.record(stage: .lifecycleDeletionPublish, outcome: .started,
                                            householdID: householdID)
        let generation = accountGeneration
        guard account == expectedParticipantID else { throw HouseholdError.wrongAccount }
        await beforeLifecycleFinalize?()
        guard account == expectedParticipantID,
              accountGeneration == generation else { throw HouseholdError.wrongAccount }
        if lifecycleFinalizeFailures > 0 {
            lifecycleFinalizeFailures -= 1
            throw CKError(.networkFailure)
        }
        guard var authority = server.lifecycleAuthorities[householdID],
              authority.creator == account,
              authority.lastModifier == account,
              authority.state != .active else { throw HouseholdError.accountMembershipConflict }
        lifecycleMutationEnqueues += 1
        authority.state = .deleted
        authority.lastModifier = account
        server.lifecycleAuthorities[householdID] = authority
        familyTransitionDiagnostics.record(stage: .lifecycleDeletionPublish, outcome: .succeeded,
                                            householdID: householdID)
    }
    func familyLifecycleState(householdID: UUID, ownerAuthorityBinding: String,
                              expectedParticipantID: String) async throws -> FamilyLifecycleState? {
        familyTransitionDiagnostics.record(stage: .lifecycleDeletionCheck, outcome: .started,
                                            householdID: householdID)
        let generation = accountGeneration
        guard account == expectedParticipantID else { throw HouseholdError.wrongAccount }
        lifecycleReadCount += 1
        if let lifecycleStateError { throw lifecycleStateError }
        guard let authority = server.lifecycleAuthorities[householdID] else {
            familyTransitionDiagnostics.record(stage: .lifecycleDeletionCheck, outcome: .absent,
                                                householdID: householdID)
            return nil
        }
        guard AccountMembershipBinding.ownerAuthority(participantID: authority.creator) == ownerAuthorityBinding,
              AccountMembershipBinding.ownerAuthority(participantID: authority.lastModifier) == ownerAuthorityBinding,
              account == expectedParticipantID,
              accountGeneration == generation else { throw HouseholdError.accountMembershipConflict }
        familyTransitionDiagnostics.record(stage: .lifecycleDeletionCheck, outcome: .succeeded,
                                            householdID: householdID)
        return authority.state
    }
    func fetch(from location: CloudLocation) async throws -> [HouseholdFact] {
        familyTransitionDiagnostics.record(stage: .journalFetch, outcome: .started,
                                            householdID: location.householdID)
        await beforeFetch?()
        if let fetchError {
            familyTransitionDiagnostics.record(stage: .journalFetch, outcome: .failed,
                                                householdID: location.householdID, error: fetchError)
            throw fetchError
        }
        guard let zone = server.zones[location.zoneName] else {
            let error = CKError(.zoneNotFound)
            familyTransitionDiagnostics.record(stage: .journalFetch, outcome: .failed,
                                                householdID: location.householdID, error: error)
            throw error
        }
        guard zone.owner == account || zone.participants.contains(account) else {
            let error = CKError(.permissionFailure)
            familyTransitionDiagnostics.record(stage: .journalFetch, outcome: .failed,
                                                householdID: location.householdID, error: error)
            throw error
        }
        let facts = Array(zone.facts.values)
        familyTransitionDiagnostics.record(stage: .journalFetch, outcome: .succeeded,
                                            householdID: location.householdID, factCount: facts.count)
        return facts
    }
    func upload(_ facts: [HouseholdFact], to location: CloudLocation) async throws {
        let stage: FamilyTransitionDiagnosticStage = facts.contains { fact in
            if case .invitation = fact.body { return true }
            return false
        } ? .invitationFactUpload : .journalUpload
        familyTransitionDiagnostics.record(stage: stage, outcome: .started,
                                            householdID: location.householdID, factCount: facts.count)
        guard server.writeAllowed else {
            let error = HouseholdError.readOnly
            familyTransitionDiagnostics.record(stage: stage, outcome: .failed,
                                                householdID: location.householdID,
                                                factCount: facts.count, error: error)
            throw error
        }
        for (index, fact) in facts.enumerated() {
            if server.failUploadAfter == index {
                let error = CKError(.networkFailure)
                familyTransitionDiagnostics.record(stage: stage, outcome: .failed,
                                                    householdID: location.householdID,
                                                    factCount: facts.count, error: error)
                throw error
            }
            server.zones[location.zoneName]?.facts[fact.id] = fact
            uploadedIDs.append(fact.id)
        }
        familyTransitionDiagnostics.record(stage: stage, outcome: .succeeded,
                                            householdID: location.householdID, factCount: facts.count)
    }
    func share(for location: CloudLocation, title: String) async throws -> CKShare { throw HouseholdError.cloudUnavailable }
    func createInvitationAccess(for location: CloudLocation, title: String,
                                role: UserRole) async throws -> CloudInvitationAccess {
        invitationAccessCreationCalls += 1
        familyTransitionDiagnostics.record(stage: .shareFetch, outcome: .started,
                                            householdID: location.householdID)
        guard let zone = server.zones[location.zoneName] else {
            let error = HouseholdError.cloudUnavailable
            familyTransitionDiagnostics.record(stage: .shareFetch, outcome: .failed,
                                                householdID: location.householdID, error: error)
            throw error
        }
        if zone.shareExists {
            familyTransitionDiagnostics.record(stage: .shareFetch, outcome: .succeeded,
                                                householdID: location.householdID)
        } else {
            familyTransitionDiagnostics.record(stage: .shareFetch, outcome: .absent,
                                                householdID: location.householdID)
            familyTransitionDiagnostics.record(stage: .shareCreate, outcome: .started,
                                                householdID: location.householdID)
            server.zones[location.zoneName]?.shareExists = true
            familyTransitionDiagnostics.record(stage: .shareCreate, outcome: .succeeded,
                                                householdID: location.householdID)
        }
        familyTransitionDiagnostics.record(stage: .invitationAccessOwnerValidation, outcome: .started,
                                            householdID: location.householdID)
        guard zone.owner == account else {
            familyTransitionDiagnostics.record(stage: .invitationAccessOwnerValidation, outcome: .failed,
                                                householdID: location.householdID,
                                                error: HouseholdError.invitationOwnerRequired)
            throw HouseholdError.invitationOwnerRequired
        }
        familyTransitionDiagnostics.record(stage: .invitationAccessOwnerValidation, outcome: .succeeded,
                                            householdID: location.householdID)
        // Native CloudKit traps at addParticipant when this entitlement value is absent.
        // The double reports the rejected operation without terminating the test host.
        guard extendedShareAccess.contains("InProcessOneTimeLinks") else { throw HouseholdError.invitation }
        familyTransitionDiagnostics.record(stage: .participantCreate, outcome: .started,
                                            householdID: location.householdID)
        if let invitationAccessError {
            familyTransitionDiagnostics.record(stage: .participantCreate, outcome: .failed,
                                                householdID: location.householdID,
                                                error: invitationAccessError)
            throw invitationAccessError
        }
        let participantID = UUID().uuidString
        server.zones[location.zoneName]?.pendingInvitationParticipants.insert(participantID)
        let url = URL(string: "https://test.invalid/\(location.zoneName)?invitation=\(participantID)")!
        familyTransitionDiagnostics.record(stage: .participantCreate, outcome: .succeeded,
                                            householdID: location.householdID)
        return CloudInvitationAccess(participantID: participantID, url: url)
    }
    func revokeInvitationAccess(participantID: String, from location: CloudLocation) async throws {
        server.zones[location.zoneName]?.pendingInvitationParticipants.remove(participantID)
        if let account = server.zones[location.zoneName]?.claimedInvitationAccounts.removeValue(forKey: participantID) {
            server.zones[location.zoneName]?.participants.remove(account)
        }
    }
    func hasInvitationAccess(participantID: String, in location: CloudLocation) async throws -> Bool {
        invitationAccessVisible && !acceptedParticipantIDTransforms
            && server.zones[location.zoneName]?.claimedInvitationAccounts[participantID] == account
    }
    func invitationValidationTime(in location: CloudLocation, clientTime: Date) async throws -> Date {
        invitationValidationTimeCalls += 1
        familyTransitionDiagnostics.record(stage: .validationTimeWrite, outcome: .started,
                                            householdID: location.householdID)
        if invitationValidationTimeFailures > 0 {
            invitationValidationTimeFailures -= 1
            let error = invitationValidationTimeError ?? CKError(.networkFailure)
            familyTransitionDiagnostics.record(stage: .validationTimeWrite, outcome: .failed,
                                                householdID: location.householdID, error: error)
            throw error
        }
        familyTransitionDiagnostics.record(stage: .validationTimeWrite, outcome: .succeeded,
                                            householdID: location.householdID)
        return server.authoritativeTime ?? clientTime
    }
    func claimInvitation(_ facts: [HouseholdFact], in location: CloudLocation) async throws -> [HouseholdFact] {
        if let claimError { throw claimError }
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

    func ownerTransitionPreflight(targetHouseholdID: UUID, localSession: DeviceSession,
                                  localFacts: [HouseholdFact], localPendingFactCount: Int) async
        -> OwnerTransitionPreflightSnapshot {
        let startingGeneration = accountGeneration
        var result = OwnerTransitionPreflightSnapshot()
        result.localFactCount = localFacts.count
        result.localPendingFactCount = localPendingFactCount
        result.accountMatchesLocalParticipant = localSession.cloudParticipantID.map { $0 == account }
        if let location = localSession.location {
            if location.householdID != targetHouseholdID {
                result.localLocationState = .otherHousehold
            } else {
                result.localLocationState = location.isOwner ? .ownerForTarget : .sharedForTarget
            }
        }
        if let lock = server.accountMembershipLocks[account] {
            result.lockState = lock.state
            result.lockMatchesTargetHousehold = lock.householdID == targetHouseholdID
            result.lockMatchesOtherHousehold = lock.householdID != targetHouseholdID
            result.lockAttemptMatchesLocal = localSession.accountMembershipLockAttemptID.map {
                $0 == lock.attemptID
            }
            result.lockBindingMatchesTargetOwner = lock.claimBinding.map {
                $0 == AccountMembershipBinding.owner(householdID: targetHouseholdID)
            }
            result.lockOwnerAuthorityMatchesTargetOwner = lock.ownerAuthorityBinding.map {
                $0 == AccountMembershipBinding.ownerAuthority(participantID: account)
            }
        } else {
            result.lockMatchesTargetHousehold = false
            result.lockMatchesOtherHousehold = false
        }
        if let authority = server.lifecycleAuthorities[targetHouseholdID],
           authority.creator == account,
           authority.lastModifier == account {
            result.lifecycleState = authority.state
        }
        let zone = server.zones.values.first {
            $0.householdID == targetHouseholdID && $0.owner == account
        }
        result.cloudTargetZoneExists = zone != nil
        if let zone {
            let facts = Array(zone.facts.values)
            applyPreflightFactCounts(facts, to: &result)
            result.shareExists = zone.shareExists
            result.shareParticipantCount = zone.pendingInvitationParticipants.count + zone.participants.count
            result.pendingShareParticipantCount = zone.pendingInvitationParticipants.count
            result.acceptedShareParticipantCount = zone.participants.count
        } else {
            applyPreflightFactCounts([], to: &result)
            result.shareExists = false
            result.shareParticipantCount = 0
            result.pendingShareParticipantCount = 0
            result.acceptedShareParticipantCount = 0
        }
        result.accountGenerationStable = accountGeneration == startingGeneration
        return result
    }

    func childRecoveryPreflight(localSession: DeviceSession, localFacts: [HouseholdFact]) async
        -> ChildRecoveryPreflightSnapshot {
        let startingGeneration = accountGeneration
        var result = ChildRecoveryPreflightSnapshot()
        result.localFactCount = localFacts.count
        result.accountMatchesLocalParticipant = localSession.cloudParticipantID.map { $0 == account }
        if let error = preflightAccountLockReadError {
            result.result = .membershipLockUnavailable
            result.cloudErrors = FamilyTransitionDiagnostics.cloudErrors(from: error)
            result.accountGenerationStable = accountGeneration == startingGeneration
            return result
        }
        guard let lock = server.accountMembershipLocks[account] else {
            result.result = .lockMissing
            result.accountGenerationStable = true
            return result
        }
        result.furthestStage = .membershipLock
        result.lockState = lock.state
        result.lockMatchesLocalHousehold = localSession.householdID.map { $0 == lock.householdID }
        result.lockAttemptMatchesLocal = localSession.accountMembershipLockAttemptID.map { $0 == lock.attemptID }
        result.lockBindingMatchesLocal = localSession.accountMembershipClaimBinding.map { $0 == lock.claimBinding }
        result.lockHasOwnerAuthorityBinding = lock.ownerAuthorityBinding != nil
        if let binding = lock.ownerAuthorityBinding,
           let authority = server.lifecycleAuthorities[lock.householdID],
           AccountMembershipBinding.ownerAuthority(participantID: authority.creator) == binding,
           AccountMembershipBinding.ownerAuthority(participantID: authority.lastModifier) == binding {
            result.lifecycleState = authority.state
        }
        if let location = localSession.location {
            if location.householdID != lock.householdID {
                result.localLocationState = .otherHousehold
            } else {
                result.localLocationState = location.isOwner ? .ownerForTarget : .sharedForTarget
            }
        }
        if let error = preflightSharedZoneReadError {
            result.result = .sharedZoneUnavailable
            result.cloudErrors = FamilyTransitionDiagnostics.cloudErrors(from: error)
            result.accountGenerationStable = accountGeneration == startingGeneration
            return result
        }
        guard let zone = server.zones.values.first(where: {
            $0.householdID == lock.householdID && $0.owner != account && $0.participants.contains(account)
        }) else {
            result.sharedZoneExists = false
            result.furthestStage = .sharedZone
            result.result = lock.state == .released ? .lockReleased : .sharedZoneMissing
            result.accountGenerationStable = accountGeneration == startingGeneration
            return result
        }
        result.sharedZoneExists = true
        result.furthestStage = .sharedZone
        let facts = Array(zone.facts.values)
        let imported = HouseholdSnapshot(facts: facts)
        result.cloudFactCount = facts.count
        result.householdRootFactCount = facts.filter {
            if case .household = $0.body { return true }
            return false
        }.count
        result.memberFactCount = facts.filter {
            if case .member = $0.body { return true }
            return false
        }.count
        result.invitationReferenceCount = imported.invitations.count
        result.invitationClaimCount = imported.invitationClaims.count
        result.invitationRevocationCount = imported.invitationRevocations.count
        result.furthestStage = .journal
        result.shareExists = zone.shareExists
        result.currentParticipantPresentOnShare = zone.participants.contains(account)
        result.currentParticipantCanWrite = server.writeAllowed && zone.participants.contains(account)
        result.furthestStage = .share
        do {
            let membership = try imported.committedAccountMembership(participantID: account)
            result.committedExactMembershipPresent = membership != nil
            result.exactMemberMatchesLocalSelection = membership.map { $0.member.id == localSession.selectedMemberID }
            result.exactMemberRoleIsChild = membership.map { $0.member.role == .child }
            result.exactBindingMatchesLock = membership.map {
                AccountMembershipBinding.invitation($0) == lock.claimBinding
            }
            result.furthestStage = .exactMembership
            if lock.state == .released {
                result.result = .lockReleased
            } else if membership == nil {
                result.result = .committedMembershipMissing
            } else if result.exactBindingMatchesLock == true {
                result.result = .exactCommittedMembershipMatchesLock
            } else {
                result.result = .exactMembershipConflictsWithLock
            }
        } catch {
            result.result = .malformedOrAmbiguousMembership
        }
        if result.accountMatchesLocalParticipant == false { result.result = .accountUnavailable }
        result.accountGenerationStable = accountGeneration == startingGeneration
        return result
    }

    private func applyPreflightFactCounts(
        _ facts: [HouseholdFact],
        to result: inout OwnerTransitionPreflightSnapshot
    ) {
        let imported = HouseholdSnapshot(facts: facts)
        let childIDs = Set(imported.members.filter { $0.role == .child }.map(\.id))
        result.cloudFactCount = facts.count
        result.householdRootFactCount = facts.filter {
            if case .household = $0.body { return true }
            return false
        }.count
        result.memberFactCount = facts.filter {
            if case .member = $0.body { return true }
            return false
        }.count
        result.invitationReferenceCount = imported.invitations.count
        result.invitationClaimCount = imported.invitationClaims.count
        result.invitationRevocationCount = imported.invitationRevocations.count
        result.childMemberCount = childIDs.count
        result.childInvitationCount = imported.invitations.filter { $0.role == .child }.count
        result.childClaimCount = imported.invitationClaims.filter { childIDs.contains($0.memberID) }.count
        result.childGrantReferenceCount = imported.grants.reduce(into: 0) { count, grant in
            count += grant.memberIDs.filter(childIDs.contains).count
        }
        result.exactChildRecoveryBindingCount = imported.invitations.filter { invitation in
            guard invitation.role == .child,
                  let claim = imported.invitationClaim(invitation.id),
                  claim.memberID == invitation.memberID,
                  claim.cloudParticipantID == invitation.cloudShareParticipantID,
                  claim.codeDigest == invitation.codeDigest else { return false }
            return childIDs.contains(invitation.memberID)
        }.count
    }

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

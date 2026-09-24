import Foundation
import CloudKit

/// Explicit CloudKit transport. SwiftData's automatic mirroring is disabled.
@MainActor
final class CloudKitHouseholdTransport: HouseholdTransport {
    nonisolated static let containerIdentifier = "iCloud.com.jlm429.EarnedIt"
    let container: CKContainer
    private let zonePrefix = "EarnedIt-"
    private let recordType = "HouseholdFact"
    private let accountMembershipRecordType = "AccountMembershipLock"
    private let accountMembershipRecordName = "current-membership"
    private let familyLifecycleRecordType = "FamilyLifecycleAuthority"
    private static let accountPrivateResetRecordTypes = [
        "AccountMembershipLock",
        "AccountMembershipValidationTime",
        "InvitationValidationTime"
    ]
    private(set) var accountGeneration: UInt64 = 0
    let familyTransitionDiagnostics: FamilyTransitionDiagnostics

    init(container: CKContainer = CKContainer(identifier: containerIdentifier),
         familyTransitionDiagnostics: FamilyTransitionDiagnostics? = nil) {
        self.container = container
        self.familyTransitionDiagnostics = familyTransitionDiagnostics ?? FamilyTransitionDiagnostics()
    }

    func accountDidChange() {
        accountGeneration &+= 1
    }

    func participantID() async throws -> String {
        guard try await container.accountStatus() == .available else { throw HouseholdError.cloudUnavailable }
        return try await container.userRecordID().recordName
    }

    func accountDataResetTargets(
        expectedParticipantID: String,
        expectedAccountGeneration: UInt64
    ) async throws -> [CloudAccountResetTarget] {
        try await requireAccount(expectedParticipantID, generation: expectedAccountGeneration)
        var targets: [CloudAccountResetTarget] = []

        for zone in try await container.privateCloudDatabase.allRecordZones() {
            guard isEarnedItZone(zone.zoneID) else { continue }
            targets.append(.ownedZone(CloudResetZone(
                zoneName: zone.zoneID.zoneName,
                ownerName: zone.zoneID.ownerName
            )))
        }
        try await requireAccount(expectedParticipantID, generation: expectedAccountGeneration)

        for zone in try await container.sharedCloudDatabase.allRecordZones() {
            guard isEarnedItZone(zone.zoneID) else { continue }
            targets.append(.sharedParticipation(CloudResetZone(
                zoneName: zone.zoneID.zoneName,
                ownerName: zone.zoneID.ownerName
            )))
        }
        try await requireAccount(expectedParticipantID, generation: expectedAccountGeneration)

        for recordType in Self.accountPrivateResetRecordTypes where recordType != accountMembershipRecordType {
            let records = try await resetRecords(
                recordType: recordType,
                predicate: NSPredicate(format: "TRUEPREDICATE"),
                database: container.privateCloudDatabase,
                zoneID: .default
            )
            targets += records.map {
                .privateRecord(recordType: recordType, recordName: $0.recordID.recordName)
            }
            try await requireAccount(expectedParticipantID, generation: expectedAccountGeneration)
        }
        let membershipRecordID = CKRecord.ID(recordName: accountMembershipRecordName, zoneID: .default)
        do {
            let record = try await container.privateCloudDatabase.record(for: membershipRecordID)
            guard record.recordType == accountMembershipRecordType else { throw HouseholdError.malformedData }
            targets.append(.privateRecord(
                recordType: accountMembershipRecordType,
                recordName: accountMembershipRecordName
            ))
        } catch let error as CKError where Self.isRecordMissing(error, recordID: membershipRecordID) {
        }

        let creator = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: expectedParticipantID),
            action: .none
        )
        let publicRecords = try await resetRecords(
            recordType: familyLifecycleRecordType,
            predicate: NSPredicate(
                format: "%K == %@",
                CKRecord.SystemFieldKey.creatorUserRecordID,
                creator
            ),
            database: container.publicCloudDatabase,
            zoneID: .default
        )
        targets += publicRecords.compactMap { record in
            guard record.creatorUserRecordID?.recordName == expectedParticipantID else { return nil }
            return .publicRecord(
                recordType: familyLifecycleRecordType,
                recordName: record.recordID.recordName
            )
        }
        try await requireAccount(expectedParticipantID, generation: expectedAccountGeneration)
        return CloudAccountResetTarget.ordered(targets)
    }

    func deleteAccountDataResetTarget(
        _ target: CloudAccountResetTarget,
        expectedParticipantID: String,
        expectedAccountGeneration: UInt64
    ) async throws {
        try await requireAccount(expectedParticipantID, generation: expectedAccountGeneration)
        switch target {
        case .ownedZone(let zone):
            let zoneID = CKRecordZone.ID(zoneName: zone.zoneName, ownerName: zone.ownerName)
            guard isEarnedItZone(zoneID) else { throw HouseholdError.permission }
            do {
                _ = try await container.privateCloudDatabase.deleteRecordZone(withID: zoneID)
            } catch let error as CKError where [.unknownItem, .zoneNotFound, .userDeletedZone].contains(error.code) {
                break
            }
        case .sharedParticipation(let zone):
            let zoneID = CKRecordZone.ID(zoneName: zone.zoneName, ownerName: zone.ownerName)
            guard isEarnedItZone(zoneID) else { throw HouseholdError.permission }
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
            do {
                _ = try await container.sharedCloudDatabase.deleteRecord(withID: shareID)
            } catch let error as CKError where [.unknownItem, .zoneNotFound, .permissionFailure].contains(error.code) {
                break
            }
        case .privateRecord(let recordType, let recordName):
            guard Self.accountPrivateResetRecordTypes.contains(recordType) else {
                throw HouseholdError.permission
            }
            let recordID = CKRecord.ID(recordName: recordName, zoneID: .default)
            do {
                let record = try await container.privateCloudDatabase.record(for: recordID)
                guard record.recordType == recordType else { throw HouseholdError.malformedData }
                try await requireAccount(expectedParticipantID, generation: expectedAccountGeneration)
                _ = try await container.privateCloudDatabase.deleteRecord(withID: recordID)
            } catch let error as CKError where Self.isRecordMissing(error, recordID: recordID) {
                break
            }
        case .publicRecord(let recordType, let recordName):
            guard recordType == familyLifecycleRecordType else { throw HouseholdError.permission }
            let recordID = CKRecord.ID(recordName: recordName, zoneID: .default)
            do {
                let record = try await container.publicCloudDatabase.record(for: recordID)
                guard record.recordType == recordType,
                      record.creatorUserRecordID?.recordName == expectedParticipantID else {
                    throw HouseholdError.permission
                }
                try await requireAccount(expectedParticipantID, generation: expectedAccountGeneration)
                _ = try await container.publicCloudDatabase.deleteRecord(withID: recordID)
            } catch let error as CKError where Self.isRecordMissing(error, recordID: recordID) {
                break
            }
        }
        try await requireAccount(expectedParticipantID, generation: expectedAccountGeneration)
    }

    func accountMembershipLock() async throws -> AccountMembershipLock? {
        let recordID = CKRecord.ID(recordName: accountMembershipRecordName)
        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            return try decodeAccountMembershipLock(record)
        } catch let error as CKError where Self.isRecordMissing(error, recordID: recordID) {
            return nil
        }
    }

    func accountMembershipValidationTime(clientTime: Date) async throws -> Date {
        familyTransitionDiagnostics.record(stage: .membershipValidationTimeWrite, outcome: .started)
        let database = container.privateCloudDatabase
        let record = CKRecord(recordType: "AccountMembershipValidationTime")
        do {
            let results = try await database.modifyRecords(saving: [record], deleting: [],
                                                           savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let result = results.saveResults[record.recordID],
                  let serverTime = try result.get().modificationDate else { throw HouseholdError.cloudUnavailable }
            do { _ = try await database.deleteRecord(withID: record.recordID) } catch {}
            familyTransitionDiagnostics.record(stage: .membershipValidationTimeWrite, outcome: .succeeded)
            return serverTime
        } catch {
            familyTransitionDiagnostics.record(stage: .membershipValidationTimeWrite, outcome: .failed, error: error)
            throw error
        }
    }

    func acquireAccountMembershipLock(householdID: UUID, attemptID: UUID,
                                      leaseDuration: TimeInterval, clientTime: Date) async throws
        -> AccountMembershipLock {
        let startingGeneration = accountGeneration
        familyTransitionDiagnostics.record(
            stage: .membershipLockAcquire, outcome: .started, householdID: householdID,
            attemptID: attemptID,
            accountGenerationStable: accountGeneration == startingGeneration
        )
        var observedParticipantID: String?
        do {
            let participant = try await participantID()
            observedParticipantID = participant
            let now = try await accountMembershipValidationTime(clientTime: clientTime)
            let boundedDuration = min(max(leaseDuration, 0), InvitationCode.lifetime)
            let lock = try await updateAccountMembershipLock(
                expectedParticipantID: participant,
                expectedGeneration: startingGeneration
            ) { existing in
                if let existing, existing.state == .active {
                    return existing
                }
                if let existing, existing.state == .provisional {
                    return existing
                }
                return AccountMembershipLock(householdID: householdID, attemptID: attemptID, state: .provisional,
                                             expiresAt: now.addingTimeInterval(boundedDuration), claimBinding: nil)
            }
            familyTransitionDiagnostics.record(
                stage: .membershipLockAcquire, outcome: .succeeded, lock: lock,
                participantID: participant, accountGenerationStable: accountGeneration == startingGeneration
            )
            return lock
        } catch {
            familyTransitionDiagnostics.record(
                stage: .membershipLockAcquire, outcome: .failed, householdID: householdID,
                attemptID: attemptID, participantID: observedParticipantID,
                accountGenerationStable: accountGeneration == startingGeneration, error: error
            )
            throw error
        }
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
        guard revokedAttemptID != replacementAttemptID,
              !revokedClaimBinding.isEmpty else { throw HouseholdError.accountMembershipConflict }
        try await requireAccount(expectedParticipantID, generation: startingGeneration)
        familyTransitionDiagnostics.record(
            stage: .membershipLockReplace,
            outcome: .started,
            householdID: householdID,
            attemptID: replacementAttemptID,
            participantID: expectedParticipantID,
            accountGenerationStable: true
        )
        do {
            let boundedDuration = min(max(leaseDuration, 0), InvitationCode.lifetime)
            let replacement = try await updateAccountMembershipLock(
                expectedParticipantID: expectedParticipantID,
                expectedGeneration: startingGeneration
            ) { existing in
                guard let existing,
                      existing.householdID == householdID,
                      existing.attemptID == revokedAttemptID,
                      existing.state == .active,
                      existing.claimBinding == revokedClaimBinding else {
                    throw HouseholdError.accountMembershipConflict
                }
                return AccountMembershipLock(
                    householdID: householdID,
                    attemptID: replacementAttemptID,
                    state: .provisional,
                    expiresAt: validatedAt.addingTimeInterval(boundedDuration),
                    claimBinding: nil
                )
            }
            familyTransitionDiagnostics.record(
                stage: .membershipLockReplace,
                outcome: .succeeded,
                lock: replacement,
                participantID: expectedParticipantID,
                accountGenerationStable: accountGeneration == startingGeneration
            )
            return replacement
        } catch {
            familyTransitionDiagnostics.record(
                stage: .membershipLockReplace,
                outcome: .failed,
                householdID: householdID,
                attemptID: replacementAttemptID,
                participantID: expectedParticipantID,
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
        familyTransitionDiagnostics.record(
            stage: .membershipLockActivate, outcome: .started, householdID: householdID,
            attemptID: attemptID,
            accountGenerationStable: accountGeneration == startingGeneration
        )
        var observedParticipantID: String?
        do {
            let participant = try await participantID()
            observedParticipantID = participant
            let lock = try await updateAccountMembershipLock(
                expectedParticipantID: participant,
                expectedGeneration: startingGeneration
            ) { existing in
                guard var existing, existing.householdID == householdID else {
                    throw HouseholdError.accountMembershipConflict
                }
                if existing.state == .active {
                    guard existing.claimBinding == claimBinding,
                          existing.ownerAuthorityBinding == nil
                            || existing.ownerAuthorityBinding == ownerAuthorityBinding else {
                        throw HouseholdError.accountMembershipConflict
                    }
                    existing.ownerAuthorityBinding = ownerAuthorityBinding
                    return existing
                }
                guard existing.state == .provisional,
                      existing.attemptID == attemptID else { throw HouseholdError.accountMembershipConflict }
                existing.state = .active
                existing.expiresAt = .distantFuture
                existing.claimBinding = claimBinding
                existing.ownerAuthorityBinding = ownerAuthorityBinding
                return existing
            }
            familyTransitionDiagnostics.record(
                stage: .membershipLockActivate, outcome: .succeeded, lock: lock,
                participantID: participant, accountGenerationStable: accountGeneration == startingGeneration
            )
            return lock
        } catch {
            familyTransitionDiagnostics.record(
                stage: .membershipLockActivate, outcome: .failed, householdID: householdID,
                attemptID: attemptID, participantID: observedParticipantID,
                accountGenerationStable: accountGeneration == startingGeneration, error: error
            )
            throw error
        }
    }

    func releaseAccountMembershipLock(householdID: UUID, attemptID: UUID, expectedParticipantID: String,
                                      now: Date) async throws -> Bool {
        let expectedGeneration = accountGeneration
        try Task.checkCancellation()
        guard try await participantID() == expectedParticipantID else { throw HouseholdError.wrongAccount }
        try Task.checkCancellation()
        let result = try await updateAccountMembershipLock(
            expectedParticipantID: expectedParticipantID,
            expectedGeneration: expectedGeneration
        ) { existing in
            guard var existing else {
                return AccountMembershipLock(householdID: householdID, attemptID: attemptID, state: .released,
                                             expiresAt: now, claimBinding: nil)
            }
            guard existing.householdID == householdID, existing.attemptID == attemptID else { return existing }
            existing.state = .released
            existing.expiresAt = now
            return existing
        }
        return result.householdID == householdID && result.attemptID == attemptID && result.state == .released
    }

    func releaseAccountMembershipLock(expectedLock: AccountMembershipLock, expectedParticipantID: String,
                                      reason: AccountMembershipLockReleaseReason,
                                      clientTime: Date, expectedAccountGeneration: UInt64) async throws -> Bool {
        let expectedGeneration = expectedAccountGeneration
        guard accountGeneration == expectedGeneration else { throw HouseholdError.wrongAccount }
        try await requireAccount(expectedParticipantID, generation: expectedGeneration)
        let releaseTime: Date
        switch reason {
        case .expiredProvisional:
            guard expectedLock.state == .provisional,
                  expectedLock.claimBinding == nil else { return false }
            releaseTime = try await accountMembershipValidationTime(clientTime: clientTime)
            try await requireAccount(expectedParticipantID, generation: expectedGeneration)
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
        try await requireAccount(expectedParticipantID, generation: expectedGeneration)
        do {
            let result = try await updateAccountMembershipLock(
                expectedParticipantID: expectedParticipantID,
                expectedGeneration: expectedGeneration
            ) { existing in
                guard var existing, existing == expectedLock else {
                    throw AccountMembershipLockUpdateError.expectedLockMismatch
                }
                existing.state = .released
                existing.expiresAt = releaseTime
                return existing
            }
            return result.state == .released
        } catch AccountMembershipLockUpdateError.expectedLockMismatch {
            return false
        }
    }

    func createZone(for household: Household) async throws -> CloudLocation {
        familyTransitionDiagnostics.record(stage: .zoneCreate, outcome: .started, householdID: household.id)
        let zone = CKRecordZone(zoneName: zonePrefix + household.id.uuidString)
        do {
            _ = try await container.privateCloudDatabase.save(zone)
            let location = CloudLocation(householdID: household.id, zoneName: zone.zoneID.zoneName,
                                         ownerName: zone.zoneID.ownerName, isOwner: true)
            familyTransitionDiagnostics.record(stage: .zoneCreate, outcome: .succeeded,
                                                householdID: household.id)
            return location
        } catch {
            familyTransitionDiagnostics.record(stage: .zoneCreate, outcome: .failed,
                                                householdID: household.id, error: error)
            throw error
        }
    }

    func membershipLocation(householdID: UUID) async throws -> CloudLocation? {
        let expectedZoneName = zonePrefix + householdID.uuidString
        var matches: [CloudLocation] = []
        for isOwner in [true, false] {
            let database = isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
            for zone in try await database.allRecordZones() where zone.zoneID.zoneName == expectedZoneName {
                if let candidate = location(zoneID: zone.zoneID, isOwner: isOwner) { matches.append(candidate) }
            }
        }
        return try Self.uniqueMembershipLocation(matches)
    }

    nonisolated static func uniqueMembershipLocation(_ matches: [CloudLocation]) throws -> CloudLocation? {
        guard matches.count <= 1 else { throw HouseholdError.accountMembershipConflict }
        return matches.first
    }

    func discoverFamilies() async throws -> [CloudFamily] {
        var families: [CloudFamily] = []
        for isOwner in [true, false] {
            let database = isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
            for zone in try await database.allRecordZones() where zone.zoneID.zoneName.hasPrefix(zonePrefix) {
                guard let location = location(zoneID: zone.zoneID, isOwner: isOwner) else { continue }
                let snapshot = HouseholdSnapshot(facts: try await fetch(from: location))
                if let household = snapshot.household {
                    families.append(CloudFamily(location: location, name: household.name))
                }
            }
        }
        return families.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func accept(url: URL) async throws -> CloudLocation {
        let location = try await invitationLocation(for: url)
        try await accept(url: url, expected: location)
        return location
    }

    func invitationLocation(for url: URL) async throws -> CloudLocation {
        guard url.scheme == "https", let host = url.host,
              host == "icloud.com" || host.hasSuffix(".icloud.com") else {
            throw HouseholdError.invitationUnavailable
        }
        do {
            let metadatas = try await container.shareMetadatas(for: [url])
            guard let metadata = try metadatas[url]?.get() else { throw HouseholdError.invitationUnavailable }
            return try invitationLocation(for: metadata)
        } catch let error as CKError where error.code == .unknownItem || error.code == .permissionFailure {
            throw HouseholdError.invitationUnavailable
        }
    }

    func invitationLocation(for metadata: CKShare.Metadata) throws -> CloudLocation {
        guard metadata.containerIdentifier == Self.containerIdentifier,
              metadata.share.recordID.recordName == CKRecordNameZoneWideShare,
              let location = location(zoneID: metadata.share.recordID.zoneID, isOwner: metadata.participantRole == .owner) else {
            throw HouseholdError.invitation
        }
        return location
    }

    func hasAcceptedAccess(to location: CloudLocation) async throws -> Bool {
        if location.isOwner { return true }
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(for: location))
        do {
            _ = try await container.sharedCloudDatabase.record(for: id)
            return true
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound
            || error.code == .permissionFailure {
            return false
        }
    }

    func accept(url: URL, expected location: CloudLocation) async throws {
        guard url.scheme == "https", let host = url.host,
              host == "icloud.com" || host.hasSuffix(".icloud.com") else {
            throw HouseholdError.invitationUnavailable
        }
        do {
            let metadatas = try await container.shareMetadatas(for: [url])
            guard let metadata = try metadatas[url]?.get() else { throw HouseholdError.invitationUnavailable }
            try await accept(metadata: metadata, expected: location)
        } catch let error as CKError where error.code == .unknownItem || error.code == .permissionFailure {
            throw HouseholdError.invitationUnavailable
        }
    }

    func accept(metadata: CKShare.Metadata) async throws -> CloudLocation {
        let location = try invitationLocation(for: metadata)
        try await accept(metadata: metadata, expected: location)
        return location
    }

    func accept(metadata: CKShare.Metadata, expected location: CloudLocation) async throws {
        guard try invitationLocation(for: metadata) == location else { throw HouseholdError.invitationNotFound }
        if metadata.participantRole != .owner && metadata.participantStatus != .accepted {
            let accepted = try await container.accept([metadata])
            guard let result = accepted[metadata] else { throw HouseholdError.invitation }
            _ = try result.get()
        }
    }

    func leave(_ location: CloudLocation, expectedParticipantID: String) async throws {
        let expectedGeneration = accountGeneration
        try Task.checkCancellation()
        guard try await participantID() == expectedParticipantID else { throw HouseholdError.wrongAccount }
        try Task.checkCancellation()
        guard accountGeneration == expectedGeneration else { throw HouseholdError.wrongAccount }
        guard !location.isOwner else { return }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(for: location))
        do {
            try await enqueueModifyRecords(saving: [], deleting: [shareID],
                                           in: container.sharedCloudDatabase)
            try Task.checkCancellation()
            guard accountGeneration == expectedGeneration,
                  try await participantID() == expectedParticipantID else { throw HouseholdError.wrongAccount }
        }
        catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound
            || error.code == .permissionFailure {}
    }

    func deleteFamilyData(at location: CloudLocation, expectedParticipantID: String) async throws {
        let expectedGeneration = accountGeneration
        guard location.isOwner else { throw HouseholdError.permission }
        try Task.checkCancellation()
        guard try await participantID() == expectedParticipantID else { throw HouseholdError.wrongAccount }
        try Task.checkCancellation()
        guard accountGeneration == expectedGeneration else { throw HouseholdError.wrongAccount }
        do {
            _ = try await container.privateCloudDatabase.deleteRecordZone(withID: zoneID(for: location))
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound
            || error.code == .userDeletedZone {
            // A prior confirmed attempt already reached the cloud-authoritative postcondition.
        }
        try Task.checkCancellation()
        guard accountGeneration == expectedGeneration,
              try await participantID() == expectedParticipantID else { throw HouseholdError.wrongAccount }
    }

    func ensureFamilyLifecycleAuthority(householdID: UUID, expectedParticipantID: String) async throws
        -> FamilyLifecycleState {
        try await updateFamilyLifecycleAuthority(
            householdID: householdID,
            expectedParticipantID: expectedParticipantID,
            stage: .lifecycleAuthorityPrepare
        ) { existing in
            existing ?? .active
        }
    }

    func beginFamilyDeletion(householdID: UUID, expectedParticipantID: String) async throws {
        _ = try await updateFamilyLifecycleAuthority(
            householdID: householdID,
            expectedParticipantID: expectedParticipantID,
            stage: .lifecycleDeletionPublish
        ) { existing in
            switch existing {
            case .active: return .deleting
            case .deleting: return .deleting
            case .deleted: return .deleted
            case nil: throw HouseholdError.accountMembershipConflict
            }
        }
    }

    func finalizeFamilyDeletion(householdID: UUID, expectedParticipantID: String) async throws {
        _ = try await updateFamilyLifecycleAuthority(
            householdID: householdID,
            expectedParticipantID: expectedParticipantID,
            stage: .lifecycleDeletionPublish
        ) { existing in
            switch existing {
            case .deleting, .deleted: return .deleted
            case .active, nil: throw HouseholdError.accountMembershipConflict
            }
        }
    }

    func familyLifecycleState(householdID: UUID, ownerAuthorityBinding: String,
                              expectedParticipantID: String) async throws -> FamilyLifecycleState? {
        let expectedGeneration = accountGeneration
        familyTransitionDiagnostics.record(stage: .lifecycleDeletionCheck, outcome: .started,
                                            householdID: householdID)
        do {
            try await requireAccount(expectedParticipantID, generation: expectedGeneration)
            let state = try await readFamilyLifecycleAuthority(
                householdID: householdID,
                ownerAuthorityBinding: ownerAuthorityBinding
            )
            try await requireAccount(expectedParticipantID, generation: expectedGeneration)
            familyTransitionDiagnostics.record(stage: .lifecycleDeletionCheck,
                                                outcome: state == nil ? .absent : .succeeded,
                                                householdID: householdID)
            return state
        } catch {
            familyTransitionDiagnostics.record(stage: .lifecycleDeletionCheck, outcome: .failed,
                                                householdID: householdID, error: error)
            throw error
        }
    }

    func fetch(from location: CloudLocation) async throws -> [HouseholdFact] {
        familyTransitionDiagnostics.record(stage: .journalFetch, outcome: .started,
                                            householdID: location.householdID)
        do {
            let facts = try await readFacts(from: location)
            familyTransitionDiagnostics.record(stage: .journalFetch, outcome: .succeeded,
                                                householdID: location.householdID, factCount: facts.count)
            return facts
        } catch {
            familyTransitionDiagnostics.record(stage: .journalFetch, outcome: .failed,
                                                householdID: location.householdID, error: error)
            throw error
        }
    }

    private func readFacts(from location: CloudLocation) async throws -> [HouseholdFact] {
        let database = database(for: location)
        var cursor: CKServerChangeToken?
        var facts: [UUID: HouseholdFact] = [:]
        var moreComing = true
        // A full paginated read keeps the small immutable journal independent of expired cursors.
        // No application records are deleted by the app, including completion reversals.
        while moreComing {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID(for: location), since: cursor)
            for (_, result) in changes.modificationResultsByID {
                let record = try result.get().record
                guard record.recordType == recordType else { continue }
                let fact = try Self.decode(record)
                guard fact.householdID == location.householdID else { throw HouseholdError.malformedData }
                facts[fact.id] = fact
            }
            cursor = changes.changeToken
            moreComing = changes.moreComing
        }
        return facts.values.sorted(by: HouseholdFact.precedes)
    }

    func upload(_ facts: [HouseholdFact], to location: CloudLocation) async throws {
        let stage: FamilyTransitionDiagnosticStage = facts.contains { fact in
            if case .invitation = fact.body { return true }
            return false
        } ? .invitationFactUpload : .journalUpload
        familyTransitionDiagnostics.record(stage: stage, outcome: .started,
                                            householdID: location.householdID, factCount: facts.count)
        let database = database(for: location)
        do {
            try await Self.uploadConfirmed(facts, to: location) { record in
                let results = try await database.modifyRecords(saving: [record], deleting: [],
                                                               savePolicy: .ifServerRecordUnchanged, atomically: true)
                guard let result = results.saveResults[record.recordID] else { throw HouseholdError.malformedData }
                return try result.get()
            }
            familyTransitionDiagnostics.record(stage: stage, outcome: .succeeded,
                                                householdID: location.householdID, factCount: facts.count)
        } catch {
            familyTransitionDiagnostics.record(stage: stage, outcome: .failed,
                                                householdID: location.householdID,
                                                factCount: facts.count, error: error)
            throw error
        }
    }

    static func uploadConfirmed(_ facts: [HouseholdFact], to location: CloudLocation,
                                save: (CKRecord) async throws -> CKRecord) async throws {
        for fact in facts.sorted(by: HouseholdFact.precedes) {
            guard fact.householdID == location.householdID else { throw HouseholdError.malformedData }
            let record = try record(for: fact, location: location)
            do { _ = try await save(record) } catch let error as CKError {
                guard error.code == .serverRecordChanged,
                      let server = error.serverRecord, try decode(server) == fact else { throw error }
            }
        }
    }

    func share(for location: CloudLocation, title: String) async throws -> CKShare {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(for: location))
        familyTransitionDiagnostics.record(stage: .shareFetch, outcome: .started,
                                            householdID: location.householdID)
        do {
            guard let share = try await database(for: location).record(for: id) as? CKShare else {
                throw HouseholdError.malformedData
            }
            familyTransitionDiagnostics.record(stage: .shareFetch, outcome: .succeeded,
                                                householdID: location.householdID)
            return share
        } catch let error as CKError where error.code == .unknownItem {
            familyTransitionDiagnostics.record(stage: .shareFetch, outcome: .absent,
                                                householdID: location.householdID)
            familyTransitionDiagnostics.record(stage: .shareOwnerValidation, outcome: .started,
                                                householdID: location.householdID)
            guard location.isOwner else {
                familyTransitionDiagnostics.record(stage: .shareOwnerValidation, outcome: .failed,
                                                    householdID: location.householdID,
                                                    error: HouseholdError.invitation)
                throw HouseholdError.invitation
            }
            familyTransitionDiagnostics.record(stage: .shareOwnerValidation, outcome: .succeeded,
                                                householdID: location.householdID)
            let share = CKShare(recordZoneID: zoneID(for: location))
            share.publicPermission = .none
            share[CKShare.SystemFieldKey.title] = title as CKRecordValue
            familyTransitionDiagnostics.record(stage: .shareCreate, outcome: .started,
                                                householdID: location.householdID)
            do {
                guard let saved = try await container.privateCloudDatabase.save(share) as? CKShare else {
                    throw HouseholdError.malformedData
                }
                familyTransitionDiagnostics.record(stage: .shareCreate, outcome: .succeeded,
                                                    householdID: location.householdID)
                return saved
            } catch {
                familyTransitionDiagnostics.record(stage: .shareCreate, outcome: .failed,
                                                    householdID: location.householdID, error: error)
                throw error
            }
        } catch {
            familyTransitionDiagnostics.record(stage: .shareFetch, outcome: .failed,
                                                householdID: location.householdID, error: error)
            throw error
        }
    }

    func createInvitationAccess(for location: CloudLocation, title: String,
        role: UserRole) async throws -> CloudInvitationAccess {
        let share = try await share(for: location, title: title)
        familyTransitionDiagnostics.record(stage: .invitationAccessOwnerValidation, outcome: .started,
                                            householdID: location.householdID)
        guard location.isOwner else {
            familyTransitionDiagnostics.record(stage: .invitationAccessOwnerValidation, outcome: .failed,
                                                householdID: location.householdID,
                                                error: HouseholdError.invitationOwnerRequired)
            throw HouseholdError.invitationOwnerRequired
        }
        familyTransitionDiagnostics.record(stage: .invitationAccessOwnerValidation, outcome: .succeeded,
                                            householdID: location.householdID)

        familyTransitionDiagnostics.record(stage: .participantCreate, outcome: .started,
                                            householdID: location.householdID)
        let participant = CKShare.Participant.oneTimeURLParticipant()
        participant.permission = .readWrite
        participant.role = .privateUser
        share.addParticipant(participant)
        do {
            guard let saved = try await database(for: location).save(share) as? CKShare,
                  let url = oneTimeURL(in: saved, participantID: participant.participantID) else {
                throw HouseholdError.invitation
            }
            familyTransitionDiagnostics.record(stage: .participantCreate, outcome: .succeeded,
                                                householdID: location.householdID)
            return CloudInvitationAccess(participantID: participant.participantID, url: url)
        } catch {
            familyTransitionDiagnostics.record(stage: .participantCreate, outcome: .failed,
                                                householdID: location.householdID, error: error)
            throw error
        }
    }

    func revokeInvitationAccess(participantID: String, from location: CloudLocation) async throws {
        let share = try await share(for: location, title: "Earned It Family")
        guard let participant = share.participants.first(where: { $0.participantID == participantID }) else { return }
        share.removeParticipant(participant)
        _ = try await database(for: location).save(share)
    }

    func hasInvitationAccess(participantID: String, in location: CloudLocation) async throws -> Bool {
        let share = try await share(for: location, title: "Earned It Family")
        return share.currentUserParticipant?.participantID == participantID
    }

    func invitationValidationTime(in location: CloudLocation, clientTime: Date) async throws -> Date {
        familyTransitionDiagnostics.record(stage: .validationTimeWrite, outcome: .started,
                                            householdID: location.householdID)
        let database = database(for: location)
        let recordID = CKRecord.ID(zoneID: zoneID(for: location))
        let record = CKRecord(recordType: "InvitationValidationTime", recordID: recordID)
        do {
            let results = try await database.modifyRecords(saving: [record], deleting: [],
                                                           savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let result = results.saveResults[record.recordID],
                  let serverTime = try result.get().modificationDate else { throw HouseholdError.cloudUnavailable }
            do { _ = try await database.deleteRecord(withID: record.recordID) } catch {}
            familyTransitionDiagnostics.record(stage: .validationTimeWrite, outcome: .succeeded,
                                                householdID: location.householdID)
            return serverTime
        } catch {
            familyTransitionDiagnostics.record(stage: .validationTimeWrite, outcome: .failed,
                                                householdID: location.householdID, error: error)
            throw error
        }
    }

    func claimInvitation(_ facts: [HouseholdFact], in location: CloudLocation) async throws -> [HouseholdFact] {
        guard facts.count == 2,
              facts.allSatisfy({ if case .invitationClaim = $0.body { return true }; return false }) else {
            throw HouseholdError.malformedData
        }
        let records = try facts.map { try Self.record(for: $0, location: location) }
        let database = database(for: location)
        do {
            let results = try await database.modifyRecords(
                saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
            )
            for (fact, record) in zip(facts, records) {
                guard let result = results.saveResults[record.recordID],
                      Self.isSameInvitationClaim(try Self.decode(result.get()), as: fact) else {
                    throw HouseholdError.invitationConsumed
                }
            }
            return facts
        } catch {
            var missing: [HouseholdFact] = []
            for fact in facts {
                let id = CKRecord.ID(recordName: fact.id.uuidString, zoneID: zoneID(for: location))
                do {
                    let existing = try Self.decode(try await database.record(for: id))
                    guard Self.isSameInvitationClaim(existing, as: fact) else {
                        throw HouseholdError.invitationConsumed
                    }
                } catch let cloudError as CKError where cloudError.code == .unknownItem {
                    missing.append(fact)
                }
            }
            guard !missing.isEmpty else { return facts }
            let missingRecords = try missing.map { try Self.record(for: $0, location: location) }
            do {
                let results = try await database.modifyRecords(
                    saving: missingRecords, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
                )
                for (fact, record) in zip(missing, missingRecords) {
                    guard let result = results.saveResults[record.recordID],
                          Self.isSameInvitationClaim(try Self.decode(result.get()), as: fact) else {
                        throw HouseholdError.invitationConsumed
                    }
                }
                return facts
            } catch let cloudError as CKError where Self.isInvitationClaimConflict(
                cloudError, recordIDs: Set(missingRecords.map(\.recordID))
            ) {
                throw HouseholdError.invitationConsumed
            }
        }
    }

    func canWrite(to location: CloudLocation) async throws -> Bool {
        if location.isOwner { return true }
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(for: location))
        guard let share = try await container.sharedCloudDatabase.record(for: id) as? CKShare else {
            throw HouseholdError.invitation
        }
        return share.currentUserParticipant?.permission == .readWrite
    }

    func ownerTransitionPreflight(targetHouseholdID: UUID, localSession: DeviceSession,
                                  localFacts: [HouseholdFact], localPendingFactCount: Int) async
        -> OwnerTransitionPreflightSnapshot {
        let startingGeneration = accountGeneration
        var snapshot = OwnerTransitionPreflightSnapshot()
        snapshot.localFactCount = localFacts.count
        snapshot.localPendingFactCount = localPendingFactCount
        if let location = localSession.location {
            if location.householdID != targetHouseholdID {
                snapshot.localLocationState = .otherHousehold
            } else {
                snapshot.localLocationState = location.isOwner ? .ownerForTarget : .sharedForTarget
            }
        }

        var participant: String?
        do {
            let observedParticipant = try await participantID()
            participant = observedParticipant
            snapshot.accountMatchesLocalParticipant = localSession.cloudParticipantID.map {
                $0 == observedParticipant
            }
        } catch {
            snapshot.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
        }

        do {
            if let lock = try await accountMembershipLock() {
                snapshot.lockState = lock.state
                snapshot.lockMatchesTargetHousehold = lock.householdID == targetHouseholdID
                snapshot.lockMatchesOtherHousehold = lock.householdID != targetHouseholdID
                snapshot.lockAttemptMatchesLocal = localSession.accountMembershipLockAttemptID.map {
                    $0 == lock.attemptID
                }
                snapshot.lockBindingMatchesTargetOwner = lock.claimBinding.map {
                    $0 == AccountMembershipBinding.owner(householdID: targetHouseholdID)
                }
                snapshot.lockOwnerAuthorityMatchesTargetOwner = lock.ownerAuthorityBinding.map { binding in
                    participant.map { binding == AccountMembershipBinding.ownerAuthority(participantID: $0) }
                        ?? false
                }
            } else {
                snapshot.lockMatchesTargetHousehold = false
                snapshot.lockMatchesOtherHousehold = false
            }
        } catch {
            snapshot.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
        }

        if let participant {
            do {
                snapshot.lifecycleState = try await readFamilyLifecycleAuthority(
                    householdID: targetHouseholdID,
                    ownerAuthorityBinding: AccountMembershipBinding.ownerAuthority(participantID: participant)
                )
            } catch {
                snapshot.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
            }
        }

        var targetLocation: CloudLocation?
        do {
            let expectedZoneName = zonePrefix + targetHouseholdID.uuidString
            let zone = try await container.privateCloudDatabase.allRecordZones().first {
                $0.zoneID.zoneName == expectedZoneName
            }
            snapshot.cloudTargetZoneExists = zone != nil
            if let zone {
                targetLocation = CloudLocation(householdID: targetHouseholdID,
                                               zoneName: zone.zoneID.zoneName,
                                               ownerName: zone.zoneID.ownerName, isOwner: true)
            }
        } catch {
            snapshot.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
        }

        if let targetLocation {
            do {
                let facts = try await readFacts(from: targetLocation)
                applyFactCounts(facts, to: &snapshot)
            } catch {
                snapshot.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
            }
            do {
                let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(for: targetLocation))
                if let share = try await container.privateCloudDatabase.record(for: id) as? CKShare {
                    snapshot.shareExists = true
                    snapshot.shareParticipantCount = share.participants.count
                    snapshot.pendingShareParticipantCount = share.participants.filter {
                        $0.acceptanceStatus == .pending
                    }.count
                    snapshot.acceptedShareParticipantCount = share.participants.filter {
                        $0.acceptanceStatus == .accepted
                    }.count
                } else {
                    snapshot.shareExists = nil
                }
            } catch let error as CKError where error.code == .unknownItem {
                snapshot.shareExists = false
                snapshot.shareParticipantCount = 0
                snapshot.pendingShareParticipantCount = 0
                snapshot.acceptedShareParticipantCount = 0
            } catch {
                snapshot.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
            }
        } else if snapshot.cloudTargetZoneExists == false {
            snapshot.cloudFactCount = 0
            snapshot.householdRootFactCount = 0
            snapshot.memberFactCount = 0
            snapshot.shareExists = false
            snapshot.shareParticipantCount = 0
            snapshot.pendingShareParticipantCount = 0
            snapshot.acceptedShareParticipantCount = 0
            snapshot.invitationReferenceCount = 0
            snapshot.invitationClaimCount = 0
            snapshot.invitationRevocationCount = 0
            snapshot.childMemberCount = 0
            snapshot.childInvitationCount = 0
            snapshot.childClaimCount = 0
            snapshot.childGrantReferenceCount = 0
            snapshot.exactChildRecoveryBindingCount = 0
        }
        if let participant {
            do {
                let finalParticipant = try await participantID()
                snapshot.accountGenerationStable = accountGeneration == startingGeneration
                    && finalParticipant == participant
            } catch {
                snapshot.accountGenerationStable = false
                snapshot.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
            }
        }
        return snapshot
    }

    func childRecoveryPreflight(localSession: DeviceSession, localFacts: [HouseholdFact]) async
        -> ChildRecoveryPreflightSnapshot {
        let startingGeneration = accountGeneration
        var result = ChildRecoveryPreflightSnapshot()
        result.localFactCount = localFacts.count
        var participant: String?
        do {
            participant = try await participantID()
            result.accountMatchesLocalParticipant = localSession.cloudParticipantID.map { $0 == participant }
        } catch {
            result.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
        }

        var lock: AccountMembershipLock?
        var lockReadCompleted = false
        do {
            lock = try await accountMembershipLock()
            lockReadCompleted = true
            result.furthestStage = .membershipLock
        } catch {
            result.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
        }
        guard lockReadCompleted else {
            result.result = .membershipLockUnavailable
            if let participant {
                do {
                    let finalParticipant = try await participantID()
                    result.accountGenerationStable = accountGeneration == startingGeneration
                        && finalParticipant == participant
                } catch {
                    result.accountGenerationStable = false
                    result.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
                }
            }
            return result
        }
        guard let lock else {
            result.result = .lockMissing
            if let participant {
                do {
                    let finalParticipant = try await participantID()
                    result.accountGenerationStable = accountGeneration == startingGeneration
                        && finalParticipant == participant
                } catch {
                    result.accountGenerationStable = false
                    result.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
                }
            }
            return result
        }
        result.lockState = lock.state
        result.lockMatchesLocalHousehold = localSession.householdID.map { $0 == lock.householdID }
        result.lockAttemptMatchesLocal = localSession.accountMembershipLockAttemptID.map { $0 == lock.attemptID }
        result.lockBindingMatchesLocal = localSession.accountMembershipClaimBinding.map { $0 == lock.claimBinding }
        result.lockHasOwnerAuthorityBinding = lock.ownerAuthorityBinding != nil
        if participant != nil, let ownerAuthorityBinding = lock.ownerAuthorityBinding {
            do {
                result.lifecycleState = try await readFamilyLifecycleAuthority(
                    householdID: lock.householdID,
                    ownerAuthorityBinding: ownerAuthorityBinding
                )
            } catch {
                result.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
            }
        }
        if let location = localSession.location {
            if location.householdID != lock.householdID {
                result.localLocationState = .otherHousehold
            } else {
                result.localLocationState = location.isOwner ? .ownerForTarget : .sharedForTarget
            }
        }

        let expectedZoneName = zonePrefix + lock.householdID.uuidString
        var location: CloudLocation?
        var sharedZoneReadCompleted = false
        do {
            let zone = try await container.sharedCloudDatabase.allRecordZones().first {
                $0.zoneID.zoneName == expectedZoneName
            }
            sharedZoneReadCompleted = true
            result.sharedZoneExists = zone != nil
            result.furthestStage = .sharedZone
            if let zone {
                location = CloudLocation(householdID: lock.householdID,
                                         zoneName: zone.zoneID.zoneName,
                                         ownerName: zone.zoneID.ownerName, isOwner: false)
            }
        } catch {
            result.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
        }
        guard sharedZoneReadCompleted else {
            result.result = .sharedZoneUnavailable
            if let participant {
                do {
                    let finalParticipant = try await participantID()
                    result.accountGenerationStable = accountGeneration == startingGeneration
                        && finalParticipant == participant
                } catch {
                    result.accountGenerationStable = false
                    result.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
                }
            }
            return result
        }
        guard let location else {
            result.result = lock.state == .released ? .lockReleased : .sharedZoneMissing
            if let participant {
                do {
                    let finalParticipant = try await participantID()
                    result.accountGenerationStable = accountGeneration == startingGeneration
                        && finalParticipant == participant
                } catch {
                    result.accountGenerationStable = false
                    result.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
                }
            }
            return result
        }

        var imported: HouseholdSnapshot?
        do {
            let facts = try await readFacts(from: location)
            imported = HouseholdSnapshot(facts: facts)
            result.cloudFactCount = facts.count
            result.householdRootFactCount = facts.filter {
                if case .household = $0.body { return true }
                return false
            }.count
            result.memberFactCount = facts.filter {
                if case .member = $0.body { return true }
                return false
            }.count
            result.invitationReferenceCount = imported?.invitations.count
            result.invitationClaimCount = imported?.invitationClaims.count
            result.invitationRevocationCount = imported?.invitationRevocations.count
            result.furthestStage = .journal
        } catch {
            result.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
            result.result = .journalUnavailable
        }

        do {
            let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(for: location))
            if let share = try await container.sharedCloudDatabase.record(for: id) as? CKShare {
                result.shareExists = true
                result.currentParticipantPresentOnShare = share.currentUserParticipant != nil
                result.currentParticipantCanWrite = share.currentUserParticipant?.permission == .readWrite
            }
            result.furthestStage = .share
        } catch let error as CKError where error.code == .unknownItem {
            result.shareExists = false
            result.currentParticipantPresentOnShare = false
            result.currentParticipantCanWrite = false
            result.furthestStage = .share
        } catch {
            result.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
        }

        if let imported, let participant {
            do {
                let membership = try imported.committedAccountMembership(participantID: participant)
                result.committedExactMembershipPresent = membership != nil
                result.exactMemberMatchesLocalSelection = membership.map {
                    $0.member.id == localSession.selectedMemberID
                }
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
        }
        if result.accountMatchesLocalParticipant == false { result.result = .accountUnavailable }
        if let participant {
            do {
                let finalParticipant = try await participantID()
                result.accountGenerationStable = accountGeneration == startingGeneration
                    && finalParticipant == participant
            } catch {
                result.accountGenerationStable = false
                result.cloudErrors += FamilyTransitionDiagnostics.cloudErrors(from: error)
            }
        }
        return result
    }

    private func applyFactCounts(_ facts: [HouseholdFact], to result: inout OwnerTransitionPreflightSnapshot) {
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

    private static func decode(_ record: CKRecord) throws -> HouseholdFact {
        guard (record["formatVersion"] as? Int) == 1, let payload = record["payload"] as? Data else {
            throw HouseholdError.malformedData
        }
        let fact = try JSONDecoder().decode(HouseholdFact.self, from: payload)
        guard record.recordID.recordName == fact.id.uuidString else { throw HouseholdError.malformedData }
        return fact
    }

    private static func record(for fact: HouseholdFact, location: CloudLocation) throws -> CKRecord {
        let zoneID = CKRecordZone.ID(zoneName: location.zoneName, ownerName: location.ownerName)
        let record = CKRecord(recordType: "HouseholdFact",
                              recordID: CKRecord.ID(recordName: fact.id.uuidString, zoneID: zoneID))
        let data = try JSONEncoder().encode(fact)
        guard data.count < 900_000 else { throw HouseholdError.malformedData }
        record["payload"] = data as CKRecordValue
        record["formatVersion"] = 1 as CKRecordValue
        return record
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

    private func oneTimeURL(in share: CKShare, participantID: CKShare.Participant.ID) -> URL? {
        if #available(iOS 26.0, *) { return share.oneTimeURL(for: participantID) }
        let selector = NSSelectorFromString("oneTimeURLForParticipantID:")
        return share.perform(selector, with: participantID)?.takeUnretainedValue() as? URL
    }

    private func updateFamilyLifecycleAuthority(
        householdID: UUID,
        expectedParticipantID: String,
        stage: FamilyTransitionDiagnosticStage,
        transition: (FamilyLifecycleState?) throws -> FamilyLifecycleState
    ) async throws -> FamilyLifecycleState {
        let expectedGeneration = accountGeneration
        let ownerAuthorityBinding = AccountMembershipBinding.ownerAuthority(participantID: expectedParticipantID)
        let recordID = familyLifecycleRecordID(householdID: householdID)
        let database = container.publicCloudDatabase
        familyTransitionDiagnostics.record(stage: stage, outcome: .started, householdID: householdID)
        do {
            for attempt in 1...4 {
                try await requireAccount(expectedParticipantID, generation: expectedGeneration)
                let existingRecord: CKRecord?
                let existingState: FamilyLifecycleState?
                do {
                    let record = try await database.record(for: recordID)
                    let comparison = familyLifecycleAuthorityComparison(
                        record,
                        ownerAuthorityBinding: ownerAuthorityBinding
                    )
                    familyTransitionDiagnostics.recordLifecycleAuthority(
                        attempt: attempt,
                        phase: .existingFetch,
                        result: comparison.isAccepted ? .recordAccepted : .recordRejected,
                        comparison: comparison
                    )
                    existingState = try decodeFamilyLifecycleAuthority(comparison)
                    existingRecord = record
                } catch let error as CKError where Self.isRecordMissing(error, recordID: recordID) {
                    familyTransitionDiagnostics.recordLifecycleAuthority(
                        attempt: attempt,
                        phase: .existingFetch,
                        result: .recordAbsent
                    )
                    existingRecord = nil
                    existingState = nil
                }
                let next = try transition(existingState)
                if next == existingState {
                    try await requireAccount(expectedParticipantID, generation: expectedGeneration)
                    familyTransitionDiagnostics.record(stage: stage, outcome: .succeeded,
                                                        householdID: householdID)
                    return next
                }
                let record = existingRecord
                    ?? CKRecord(recordType: familyLifecycleRecordType, recordID: recordID)
                record["formatVersion"] = 1 as CKRecordValue
                record["state"] = next.rawValue as CKRecordValue
                do {
                    try await requireAccount(expectedParticipantID, generation: expectedGeneration)
                    let results = try await database.modifyRecords(
                        saving: [record],
                        deleting: [],
                        savePolicy: .ifServerRecordUnchanged,
                        atomically: true
                    )
                    try await requireAccount(expectedParticipantID, generation: expectedGeneration)
                    let comparison = try Self.familyLifecycleAuthoritySaveComparison(
                        recordID: recordID,
                        saveResults: results.saveResults,
                        comparison: { saved in
                            self.familyLifecycleAuthorityComparison(
                                saved,
                                ownerAuthorityBinding: ownerAuthorityBinding
                            )
                        }
                    )
                    let stateMatchesRequested = comparison.isAccepted
                        ? comparison.state.map { $0 == next } : nil
                    let result: InvitationLifecycleAuthorityResult
                    if !comparison.isAccepted {
                        result = .recordRejected
                    } else if stateMatchesRequested == true {
                        result = .recordAccepted
                    } else {
                        result = .savedStateMismatch
                    }
                    familyTransitionDiagnostics.recordLifecycleAuthority(
                        attempt: attempt,
                        phase: .save,
                        result: result,
                        comparison: comparison,
                        stateMatchesRequested: stateMatchesRequested
                    )
                    let savedState = try Self.confirmFamilyLifecycleAuthoritySave(
                        comparison,
                        requestedState: next
                    )
                    try await requireAccount(expectedParticipantID, generation: expectedGeneration)
                    familyTransitionDiagnostics.record(stage: stage, outcome: .succeeded,
                                                        householdID: householdID)
                    return savedState
                } catch let error as CKError
                    where Self.shouldRetryLifecycleAuthorityBootstrap(error, recordID: recordID) {
                    familyTransitionDiagnostics.recordLifecycleAuthority(
                        attempt: attempt,
                        phase: .save,
                        result: .retryableCloudError,
                        error: error
                    )
                    continue
                }
            }
            familyTransitionDiagnostics.recordLifecycleAuthority(
                attempt: 4,
                phase: .terminal,
                result: .retriesExhausted
            )
            throw HouseholdError.accountMembershipConflict
        } catch {
            familyTransitionDiagnostics.record(stage: stage, outcome: .failed,
                                                householdID: householdID, error: error)
            throw error
        }
    }

    private func decodeFamilyLifecycleAuthority(
        _ record: CKRecord,
        ownerAuthorityBinding: String
    ) throws -> FamilyLifecycleState {
        try decodeFamilyLifecycleAuthority(familyLifecycleAuthorityComparison(
            record,
            ownerAuthorityBinding: ownerAuthorityBinding
        ))
    }

    private func decodeFamilyLifecycleAuthority(
        _ comparison: InvitationLifecycleAuthorityRecordComparison
    ) throws -> FamilyLifecycleState {
        guard comparison.isAccepted, let state = comparison.state else {
            throw HouseholdError.accountMembershipConflict
        }
        return state
    }

    private func familyLifecycleAuthorityComparison(
        _ record: CKRecord,
        ownerAuthorityBinding: String
    ) -> InvitationLifecycleAuthorityRecordComparison {
        let formatVersion = (record["formatVersion"] as? NSNumber)?.intValue
            ?? record["formatVersion"] as? Int
        return Self.familyLifecycleAuthorityComparison(
            recordTypeMatches: record.recordType == familyLifecycleRecordType,
            formatVersion: formatVersion,
            rawState: record["state"] as? String,
            creatorParticipantID: record.creatorUserRecordID?.recordName,
            modifierParticipantID: record.lastModifiedUserRecordID?.recordName,
            ownerAuthorityBinding: ownerAuthorityBinding
        )
    }

    static func familyLifecycleAuthorityComparison(
        recordTypeMatches: Bool,
        formatVersion: Int?,
        rawState: String?,
        creatorParticipantID: String?,
        modifierParticipantID: String?,
        ownerAuthorityBinding: String
    ) -> InvitationLifecycleAuthorityRecordComparison {
        let creatorMatches = creatorParticipantID.map {
            AccountMembershipBinding.ownerAuthority(participantID: $0) == ownerAuthorityBinding
        }
        let modifierMatches = modifierParticipantID.map {
            AccountMembershipBinding.ownerAuthority(participantID: $0) == ownerAuthorityBinding
        }
        let state = rawState.flatMap(FamilyLifecycleState.init(rawValue:))
        return InvitationLifecycleAuthorityRecordComparison(
            recordTypeMatches: recordTypeMatches,
            formatVersionMatches: formatVersion == 1,
            state: state,
            stateRecognized: state != nil,
            creatorPresent: creatorParticipantID != nil,
            creatorMatchesCurrentAccount: creatorMatches,
            modifierPresent: modifierParticipantID != nil,
            modifierMatchesCurrentAccount: modifierMatches
        )
    }

    static func familyLifecycleAuthoritySaveComparison(
        recordID: CKRecord.ID,
        saveResults: [CKRecord.ID: Result<CKRecord, Error>],
        comparison: (CKRecord) -> InvitationLifecycleAuthorityRecordComparison
    ) throws -> InvitationLifecycleAuthorityRecordComparison {
        guard let saveResult = saveResults[recordID] else { throw HouseholdError.malformedData }
        let saved = try saveResult.get()
        guard saved.recordID == recordID else { throw HouseholdError.accountMembershipConflict }
        return comparison(saved)
    }

    static func confirmFamilyLifecycleAuthoritySave(
        _ comparison: InvitationLifecycleAuthorityRecordComparison,
        requestedState: FamilyLifecycleState
    ) throws -> FamilyLifecycleState {
        guard comparison.isAccepted,
              comparison.state == requestedState else {
            throw HouseholdError.accountMembershipConflict
        }
        return requestedState
    }

    private func readFamilyLifecycleAuthority(
        householdID: UUID,
        ownerAuthorityBinding: String
    ) async throws -> FamilyLifecycleState? {
        let recordID = familyLifecycleRecordID(householdID: householdID)
        do {
            let record = try await container.publicCloudDatabase.record(for: recordID)
            return try decodeFamilyLifecycleAuthority(record, ownerAuthorityBinding: ownerAuthorityBinding)
        } catch let error as CKError where Self.isRecordMissing(error, recordID: recordID) {
            return nil
        }
    }

    private func familyLifecycleRecordID(householdID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: AccountMembershipBinding.lifecycleRecordName(householdID: householdID))
    }

    private func requireAccount(_ expectedParticipantID: String, generation: UInt64) async throws {
        try Task.checkCancellation()
        guard accountGeneration == generation,
              try await participantID() == expectedParticipantID else { throw HouseholdError.wrongAccount }
        try Task.checkCancellation()
    }

    private func updateAccountMembershipLock(
        expectedParticipantID: String? = nil,
        expectedGeneration: UInt64? = nil,
        _ update: (AccountMembershipLock?) throws -> AccountMembershipLock
    ) async throws -> AccountMembershipLock {
        let database = container.privateCloudDatabase
        let recordID = CKRecord.ID(recordName: accountMembershipRecordName)
        for _ in 0..<4 {
            var record: CKRecord
            let existing: AccountMembershipLock?
            do {
                record = try await database.record(for: recordID)
                existing = try decodeAccountMembershipLock(record)
            } catch let error as CKError where Self.isRecordMissing(error, recordID: recordID) {
                record = CKRecord(recordType: accountMembershipRecordType, recordID: recordID)
                existing = nil
            }
            let next = try update(existing)
            record["payload"] = try JSONEncoder().encode(next) as CKRecordValue
            record["formatVersion"] = 1 as CKRecordValue
            do {
                try Task.checkCancellation()
                if let expectedParticipantID,
                   try await participantID() != expectedParticipantID { throw HouseholdError.wrongAccount }
                try Task.checkCancellation()
                if let expectedGeneration,
                   accountGeneration != expectedGeneration { throw HouseholdError.wrongAccount }
                try await enqueueModifyRecords(saving: [record], deleting: [], in: database)
                try Task.checkCancellation()
                if let expectedGeneration,
                   accountGeneration != expectedGeneration { throw HouseholdError.wrongAccount }
                if let expectedParticipantID,
                   try await participantID() != expectedParticipantID { throw HouseholdError.wrongAccount }
                return next
            } catch let error as CKError {
                guard Self.isAccountMembershipRecordConflict(error, recordID: recordID) else { throw error }
                continue
            }
        }
        throw HouseholdError.accountMembershipConflict
    }

    private enum AccountMembershipLockUpdateError: Error {
        case expectedLockMismatch
    }

    private func enqueueModifyRecords(saving records: [CKRecord], deleting recordIDs: [CKRecord.ID],
                                      in database: CKDatabase) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: recordIDs)
            operation.savePolicy = .ifServerRecordUnchanged
            operation.isAtomic = true
            operation.modifyRecordsResultBlock = { continuation.resume(with: $0) }
            database.add(operation)
        }
    }

    nonisolated static func isAccountMembershipRecordConflict(_ error: CKError,
                                                               recordID: CKRecord.ID) -> Bool {
        isRecordConflict(error, recordID: recordID)
    }

    nonisolated static func isRecordConflict(_ error: CKError, recordID: CKRecord.ID) -> Bool {
        if error.code == .serverRecordChanged { return true }
        guard error.code == .partialFailure,
              let partial = error.partialErrorsByItemID?[recordID] as? CKError else { return false }
        return partial.code == CKError.Code.serverRecordChanged
    }

    nonisolated static func shouldRetryLifecycleAuthorityBootstrap(
        _ error: CKError,
        recordID: CKRecord.ID
    ) -> Bool {
        isRecordConflict(error, recordID: recordID) || isRecordMissing(error, recordID: recordID)
    }

    nonisolated static func isRecordMissing(_ error: CKError, recordID: CKRecord.ID) -> Bool {
        if error.code == .unknownItem { return true }
        guard error.code == .partialFailure,
              let partial = error.partialErrorsByItemID?[recordID] as? CKError else { return false }
        return partial.code == .unknownItem
    }

    nonisolated static func isInvitationClaimConflict(_ error: CKError,
                                                       recordIDs: Set<CKRecord.ID>) -> Bool {
        if error.code == .serverRecordChanged { return true }
        guard error.code == .partialFailure else { return false }
        let errors = recordIDs.compactMap { error.partialErrorsByItemID?[$0] as? CKError }
        return errors.contains { $0.code == .serverRecordChanged }
            && errors.allSatisfy { $0.code == .serverRecordChanged || $0.code == .batchRequestFailed }
    }

    private func decodeAccountMembershipLock(_ record: CKRecord) throws -> AccountMembershipLock {
        guard record.recordType == accountMembershipRecordType,
              (record["formatVersion"] as? Int) == 1,
              let payload = record["payload"] as? Data else { throw HouseholdError.malformedData }
        return try JSONDecoder().decode(AccountMembershipLock.self, from: payload)
    }

    private func resetRecords(
        recordType: String,
        predicate: NSPredicate,
        database: CKDatabase,
        zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: predicate)
        var records: [CKRecord] = []
        do {
            var page = try await database.records(
                matching: query,
                inZoneWith: zoneID,
                desiredKeys: []
            )
            while true {
                records += try Self.availableResetRecords(page.matchResults.map(\.1))
                guard let cursor = page.queryCursor else { return records }
                page = try await database.records(continuingMatchFrom: cursor, desiredKeys: [])
            }
        } catch let error as CKError where error.code == .unknownItem {
            return []
        }
    }

    nonisolated static func availableResetRecords(
        _ results: [Result<CKRecord, Error>]
    ) throws -> [CKRecord] {
        try results.compactMap { result in
            do { return try result.get() }
            catch let error as CKError where error.code == .unknownItem { return nil }
        }
    }

    private func isEarnedItZone(_ zoneID: CKRecordZone.ID) -> Bool {
        guard zoneID.zoneName.hasPrefix(zonePrefix) else { return false }
        return UUID(uuidString: String(zoneID.zoneName.dropFirst(zonePrefix.count))) != nil
    }

    private func database(for location: CloudLocation) -> CKDatabase {
        location.isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    private func zoneID(for location: CloudLocation) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: location.zoneName, ownerName: location.ownerName)
    }

    private func location(zoneID: CKRecordZone.ID, isOwner: Bool) -> CloudLocation? {
        guard zoneID.zoneName.hasPrefix(zonePrefix),
              let id = UUID(uuidString: String(zoneID.zoneName.dropFirst(zonePrefix.count))) else { return nil }
        return CloudLocation(householdID: id, zoneName: zoneID.zoneName, ownerName: zoneID.ownerName, isOwner: isOwner)
    }
}

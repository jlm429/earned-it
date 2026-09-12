import Foundation
import CloudKit

/// Explicit CloudKit transport. SwiftData's automatic mirroring is disabled.
@MainActor
final class CloudKitHouseholdTransport: HouseholdTransport {
    nonisolated static let containerIdentifier = "iCloud.com.jlm429.EarnedIt"
    let container: CKContainer
    private let zonePrefix = "EarnedIt-"
    private let recordType = "HouseholdFact"

    init(container: CKContainer = CKContainer(identifier: containerIdentifier)) {
        self.container = container
    }

    func participantID() async throws -> String {
        guard try await container.accountStatus() == .available else { throw HouseholdError.cloudUnavailable }
        return try await container.userRecordID().recordName
    }

    func createZone(for household: Household) async throws -> CloudLocation {
        let zone = CKRecordZone(zoneName: zonePrefix + household.id.uuidString)
        _ = try await container.privateCloudDatabase.save(zone)
        return CloudLocation(householdID: household.id, zoneName: zone.zoneID.zoneName,
                             ownerName: zone.zoneID.ownerName, isOwner: true)
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
        guard url.scheme == "https", let host = url.host,
              host == "icloud.com" || host.hasSuffix(".icloud.com") else {
            throw HouseholdError.invitationUnavailable
        }
        do {
            let metadatas = try await container.shareMetadatas(for: [url])
            guard let metadata = try metadatas[url]?.get() else { throw HouseholdError.invitationUnavailable }
            return try await accept(metadata: metadata)
        } catch let error as CKError where error.code == .unknownItem || error.code == .permissionFailure {
            throw HouseholdError.invitationUnavailable
        }
    }

    func accept(metadata: CKShare.Metadata) async throws -> CloudLocation {
        guard metadata.containerIdentifier == Self.containerIdentifier,
              metadata.share.recordID.recordName == CKRecordNameZoneWideShare,
              let location = location(zoneID: metadata.share.recordID.zoneID, isOwner: metadata.participantRole == .owner) else {
            throw HouseholdError.invitation
        }
        if metadata.participantRole != .owner && metadata.participantStatus != .accepted {
            let accepted = try await container.accept([metadata])
            guard let result = accepted[metadata] else { throw HouseholdError.invitation }
            _ = try result.get()
        }
        return location
    }

    func leave(_ location: CloudLocation) async throws {
        guard !location.isOwner else { return }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(for: location))
        do { _ = try await container.sharedCloudDatabase.deleteRecord(withID: shareID) }
        catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {}
    }

    func fetch(from location: CloudLocation) async throws -> [HouseholdFact] {
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
        let database = database(for: location)
        try await Self.uploadConfirmed(facts, to: location) { record in
            let results = try await database.modifyRecords(saving: [record], deleting: [],
                                                           savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let result = results.saveResults[record.recordID] else { throw HouseholdError.malformedData }
            return try result.get()
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
        do {
            guard let share = try await database(for: location).record(for: id) as? CKShare else {
                throw HouseholdError.malformedData
            }
            return share
        } catch let error as CKError where error.code == .unknownItem {
            guard location.isOwner else { throw HouseholdError.invitation }
            let share = CKShare(recordZoneID: zoneID(for: location))
            share.publicPermission = .none
            share[CKShare.SystemFieldKey.title] = title as CKRecordValue
            guard let saved = try await container.privateCloudDatabase.save(share) as? CKShare else {
                throw HouseholdError.malformedData
            }
            return saved
        }
    }

    func createInvitationAccess(for location: CloudLocation, title: String,
                                role: UserRole) async throws -> CloudInvitationAccess {
        let share = try await share(for: location, title: title)
        let mayManage: Bool
        if location.isOwner {
            mayManage = true
        } else if #available(iOS 26.0, *) {
            mayManage = share.currentUserParticipant?.role == .administrator
        } else {
            mayManage = false
        }
        guard mayManage else { throw HouseholdError.invitationOwnerRequired }

        let participant = CKShare.Participant.oneTimeURLParticipant()
        participant.permission = .readWrite
        if role == .parent, #available(iOS 26.0, *) {
            participant.role = .administrator
        } else {
            participant.role = .privateUser
        }
        share.addParticipant(participant)
        guard let saved = try await database(for: location).save(share) as? CKShare,
              let url = oneTimeURL(in: saved, participantID: participant.participantID) else {
            throw HouseholdError.invitation
        }
        return CloudInvitationAccess(participantID: participant.participantID, url: url)
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

    func claimInvitation(_ fact: HouseholdFact, in location: CloudLocation) async throws -> HouseholdFact {
        guard case .invitationClaim = fact.body else { throw HouseholdError.malformedData }
        let record = try Self.record(for: fact, location: location)
        do {
            let results = try await database(for: location).modifyRecords(
                saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
            )
            guard let result = results.saveResults[record.recordID] else { throw HouseholdError.malformedData }
            return try Self.decode(result.get())
        } catch let error as CKError where error.code == .serverRecordChanged {
            if let server = error.serverRecord {
                let serverFact = try Self.decode(server)
                if Self.isSameInvitationClaim(serverFact, as: fact) { return serverFact }
            }
            throw HouseholdError.invitationConsumed
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

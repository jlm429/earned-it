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
              host == "icloud.com" || host.hasSuffix(".icloud.com") else { throw HouseholdError.invitation }
        let metadatas = try await container.shareMetadatas(for: [url])
        guard let metadata = try metadatas[url]?.get() else { throw HouseholdError.invitation }
        return try await accept(metadata: metadata)
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
                let fact = try decode(record)
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
        for offset in stride(from: 0, to: facts.count, by: 100) {
            let batch = Array(facts[offset..<min(offset + 100, facts.count)])
            let records = try batch.map { fact in
                guard fact.householdID == location.householdID else { throw HouseholdError.malformedData }
                let record = CKRecord(recordType: recordType,
                                      recordID: CKRecord.ID(recordName: fact.id.uuidString, zoneID: zoneID(for: location)))
                let data = try JSONEncoder().encode(fact)
                guard data.count < 900_000 else { throw HouseholdError.malformedData }
                record["payload"] = data as CKRecordValue
                record["formatVersion"] = 1 as CKRecordValue
                return record
            }
            let results = try await database.modifyRecords(saving: records, deleting: [],
                                                           savePolicy: .ifServerRecordUnchanged, atomically: false)
            for (index, record) in records.enumerated() {
                guard let result = results.saveResults[record.recordID] else { throw HouseholdError.malformedData }
                do { _ = try result.get() } catch let error as CKError {
                    // Retrying an already accepted immutable fact must not replace its contents.
                    guard error.code == .serverRecordChanged,
                          let server = error.serverRecord, try decode(server) == batch[index] else { throw error }
                }
            }
        }
    }

    func share(for location: CloudLocation, title: String) async throws -> CKShare {
        guard location.isOwner else { throw HouseholdError.permission }
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(for: location))
        do {
            guard let share = try await container.privateCloudDatabase.record(for: id) as? CKShare else {
                throw HouseholdError.malformedData
            }
            return share
        } catch let error as CKError where error.code == .unknownItem {
            let share = CKShare(recordZoneID: zoneID(for: location))
            share.publicPermission = .none
            share[CKShare.SystemFieldKey.title] = title as CKRecordValue
            guard let saved = try await container.privateCloudDatabase.save(share) as? CKShare else {
                throw HouseholdError.malformedData
            }
            return saved
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

    private func decode(_ record: CKRecord) throws -> HouseholdFact {
        guard (record["formatVersion"] as? Int) == 1, let payload = record["payload"] as? Data else {
            throw HouseholdError.malformedData
        }
        let fact = try JSONDecoder().decode(HouseholdFact.self, from: payload)
        guard record.recordID.recordName == fact.id.uuidString else { throw HouseholdError.malformedData }
        return fact
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

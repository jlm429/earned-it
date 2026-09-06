import Foundation
import SwiftData

@MainActor
final class HouseholdRepository {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(url: URL? = nil, inMemory: Bool = false) throws {
        let schema = Schema([StoredFact.self, StoredSession.self])
        let configuration: ModelConfiguration
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        }
        container = try ModelContainer(for: schema, configurations: [configuration])
        context.autosaveEnabled = false
    }

    func session() throws -> DeviceSession {
        if let stored = try context.fetch(FetchDescriptor<StoredSession>()).first {
            return try JSONDecoder().decode(DeviceSession.self, from: stored.payload)
        }
        let session = DeviceSession()
        try commit(facts: [], session: session)
        return session
    }

    func facts(householdID: UUID) throws -> [HouseholdFact] {
        try context.fetch(FetchDescriptor<StoredFact>()).filter { $0.householdID == householdID }.map { try $0.fact() }
    }

    func pending(householdID: UUID, includingRejected: Bool = false) throws -> [HouseholdFact] {
        try context.fetch(FetchDescriptor<StoredFact>()).filter { $0.householdID == householdID && !$0.uploaded && (includingRejected || $0.rejectionReason == nil) }
            .map { try $0.fact() }.sorted(by: HouseholdFact.precedes)
    }

    func rejections(householdID: UUID) throws -> [UUID: String] {
        let stored = try context.fetch(FetchDescriptor<StoredFact>())
        return Dictionary(uniqueKeysWithValues: stored.filter { $0.householdID == householdID && !$0.uploaded }
            .compactMap { fact in fact.rejectionReason.map { (fact.id, $0) } })
    }

    func setRejections(_ reasons: [UUID: String], householdID: UUID) throws {
        do {
            for stored in try context.fetch(FetchDescriptor<StoredFact>()) where stored.householdID == householdID {
                stored.rejectionReason = reasons[stored.id]
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func commit(facts: [HouseholdFact], session: DeviceSession? = nil, uploaded: Bool = false) throws {
        do {
            let existing = try context.fetch(FetchDescriptor<StoredFact>())
            var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            for fact in facts {
                if let stored = byID[fact.id] {
                    guard try stored.fact() == fact else { throw HouseholdError.malformedData }
                    if uploaded { stored.uploaded = true }
                } else {
                    let stored = try StoredFact(fact, uploaded: uploaded)
                    context.insert(stored)
                    byID[fact.id] = stored
                }
            }
            if let session {
                if let stored = try context.fetch(FetchDescriptor<StoredSession>()).first {
                    stored.payload = try JSONEncoder().encode(session)
                } else {
                    context.insert(try StoredSession(session))
                }
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func clearLocalData(retainingRejected: Bool = false) throws {
        do {
            let stored = try context.fetch(FetchDescriptor<StoredFact>())
            let retainedHouseholds = Set(stored.filter { $0.rejectionReason != nil }.map(\.householdID))
            stored.filter { !retainingRejected || !retainedHouseholds.contains($0.householdID) }.forEach(context.delete)
            try context.fetch(FetchDescriptor<StoredSession>()).forEach(context.delete)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

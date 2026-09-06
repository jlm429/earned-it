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
        var facts: [UUID: HouseholdFact] = [:]
    }
    var zones: [String: Zone] = [:]
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
    var beforeCreateZone: (() async -> Void)?

    init(server: TestCloudServer, account: String) { self.server = server; self.account = account }
    func participantID() async throws -> String { account }
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
        guard let zone = server.zones[url.lastPathComponent] else { throw HouseholdError.invitation }
        server.zones[url.lastPathComponent]?.participants.insert(account)
        return CloudLocation(householdID: zone.householdID, zoneName: url.lastPathComponent, ownerName: zone.owner, isOwner: zone.owner == account)
    }
    func accept(metadata: CKShare.Metadata) async throws -> CloudLocation { throw HouseholdError.invitation }
    func fetch(from location: CloudLocation) async throws -> [HouseholdFact] {
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
    func canWrite(to location: CloudLocation) async throws -> Bool { server.writeAllowed }
}

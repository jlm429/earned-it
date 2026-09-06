import Foundation
import CloudKit

struct CloudFamily: Identifiable, Equatable {
    let location: CloudLocation
    let name: String
    var id: String { location.id }
}

/// Production uses the same boundary exercised by the in-memory server in tests.
@MainActor
protocol HouseholdTransport {
    func participantID() async throws -> String
    func createZone(for household: Household) async throws -> CloudLocation
    func discoverFamilies() async throws -> [CloudFamily]
    func accept(url: URL) async throws -> CloudLocation
    func accept(metadata: CKShare.Metadata) async throws -> CloudLocation
    func fetch(from location: CloudLocation) async throws -> [HouseholdFact]
    func upload(_ facts: [HouseholdFact], to location: CloudLocation) async throws
    func share(for location: CloudLocation, title: String) async throws -> CKShare
    func canWrite(to location: CloudLocation) async throws -> Bool
}

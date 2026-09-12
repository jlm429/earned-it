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
    func invitationLocation(for url: URL) async throws -> CloudLocation
    func invitationLocation(for metadata: CKShare.Metadata) throws -> CloudLocation
    func hasAcceptedAccess(to location: CloudLocation) async throws -> Bool
    func accept(url: URL) async throws -> CloudLocation
    func accept(url: URL, expected location: CloudLocation) async throws
    func accept(metadata: CKShare.Metadata) async throws -> CloudLocation
    func accept(metadata: CKShare.Metadata, expected location: CloudLocation) async throws
    func leave(_ location: CloudLocation) async throws
    func fetch(from location: CloudLocation) async throws -> [HouseholdFact]
    func upload(_ facts: [HouseholdFact], to location: CloudLocation) async throws
    func share(for location: CloudLocation, title: String) async throws -> CKShare
    func createInvitationAccess(for location: CloudLocation, title: String, role: UserRole) async throws -> CloudInvitationAccess
    func revokeInvitationAccess(participantID: String, from location: CloudLocation) async throws
    func hasInvitationAccess(participantID: String, in location: CloudLocation) async throws -> Bool
    func claimInvitation(_ fact: HouseholdFact, in location: CloudLocation) async throws -> HouseholdFact
    func canWrite(to location: CloudLocation) async throws -> Bool
}

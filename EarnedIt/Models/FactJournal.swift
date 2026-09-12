import Foundation
import SwiftData

@Model
final class StoredFact {
    @Attribute(.unique) var id: UUID
    var householdID: UUID
    var payload: Data
    var uploaded: Bool
    var rejectionReason: String?

    init(_ fact: HouseholdFact, uploaded: Bool = false) throws {
        id = fact.id
        householdID = fact.householdID
        payload = try JSONEncoder().encode(fact)
        self.uploaded = uploaded
    }

    func fact() throws -> HouseholdFact { try JSONDecoder().decode(HouseholdFact.self, from: payload) }
}

@Model
final class StoredSession {
    @Attribute(.unique) var key: String
    var payload: Data

    init(_ session: DeviceSession) throws {
        key = "device"
        payload = try JSONEncoder().encode(session)
    }
}

struct CloudLocation: Codable, Equatable, Identifiable {
    let householdID: UUID
    let zoneName: String
    let ownerName: String
    let isOwner: Bool
    var id: String { "\(ownerName)/\(zoneName)" }
}

enum PendingInvitationPhase: String, Codable, Equatable {
    case acceptingAccess
    case awaitingRedemption
    case cleanupRequired
}

struct PendingInvitationAcceptance: Codable, Equatable {
    let location: CloudLocation
    let cloudParticipantID: String
    let retainedFactIDs: [UUID]?
    let accessExistedBeforeAttempt: Bool?
    var phase: PendingInvitationPhase
}

struct DeviceSession: Codable, Equatable {
    var deviceID = UUID()
    var householdID: UUID?
    var selectedMemberID: UUID?
    var cloudParticipantID: String?
    var location: CloudLocation?
    var cloudCanWrite: Bool?
    var celebratedWeeks: [String]?
    /// Preserves only the profile selected by an older owner-account installation.
    /// New joins set an empty array and rely on an invitation claim or shared grant.
    var legacyProfileIDs: [UUID]?
    var pendingInvitationAcceptance: PendingInvitationAcceptance?
}

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
    var accountLockAttemptID: UUID?
    var invitationID: UUID?
    var expiresAt: Date?
    var phase: PendingInvitationPhase
}

enum JoinDiagnosticState: String, Codable, Equatable {
    case unknown
    case no
    case yes
}

enum JoinClaimDiagnosticState: String, Codable, Equatable {
    case unknown
    case absent
    case committed
}

enum JoinLockDiagnosticState: String, Codable, Equatable {
    case unknown
    case absent
    case provisional
    case active
    case released
}

enum JoinRootRoute: String, Codable, Equatable {
    case unknown
    case pendingInvitation
    case membershipRecovery
    case onboarding
    case member
    case profileSelection
}

enum JoinFailureStage: String, Codable, Equatable {
    case package
    case metadata
    case nativeAcceptance
    case sharedVisibility
    case exactInvitation
    case claim
    case lock
    case localAttach
}

enum JoinFailureCategory: String, Codable, Equatable {
    case none
    case cancelled
    case cloudKitRetryable
    case cloudKitVisibility
    case cloudKitPermission
    case cloudKitOther
    case invitationRefused
    case accountConflict
    case wrongAccount
    case readOnly
    case other
}

enum JoinRefusalReason: String, Codable, Equatable {
    case invitationRecordMissing
    case memberRecordMissing
    case roleMismatch
    case householdMismatch
    case revoked
    case participantSlotMismatch
    case participantSlotAmbiguous
    case memberInactive
    case alreadyClaimed
    case expired
    case writeUnavailable
    case atomicClaimConflict
}

struct LastJoinReceipt: Codable, Equatable {
    var nativeAcceptance: JoinDiagnosticState = .unknown
    var sharedZoneVisible: JoinDiagnosticState = .unknown
    var claim: JoinClaimDiagnosticState = .unknown
    var lock: JoinLockDiagnosticState = .unknown
    var exactMembership: JoinDiagnosticState = .unknown
    var localAttach: JoinDiagnosticState = .no
    var rootRoute: JoinRootRoute = .unknown
    var failureStage: JoinFailureStage?
    var failureCategory: JoinFailureCategory = .none
    var refusalReason: JoinRefusalReason?
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
    var pendingInvitationPackage: PendingInvitationPackage?
    var accountMembershipLockAttemptID: UUID?
    var accountMembershipClaimBinding: String?
    var lastJoinReceipt: LastJoinReceipt?
    var familyAccessLost: Bool?
    var pendingFamilyDeletion: Bool?
}

import Foundation
import CloudKit

struct CloudFamily: Identifiable, Equatable {
    let location: CloudLocation
    let name: String
    var id: String { location.id }
}

enum AccountMembershipLockState: String, Codable, Equatable {
    case provisional
    case active
    case released
}

enum FamilyLifecycleState: String, Equatable {
    case active
    case deleting
    case deleted
}

struct AccountMembershipLock: Codable, Equatable {
    let householdID: UUID
    let attemptID: UUID
    var state: AccountMembershipLockState
    var expiresAt: Date
    var claimBinding: String?
    var ownerAuthorityBinding: String? = nil
}

/// Production uses the same boundary exercised by the in-memory server in tests.
@MainActor
protocol HouseholdTransport {
    var familyTransitionDiagnostics: FamilyTransitionDiagnostics { get }
    func accountDidChange()
    func participantID() async throws -> String
    func accountMembershipLock() async throws -> AccountMembershipLock?
    func accountMembershipValidationTime(clientTime: Date) async throws -> Date
    func acquireAccountMembershipLock(householdID: UUID, attemptID: UUID,
                                      leaseDuration: TimeInterval, clientTime: Date) async throws
        -> AccountMembershipLock
    func replaceActiveRevokedAccountMembershipLock(
        householdID: UUID,
        revokedAttemptID: UUID,
        revokedClaimBinding: String,
        replacementAttemptID: UUID,
        expectedParticipantID: String,
        leaseDuration: TimeInterval,
        validatedAt: Date
    ) async throws -> AccountMembershipLock
    func activateAccountMembershipLock(householdID: UUID, attemptID: UUID,
                                       claimBinding: String, ownerAuthorityBinding: String,
                                       now: Date) async throws -> AccountMembershipLock
    func releaseAccountMembershipLock(householdID: UUID, attemptID: UUID, expectedParticipantID: String,
                                      now: Date) async throws -> Bool
    func membershipLocation(householdID: UUID) async throws -> CloudLocation?
    func createZone(for household: Household) async throws -> CloudLocation
    func discoverFamilies() async throws -> [CloudFamily]
    func invitationLocation(for url: URL) async throws -> CloudLocation
    func invitationLocation(for metadata: CKShare.Metadata) throws -> CloudLocation
    func hasAcceptedAccess(to location: CloudLocation) async throws -> Bool
    func accept(url: URL) async throws -> CloudLocation
    func accept(url: URL, expected location: CloudLocation) async throws
    func accept(metadata: CKShare.Metadata) async throws -> CloudLocation
    func accept(metadata: CKShare.Metadata, expected location: CloudLocation) async throws
    func leave(_ location: CloudLocation, expectedParticipantID: String) async throws
    func deleteFamilyData(at location: CloudLocation, expectedParticipantID: String) async throws
    func ensureFamilyLifecycleAuthority(householdID: UUID, expectedParticipantID: String) async throws
        -> FamilyLifecycleState
    func beginFamilyDeletion(householdID: UUID, expectedParticipantID: String) async throws
    func finalizeFamilyDeletion(householdID: UUID, expectedParticipantID: String) async throws
    func familyLifecycleState(householdID: UUID, ownerAuthorityBinding: String,
                              expectedParticipantID: String) async throws -> FamilyLifecycleState?
    func fetch(from location: CloudLocation) async throws -> [HouseholdFact]
    func upload(_ facts: [HouseholdFact], to location: CloudLocation) async throws
    func share(for location: CloudLocation, title: String) async throws -> CKShare
    func createInvitationAccess(for location: CloudLocation, title: String, role: UserRole) async throws -> CloudInvitationAccess
    func revokeInvitationAccess(participantID: String, from location: CloudLocation) async throws
    func hasInvitationAccess(participantID: String, in location: CloudLocation) async throws -> Bool
    func invitationValidationTime(in location: CloudLocation, clientTime: Date) async throws -> Date
    func claimInvitation(_ facts: [HouseholdFact], in location: CloudLocation) async throws -> [HouseholdFact]
    func canWrite(to location: CloudLocation) async throws -> Bool
    func ownerTransitionPreflight(targetHouseholdID: UUID, localSession: DeviceSession,
                                  localFacts: [HouseholdFact], localPendingFactCount: Int) async
        -> OwnerTransitionPreflightSnapshot
    func childRecoveryPreflight(localSession: DeviceSession, localFacts: [HouseholdFact]) async
        -> ChildRecoveryPreflightSnapshot
}

import CloudKit
import Foundation
import OSLog

enum FamilyTransitionDiagnosticStage: String, Equatable {
    case preflight
    case childRecoveryPreflight
    case invitationStart
    case participantLookup
    case membershipValidationTimeWrite
    case membershipLockAcquire
    case zoneCreate
    case journalFetch
    case journalUpload
    case membershipLockActivate
    case validationTimeWrite
    case shareFetch
    case shareCreate
    case participantCreate
    case invitationAppend
    case invitationFactUpload
    case completed
}

enum FamilyTransitionDiagnosticOutcome: String, Equatable {
    case started
    case succeeded
    case absent
    case failed
}

enum FamilyTransitionCloudErrorSource: String, Equatable {
    case topLevel
    case partialItem
}

struct FamilyTransitionCloudError: Equatable {
    let code: CKError.Code
    let codeName: String
    let source: FamilyTransitionCloudErrorSource
    let retryAfterSeconds: Double?
    let count: Int
}

enum FamilyTransitionLocationState: String, Equatable {
    case absent
    case ownerForTarget
    case sharedForTarget
    case otherHousehold
}

struct OwnerTransitionPreflightSnapshot: Equatable {
    var lockState: AccountMembershipLockState?
    var lockMatchesTargetHousehold: Bool?
    var lockMatchesOtherHousehold: Bool?
    var lockAttemptMatchesLocal: Bool?
    var lockBindingMatchesTargetOwner: Bool?
    var localLocationState: FamilyTransitionLocationState = .absent
    var cloudTargetZoneExists: Bool?
    var accountMatchesLocalParticipant: Bool?
    var accountGenerationStable: Bool?
    var localFactCount: Int = 0
    var localPendingFactCount: Int = 0
    var cloudFactCount: Int?
    var householdRootFactCount: Int?
    var memberFactCount: Int?
    var shareExists: Bool?
    var shareParticipantCount: Int?
    var pendingShareParticipantCount: Int?
    var acceptedShareParticipantCount: Int?
    var invitationReferenceCount: Int?
    var invitationClaimCount: Int?
    var invitationRevocationCount: Int?
    var childMemberCount: Int?
    var childInvitationCount: Int?
    var childClaimCount: Int?
    var childGrantReferenceCount: Int?
    var exactChildRecoveryBindingCount: Int?
    var cloudErrors: [FamilyTransitionCloudError] = []
}

enum ChildRecoveryReadOnlyStage: String, Equatable {
    case participant
    case membershipLock
    case sharedZone
    case journal
    case share
    case exactMembership
}

enum ChildRecoveryReadOnlyResult: String, Equatable {
    case accountUnavailable
    case lockMissing
    case lockReleased
    case sharedZoneMissing
    case journalUnavailable
    case malformedOrAmbiguousMembership
    case committedMembershipMissing
    case exactMembershipConflictsWithLock
    case exactCommittedMembershipMatchesLock
}

struct ChildRecoveryPreflightSnapshot: Equatable {
    var furthestStage: ChildRecoveryReadOnlyStage = .participant
    var result: ChildRecoveryReadOnlyResult = .accountUnavailable
    var lockState: AccountMembershipLockState?
    var lockMatchesLocalHousehold: Bool?
    var lockAttemptMatchesLocal: Bool?
    var lockBindingMatchesLocal: Bool?
    var localLocationState: FamilyTransitionLocationState = .absent
    var accountMatchesLocalParticipant: Bool?
    var accountGenerationStable: Bool?
    var sharedZoneExists: Bool?
    var shareExists: Bool?
    var currentParticipantPresentOnShare: Bool?
    var currentParticipantCanWrite: Bool?
    var localFactCount: Int = 0
    var cloudFactCount: Int?
    var householdRootFactCount: Int?
    var memberFactCount: Int?
    var invitationReferenceCount: Int?
    var invitationClaimCount: Int?
    var invitationRevocationCount: Int?
    var committedExactMembershipPresent: Bool?
    var exactMemberMatchesLocalSelection: Bool?
    var exactMemberRoleIsChild: Bool?
    var exactBindingMatchesLock: Bool?
    var authoritativeValidationSkipped: Bool = true
    var productionResolveCompleted: Bool = false
    var cloudErrors: [FamilyTransitionCloudError] = []
}

struct FamilyTransitionDiagnosticEvent: Equatable {
    let sequence: Int
    let stage: FamilyTransitionDiagnosticStage
    let outcome: FamilyTransitionDiagnosticOutcome
    let lockState: AccountMembershipLockState?
    let householdMatchesTarget: Bool?
    let attemptMatchesExpected: Bool?
    let participantMatchesExpected: Bool?
    let accountGenerationStable: Bool?
    let factCount: Int?
    let cloudErrors: [FamilyTransitionCloudError]
    let preflight: OwnerTransitionPreflightSnapshot?
    let childRecoveryPreflight: ChildRecoveryPreflightSnapshot?
}

@MainActor
final class FamilyTransitionDiagnostics {
    private static let logger = Logger(subsystem: "com.jlm429.EarnedIt", category: "FamilyTransition")
    private static let eventLimit = 200

    private(set) var events: [FamilyTransitionDiagnosticEvent] = []
    private var targetHouseholdID: UUID?
    private var expectedAttemptID: UUID?
    private var expectedParticipantID: String?

    var isActive: Bool { targetHouseholdID != nil }

    func begin(targetHouseholdID: UUID, localAttemptID: UUID?, localParticipantID: String?) {
        events.removeAll(keepingCapacity: true)
        self.targetHouseholdID = targetHouseholdID
        expectedAttemptID = localAttemptID
        expectedParticipantID = localParticipantID
        record(stage: .invitationStart, outcome: .started)
    }

    func expect(attemptID: UUID? = nil, participantID: String? = nil) {
        if let attemptID { expectedAttemptID = attemptID }
        if let participantID { expectedParticipantID = participantID }
    }

    func record(
        stage: FamilyTransitionDiagnosticStage,
        outcome: FamilyTransitionDiagnosticOutcome,
        lock: AccountMembershipLock? = nil,
        householdID: UUID? = nil,
        attemptID: UUID? = nil,
        participantID: String? = nil,
        accountGenerationStable: Bool? = nil,
        factCount: Int? = nil,
        error: Error? = nil
    ) {
        guard isActive else { return }
        let observedHousehold = lock?.householdID ?? householdID
        let observedAttempt = lock?.attemptID ?? attemptID
        let cloudErrors = error.map(Self.cloudErrors(from:)) ?? []
        let event = FamilyTransitionDiagnosticEvent(
            sequence: events.count + 1,
            stage: stage,
            outcome: outcome,
            lockState: lock?.state,
            householdMatchesTarget: equality(observedHousehold, targetHouseholdID),
            attemptMatchesExpected: equality(observedAttempt, expectedAttemptID),
            participantMatchesExpected: equality(participantID, expectedParticipantID),
            accountGenerationStable: accountGenerationStable,
            factCount: factCount,
            cloudErrors: cloudErrors,
            preflight: nil,
            childRecoveryPreflight: nil
        )
        append(event)
    }

    func record(preflight: OwnerTransitionPreflightSnapshot) {
        guard isActive else { return }
        let event = FamilyTransitionDiagnosticEvent(
            sequence: events.count + 1,
            stage: .preflight,
            outcome: preflight.cloudErrors.isEmpty ? .succeeded : .failed,
            lockState: preflight.lockState,
            householdMatchesTarget: preflight.lockMatchesTargetHousehold,
            attemptMatchesExpected: preflight.lockAttemptMatchesLocal,
            participantMatchesExpected: preflight.accountMatchesLocalParticipant,
            accountGenerationStable: preflight.accountGenerationStable,
            factCount: preflight.cloudFactCount,
            cloudErrors: preflight.cloudErrors,
            preflight: preflight,
            childRecoveryPreflight: nil
        )
        append(event)
    }

    func record(childRecoveryPreflight: ChildRecoveryPreflightSnapshot) {
        guard isActive else { return }
        let event = FamilyTransitionDiagnosticEvent(
            sequence: events.count + 1,
            stage: .childRecoveryPreflight,
            outcome: childRecoveryPreflight.cloudErrors.isEmpty ? .succeeded : .failed,
            lockState: childRecoveryPreflight.lockState,
            householdMatchesTarget: childRecoveryPreflight.lockMatchesLocalHousehold,
            attemptMatchesExpected: childRecoveryPreflight.lockAttemptMatchesLocal,
            participantMatchesExpected: childRecoveryPreflight.accountMatchesLocalParticipant,
            accountGenerationStable: childRecoveryPreflight.accountGenerationStable,
            factCount: childRecoveryPreflight.cloudFactCount,
            cloudErrors: childRecoveryPreflight.cloudErrors,
            preflight: nil,
            childRecoveryPreflight: childRecoveryPreflight
        )
        append(event)
    }

    func finish(outcome: FamilyTransitionDiagnosticOutcome, error: Error? = nil) {
        record(stage: .completed, outcome: outcome, error: error)
        targetHouseholdID = nil
        expectedAttemptID = nil
        expectedParticipantID = nil
    }

    func exportLines() -> [String] { events.map(Self.line(for:)) }

    static func cloudErrors(from error: Error) -> [FamilyTransitionCloudError] {
        guard let cloudError = error as? CKError else { return [] }
        var values = [cloudErrorSummary(cloudError, source: .topLevel)]
        if cloudError.code == .partialFailure {
            values += (cloudError.partialErrorsByItemID ?? [:]).values.compactMap { partial in
                (partial as? CKError).map { cloudErrorSummary($0, source: .partialItem) }
            }
        }
        var result: [FamilyTransitionCloudError] = []
        for value in values {
            if let index = result.firstIndex(where: {
                $0.code == value.code && $0.source == value.source
                    && $0.retryAfterSeconds == value.retryAfterSeconds
            }) {
                let current = result[index]
                result[index] = FamilyTransitionCloudError(
                    code: current.code,
                    codeName: current.codeName,
                    source: current.source,
                    retryAfterSeconds: current.retryAfterSeconds,
                    count: current.count + 1
                )
            } else {
                result.append(value)
            }
        }
        return result.sorted {
            if $0.source != $1.source { return $0.source.rawValue < $1.source.rawValue }
            if $0.code.rawValue != $1.code.rawValue { return $0.code.rawValue < $1.code.rawValue }
            return ($0.retryAfterSeconds ?? -1) < ($1.retryAfterSeconds ?? -1)
        }
    }

    private func append(_ event: FamilyTransitionDiagnosticEvent) {
        if events.count == Self.eventLimit { events.removeFirst() }
        events.append(event)
        Self.logger.notice("\(Self.line(for: event), privacy: .public)")
    }

    private func equality<T: Equatable>(_ lhs: T?, _ rhs: T?) -> Bool? {
        guard let lhs, let rhs else { return nil }
        return lhs == rhs
    }

    private static func cloudErrorSummary(
        _ error: CKError,
        source: FamilyTransitionCloudErrorSource
    ) -> FamilyTransitionCloudError {
        FamilyTransitionCloudError(
            code: error.code,
            codeName: String(describing: error.code),
            source: source,
            retryAfterSeconds: (error.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue,
            count: 1
        )
    }

    private static func line(for event: FamilyTransitionDiagnosticEvent) -> String {
        var fields = [
            "sequence=\(event.sequence)",
            "stage=\(event.stage.rawValue)",
            "outcome=\(event.outcome.rawValue)",
            "lockState=\(event.lockState?.rawValue ?? "unknown")",
            "householdMatchesTarget=\(value(event.householdMatchesTarget))",
            "attemptMatchesExpected=\(value(event.attemptMatchesExpected))",
            "participantMatchesExpected=\(value(event.participantMatchesExpected))",
            "accountGenerationStable=\(value(event.accountGenerationStable))",
            "factCount=\(event.factCount.map { String($0) } ?? "unknown")"
        ]
        if let snapshot = event.preflight {
            fields += [
                "lockMatchesOtherHousehold=\(value(snapshot.lockMatchesOtherHousehold))",
                "lockBindingMatchesTargetOwner=\(value(snapshot.lockBindingMatchesTargetOwner))",
                "localLocationState=\(snapshot.localLocationState.rawValue)",
                "cloudTargetZoneExists=\(value(snapshot.cloudTargetZoneExists))",
                "localFactCount=\(snapshot.localFactCount)",
                "localPendingFactCount=\(snapshot.localPendingFactCount)",
                "householdRootFactCount=\(number(snapshot.householdRootFactCount))",
                "memberFactCount=\(number(snapshot.memberFactCount))",
                "shareExists=\(value(snapshot.shareExists))",
                "shareParticipantCount=\(number(snapshot.shareParticipantCount))",
                "pendingShareParticipantCount=\(number(snapshot.pendingShareParticipantCount))",
                "acceptedShareParticipantCount=\(number(snapshot.acceptedShareParticipantCount))",
                "invitationReferenceCount=\(number(snapshot.invitationReferenceCount))",
                "invitationClaimCount=\(number(snapshot.invitationClaimCount))",
                "invitationRevocationCount=\(number(snapshot.invitationRevocationCount))",
                "childMemberCount=\(number(snapshot.childMemberCount))",
                "childInvitationCount=\(number(snapshot.childInvitationCount))",
                "childClaimCount=\(number(snapshot.childClaimCount))",
                "childGrantReferenceCount=\(number(snapshot.childGrantReferenceCount))",
                "exactChildRecoveryBindingCount=\(number(snapshot.exactChildRecoveryBindingCount))"
            ]
        }
        if let snapshot = event.childRecoveryPreflight {
            fields += [
                "furthestStage=\(snapshot.furthestStage.rawValue)",
                "readOnlyResult=\(snapshot.result.rawValue)",
                "lockBindingMatchesLocal=\(value(snapshot.lockBindingMatchesLocal))",
                "localLocationState=\(snapshot.localLocationState.rawValue)",
                "sharedZoneExists=\(value(snapshot.sharedZoneExists))",
                "shareExists=\(value(snapshot.shareExists))",
                "currentParticipantPresentOnShare=\(value(snapshot.currentParticipantPresentOnShare))",
                "currentParticipantCanWrite=\(value(snapshot.currentParticipantCanWrite))",
                "localFactCount=\(snapshot.localFactCount)",
                "householdRootFactCount=\(number(snapshot.householdRootFactCount))",
                "memberFactCount=\(number(snapshot.memberFactCount))",
                "invitationReferenceCount=\(number(snapshot.invitationReferenceCount))",
                "invitationClaimCount=\(number(snapshot.invitationClaimCount))",
                "invitationRevocationCount=\(number(snapshot.invitationRevocationCount))",
                "committedExactMembershipPresent=\(value(snapshot.committedExactMembershipPresent))",
                "exactMemberMatchesLocalSelection=\(value(snapshot.exactMemberMatchesLocalSelection))",
                "exactMemberRoleIsChild=\(value(snapshot.exactMemberRoleIsChild))",
                "exactBindingMatchesLock=\(value(snapshot.exactBindingMatchesLock))",
                "authoritativeValidationSkipped=\(snapshot.authoritativeValidationSkipped)",
                "productionResolveCompleted=\(snapshot.productionResolveCompleted)"
            ]
        }
        for error in event.cloudErrors {
            let retryAfter = error.retryAfterSeconds.map { String($0) } ?? "none"
            let errorField = "cloudError=\(error.codeName):\(error.code.rawValue):\(error.source.rawValue):"
                + "retryAfter=\(retryAfter):count=\(error.count)"
            fields.append(errorField)
        }
        return "family-transition " + fields.joined(separator: " ")
    }

    private static func value(_ value: Bool?) -> String { value.map { String($0) } ?? "unknown" }
    private static func number(_ value: Int?) -> String { value.map { String($0) } ?? "unknown" }
}

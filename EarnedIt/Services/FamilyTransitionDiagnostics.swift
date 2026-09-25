import CloudKit
import CryptoKit
import Foundation
import OSLog

enum FamilyTransitionDiagnosticStage: String, Equatable {
    case preflight
    case childRecoveryPreflight
    case invitationStart
    case invitationDiagnosticPreamble
    case invitationDiagnosticIdentityRead
    case invitationDiagnosticMembershipLockRead
    case cloudAccountIdentity
    case invitationAccessPruning
    case invitationGeneration
    case zoneConnectionBootstrap
    case initialFactSynchronization
    case preInvitationSynchronization
    case ownerMembershipValidation
    case participantLookup
    case membershipValidationTimeWrite
    case membershipLockRead
    case membershipLockAcquire
    case membershipLockReplace
    case zoneCreate
    case journalFetch
    case journalUpload
    case membershipLockActivate
    case lifecycleAuthorityPrepare
    case lifecycleDeletionPublish
    case lifecycleDeletionCheck
    case validationTimeWrite
    case shareFetch
    case shareCreate
    case shareOwnerValidation
    case invitationAccessOwnerValidation
    case participantCreate
    case invitationStateValidation
    case connectionStateValidation
    case lifecycleAuthorityValidation
    case invitationAppend
    case invitationFactUpload
    case internalErrorCapture
    case userFacingErrorConversion
    case completed
}

enum FamilyTransitionDiagnosticOutcome: String, Equatable {
    case started
    case succeeded
    case absent
    case observed
    case skipped
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
    var domain: String = CKErrorDomain
    var path: String = "topLevel"
}

enum InvitationDiagnosticRelationship: String, Equatable {
    case matches
    case differs
    case missing
    case notApplicable
}

struct InvitationDiagnosticContext: Equatable {
    let correlationID: UUID
    let householdID: UUID
    let currentParentMemberID: UUID?
    let targetMemberID: UUID
    let targetRole: UserRole
    let startedWithCloudLocation: Bool
    let localAcquisitionNoncePresent: Bool
    var cloudKitUserRecordNameSHA256: String?
    var accountGeneration: UInt64
}

struct InvitationExpectedOwnerMembership: Equatable {
    let householdID: UUID
    let memberID: UUID?
    let role: UserRole?
    let ownerLocation: Bool
    let claimBindingKind: String
    let ownerAuthorityDerivedFromCurrentAccount: Bool
}

struct InvitationMembershipLockSnapshot: Equatable {
    let present: Bool
    let householdID: UUID?
    let state: AccountMembershipLockState?
    let accountGeneration: UInt64
    let claimBindingPresent: Bool
    let claimBindingMatchesExpectedOwner: Bool?
    let ownerAuthorityBindingPresent: Bool
    let ownerAuthorityBindingMatchesCurrentAccount: Bool?
    let acquisitionNonceRelationship: InvitationDiagnosticRelationship
}

struct InvitationOwnerMembershipComparison: Equatable {
    let locationIsOwner: Bool
    let sessionHouseholdMatchesLocation: Bool
    let sessionLocationMatches: Bool
    let sessionParticipantMatchesCurrentAccount: Bool
    let selectedMemberPresent: Bool
    let selectedMemberRoleIsParent: Bool
    let selectedMemberExistsAsParentInFetchedJournal: Bool
    let derivedBindingMatchesExpectedOwner: Bool
    let lockHouseholdMatchesLocation: Bool
    let lockStateIsActive: Bool
    let lockClaimBindingPresent: Bool
    let lockClaimBindingMatchesDerivedBinding: Bool
    let lockOwnerAuthorityBindingPresent: Bool
    let lockOwnerAuthorityBindingMatchesCurrentAccount: Bool
    let localClaimBindingPresent: Bool
    let localClaimBindingMatchesDerivedBinding: Bool?

    var permitsActiveOwnerReuse: Bool {
        locationIsOwner
            && sessionHouseholdMatchesLocation
            && sessionLocationMatches
            && sessionParticipantMatchesCurrentAccount
            && selectedMemberPresent
            && selectedMemberRoleIsParent
            && selectedMemberExistsAsParentInFetchedJournal
            && derivedBindingMatchesExpectedOwner
            && lockHouseholdMatchesLocation
            && lockStateIsActive
            && lockClaimBindingPresent
            && lockClaimBindingMatchesDerivedBinding
            && lockOwnerAuthorityBindingPresent
            && lockOwnerAuthorityBindingMatchesCurrentAccount
    }
}

enum InvitationOwnerMembershipBranch: String, Equatable {
    case readOnlyPreambleExactActiveOwnerCandidate
    case readOnlyPreambleRequiresOwnerReconciliation
    case readOnlyPreambleUnavailable
    case noDerivedMembershipBindingValidateRetainedAttempt
    case localClaimBindingConflict
    case reuseExactActiveOwnerMembership
    case validateRetainedAttemptThenAcquire
    case acquireMissingMembershipLock
    case activateMembershipLock
}

enum InvitationLifecycleAuthorityPhase: String, Equatable {
    case existingFetch
    case save
    case verificationFetch
    case terminal
}

enum InvitationLifecycleAuthorityResult: String, Equatable {
    case recordAbsent
    case recordAccepted
    case recordRejected
    case retryableCloudError
    case savedStateMismatch
    case retriesExhausted
}

struct InvitationLifecycleAuthorityRecordComparison: Equatable {
    let recordTypeMatches: Bool
    let formatVersionMatches: Bool
    let state: FamilyLifecycleState?
    let stateRecognized: Bool
    let creatorPresent: Bool
    let creatorMatchesCurrentAccount: Bool?
    let modifierPresent: Bool
    let modifierMatchesCurrentAccount: Bool?
    let identityRepresentation: InvitationLifecycleAuthorityIdentityRepresentation?

    var isAccepted: Bool {
        recordTypeMatches
            && formatVersionMatches
            && stateRecognized
            && creatorMatchesCurrentAccount == true
            && modifierMatchesCurrentAccount == true
    }
}

struct InvitationLifecycleAuthorityIdentityRepresentation: Equatable {
    let expectedCurrentRecordNameIsCurrentUserDefaultName: Bool
    let creatorRecordNameMatchesExpectedCurrentUser: Bool?
    let creatorRecordNameIsCurrentUserDefaultName: Bool?
    let modifierRecordNameMatchesExpectedCurrentUser: Bool?
    let modifierRecordNameIsCurrentUserDefaultName: Bool?
    let creatorModifierRecordNamesMatch: Bool?
    let creatorZoneNameIsDefault: Bool?
    let creatorZoneOwnerIsCurrentUserDefaultName: Bool?
    let creatorZoneOwnerMatchesExpectedCurrentUser: Bool?
    let modifierZoneNameIsDefault: Bool?
    let modifierZoneOwnerIsCurrentUserDefaultName: Bool?
    let modifierZoneOwnerMatchesExpectedCurrentUser: Bool?
}

struct InvitationLifecycleAuthorityObservation: Equatable {
    let attempt: Int
    let phase: InvitationLifecycleAuthorityPhase
    let result: InvitationLifecycleAuthorityResult
    let comparison: InvitationLifecycleAuthorityRecordComparison?
    let stateMatchesRequested: Bool?
}

enum InvitationInternalErrorKind: String, Equatable {
    case household
    case cloudKit
    case cancellation
    case cocoa
    case url
    case posix
    case unclassified
}

struct InvitationInternalErrorComponent: Equatable {
    let depth: Int
    let kind: InvitationInternalErrorKind
    let caseName: String?
    let domain: String?
    let code: Int?
}

enum InvitationDiagnosticDetail: Equatable {
    case context
    case accountIdentity(digest: String, generation: UInt64, stable: Bool?)
    case expectedOwnerMembership(InvitationExpectedOwnerMembership)
    case membershipLock(InvitationMembershipLockSnapshot)
    case ownerComparison(InvitationOwnerMembershipComparison)
    case ownerBranch(InvitationOwnerMembershipBranch, result: String)
    case lifecycleAuthority(InvitationLifecycleAuthorityObservation)
    case internalError([InvitationInternalErrorComponent])
    case userFacingConversion([InvitationInternalErrorComponent], mapping: String)
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
    var lockOwnerAuthorityMatchesTargetOwner: Bool?
    var lifecycleState: FamilyLifecycleState?
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
    case membershipLockUnavailable
    case lockMissing
    case lockReleased
    case sharedZoneUnavailable
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
    var lockHasOwnerAuthorityBinding: Bool?
    var lifecycleState: FamilyLifecycleState?
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
    let invitationDetail: InvitationDiagnosticDetail?
}

@MainActor
final class FamilyTransitionDiagnostics {
    private static let logger = Logger(subsystem: "com.jlm429.EarnedIt", category: "FamilyTransition")
    private static let eventLimit = 200

    private(set) var events: [FamilyTransitionDiagnosticEvent] = []
    private var targetHouseholdID: UUID?
    private var expectedAttemptID: UUID?
    private var expectedParticipantID: String?
    private var invitationContext: InvitationDiagnosticContext?
    private(set) var latestInvitationTrace: String?

    var isActive: Bool { targetHouseholdID != nil }

    func clearInvitationAttempt() {
        events.removeAll(keepingCapacity: true)
        targetHouseholdID = nil
        expectedAttemptID = nil
        expectedParticipantID = nil
        invitationContext = nil
        latestInvitationTrace = nil
    }

    func begin(targetHouseholdID: UUID, localAttemptID: UUID?, localParticipantID: String?) {
        events.removeAll(keepingCapacity: true)
        invitationContext = nil
        self.targetHouseholdID = targetHouseholdID
        expectedAttemptID = localAttemptID
        expectedParticipantID = localParticipantID
        record(stage: .invitationStart, outcome: .started)
    }

    func beginInvitation(
        householdID: UUID,
        currentParentMemberID: UUID?,
        targetMemberID: UUID,
        targetRole: UserRole,
        localAttemptID: UUID?,
        localParticipantID: String?,
        accountGeneration: UInt64,
        hasCloudLocation: Bool
    ) {
        events.removeAll(keepingCapacity: true)
        targetHouseholdID = householdID
        expectedAttemptID = localAttemptID
        expectedParticipantID = localParticipantID
        invitationContext = InvitationDiagnosticContext(
            correlationID: UUID(),
            householdID: householdID,
            currentParentMemberID: currentParentMemberID,
            targetMemberID: targetMemberID,
            targetRole: targetRole,
            startedWithCloudLocation: hasCloudLocation,
            localAcquisitionNoncePresent: localAttemptID != nil,
            cloudKitUserRecordNameSHA256: localParticipantID.map(Self.digest),
            accountGeneration: accountGeneration
        )
        latestInvitationTrace = nil
        append(event(stage: .invitationStart, outcome: .started, detail: .context))
    }

    func expect(attemptID: UUID? = nil, participantID: String? = nil) {
        if let attemptID { expectedAttemptID = attemptID }
        if let participantID { expectedParticipantID = participantID }
    }

    func recordAccountIdentity(participantID: String, generation: UInt64, stable: Bool? = nil) {
        guard isActive, var context = invitationContext else { return }
        let digest = Self.digest(participantID)
        context.cloudKitUserRecordNameSHA256 = digest
        context.accountGeneration = generation
        invitationContext = context
        append(event(
            stage: .cloudAccountIdentity,
            outcome: .observed,
            accountGenerationStable: stable,
            detail: .accountIdentity(digest: digest, generation: generation, stable: stable)
        ))
    }

    func recordExpectedOwnerMembership(
        householdID: UUID,
        memberID: UUID?,
        role: UserRole?,
        locationIsOwner: Bool,
        participantID: String?
    ) {
        guard isActive, invitationContext != nil else { return }
        append(event(
            stage: .ownerMembershipValidation,
            outcome: .observed,
            detail: .expectedOwnerMembership(InvitationExpectedOwnerMembership(
                householdID: householdID,
                memberID: memberID,
                role: role,
                ownerLocation: locationIsOwner,
                claimBindingKind: "deterministicOwnerHouseholdBinding",
                ownerAuthorityDerivedFromCurrentAccount: participantID?.isEmpty == false
            ))
        ))
    }

    func recordMembershipLock(
        _ lock: AccountMembershipLock?,
        expectedOwnerBinding: String,
        expectedOwnerAuthorityBinding: String?,
        localAttemptID: UUID?,
        accountGeneration: UInt64
    ) {
        guard isActive, invitationContext != nil else { return }
        let nonceRelationship: InvitationDiagnosticRelationship
        if lock == nil {
            nonceRelationship = .notApplicable
        } else if let localAttemptID {
            nonceRelationship = lock?.attemptID == localAttemptID ? .matches : .differs
        } else {
            nonceRelationship = .missing
        }
        let snapshot = InvitationMembershipLockSnapshot(
            present: lock != nil,
            householdID: lock?.householdID,
            state: lock?.state,
            accountGeneration: accountGeneration,
            claimBindingPresent: lock?.claimBinding != nil,
            claimBindingMatchesExpectedOwner: lock.map { $0.claimBinding == expectedOwnerBinding },
            ownerAuthorityBindingPresent: lock?.ownerAuthorityBinding != nil,
            ownerAuthorityBindingMatchesCurrentAccount: expectedOwnerAuthorityBinding.flatMap { expected in
                lock.map { $0.ownerAuthorityBinding == expected }
            },
            acquisitionNonceRelationship: nonceRelationship
        )
        append(event(
            stage: .ownerMembershipValidation,
            outcome: .observed,
            lock: lock,
            detail: .membershipLock(snapshot)
        ))
    }

    func recordOwnerComparison(_ comparison: InvitationOwnerMembershipComparison) {
        guard isActive, invitationContext != nil else { return }
        append(event(
            stage: .ownerMembershipValidation,
            outcome: .observed,
            detail: .ownerComparison(comparison)
        ))
    }

    func recordOwnerBranch(_ branch: InvitationOwnerMembershipBranch, result: String) {
        guard isActive, invitationContext != nil else { return }
        let safeResult = ["selected", "passed", "failed", "observed", "notApplicable"].contains(result)
            ? result : "notApplicable"
        append(event(
            stage: .ownerMembershipValidation,
            outcome: .observed,
            detail: .ownerBranch(branch, result: safeResult)
        ))
    }

    func recordLifecycleAuthority(
        attempt: Int,
        phase: InvitationLifecycleAuthorityPhase,
        result: InvitationLifecycleAuthorityResult,
        comparison: InvitationLifecycleAuthorityRecordComparison? = nil,
        stateMatchesRequested: Bool? = nil,
        error: Error? = nil
    ) {
        guard isActive, invitationContext != nil else { return }
        append(event(
            stage: .lifecycleAuthorityPrepare,
            outcome: .observed,
            cloudErrors: error.map(Self.cloudErrors(from:)) ?? [],
            detail: .lifecycleAuthority(InvitationLifecycleAuthorityObservation(
                attempt: attempt,
                phase: phase,
                result: result,
                comparison: comparison,
                stateMatchesRequested: stateMatchesRequested
            ))
        ))
    }

    func recordInternalError(_ error: Error) {
        guard invitationContext != nil else { return }
        append(event(
            stage: .internalErrorCapture,
            outcome: .observed,
            cloudErrors: Self.cloudErrors(from: error),
            detail: .internalError(Self.internalErrorChain(from: error))
        ))
    }

    func recordUserFacingErrorConversion(_ error: Error) {
        guard invitationContext != nil else { return }
        append(event(
            stage: .userFacingErrorConversion,
            outcome: .succeeded,
            cloudErrors: Self.cloudErrors(from: error),
            detail: .userFacingConversion(
                Self.internalErrorChain(from: error),
                mapping: error is HouseholdError ? "HouseholdError.errorDescription" : "Error.localizedDescription"
            )
        ))
        refreshLatestInvitationTrace()
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
        let cloudErrors = error.map(Self.cloudErrors(from:)) ?? []
        append(event(
            stage: stage,
            outcome: outcome,
            lock: lock,
            householdID: householdID,
            attemptID: attemptID,
            participantID: participantID,
            accountGenerationStable: accountGenerationStable,
            factCount: factCount,
            cloudErrors: cloudErrors
        ))
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
            childRecoveryPreflight: nil,
            invitationDetail: nil
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
            childRecoveryPreflight: childRecoveryPreflight,
            invitationDetail: nil
        )
        append(event)
    }

    func finish(outcome: FamilyTransitionDiagnosticOutcome, error: Error? = nil) {
        record(stage: .completed, outcome: outcome, error: error)
        if outcome == .failed {
            refreshLatestInvitationTrace()
        } else {
            latestInvitationTrace = nil
        }
        targetHouseholdID = nil
        expectedAttemptID = nil
        expectedParticipantID = nil
    }

    func exportLines() -> [String] { events.map(Self.line(for:)) }

    static func cloudErrors(from error: Error) -> [FamilyTransitionCloudError] {
        guard let cloudError = error as? CKError else { return [] }
        return recursiveCloudErrors(cloudError, source: .topLevel, path: "topLevel", depth: 0)
    }

    private func event(
        stage: FamilyTransitionDiagnosticStage,
        outcome: FamilyTransitionDiagnosticOutcome,
        lock: AccountMembershipLock? = nil,
        householdID: UUID? = nil,
        attemptID: UUID? = nil,
        participantID: String? = nil,
        accountGenerationStable: Bool? = nil,
        factCount: Int? = nil,
        cloudErrors: [FamilyTransitionCloudError] = [],
        detail: InvitationDiagnosticDetail? = nil
    ) -> FamilyTransitionDiagnosticEvent {
        let observedHousehold = lock?.householdID ?? householdID
        let observedAttempt = lock?.attemptID ?? attemptID
        return FamilyTransitionDiagnosticEvent(
            sequence: (events.last?.sequence ?? 0) + 1,
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
            childRecoveryPreflight: nil,
            invitationDetail: detail
        )
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
        source: FamilyTransitionCloudErrorSource,
        path: String
    ) -> FamilyTransitionCloudError {
        FamilyTransitionCloudError(
            code: error.code,
            codeName: String(describing: error.code),
            source: source,
            retryAfterSeconds: (error.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue,
            count: 1,
            domain: CKErrorDomain,
            path: path
        )
    }

    private static func recursiveCloudErrors(
        _ error: CKError,
        source: FamilyTransitionCloudErrorSource,
        path: String,
        depth: Int
    ) -> [FamilyTransitionCloudError] {
        var result = [cloudErrorSummary(error, source: source, path: path)]
        guard depth < 8, error.code == .partialFailure else { return result }
        let partials = (error.partialErrorsByItemID ?? [:]).values.compactMap { $0 as? CKError }.sorted {
            if $0.code.rawValue != $1.code.rawValue { return $0.code.rawValue < $1.code.rawValue }
            let leftRetry = ($0.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue ?? -1
            let rightRetry = ($1.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue ?? -1
            if leftRetry != rightRetry { return leftRetry < rightRetry }
            return ($0.partialErrorsByItemID?.count ?? 0) < ($1.partialErrorsByItemID?.count ?? 0)
        }
        for (index, partial) in partials.enumerated() {
            result += recursiveCloudErrors(
                partial,
                source: .partialItem,
                path: "\(path).partial[\(index + 1)]",
                depth: depth + 1
            )
        }
        return result
    }

    private func refreshLatestInvitationTrace() {
        guard let context = invitationContext,
              events.contains(where: { $0.stage == .completed && $0.outcome == .failed }) else {
            latestInvitationTrace = nil
            return
        }
        let observationalStages: [FamilyTransitionDiagnosticStage] = [
            .preflight,
            .childRecoveryPreflight,
            .invitationDiagnosticIdentityRead,
            .invitationDiagnosticMembershipLockRead
        ]
        let causalFailure = events.first {
            $0.outcome == .failed && $0.stage != .completed && !observationalStages.contains($0.stage)
        }
        let completedFailure = events.first { $0.outcome == .failed && $0.stage == .completed }
        let firstFailure = causalFailure ?? completedFailure
        var lines = [
            "Earned It Production Invitation Issuance Trace",
            "traceFormat=EarnedItInvitationIssuance/2",
            "sanitizer=allowListedTypedFields",
            "correlationID=\(context.correlationID.uuidString)",
            "householdID=\(context.householdID.uuidString)",
            "currentParentMemberID=\(context.currentParentMemberID?.uuidString ?? "unavailable")",
            "targetMemberID=\(context.targetMemberID.uuidString)",
            "targetRole=\(context.targetRole.rawValue)",
            "startedWithCloudLocation=\(context.startedWithCloudLocation)",
            "localAcquisitionNoncePresent=\(context.localAcquisitionNoncePresent)",
            "cloudKitUserRecordNameSHA256=\(context.cloudKitUserRecordNameSHA256 ?? "unavailable")",
            "accountGeneration=\(context.accountGeneration)",
            "firstFailureSequence=\(firstFailure.map { String($0.sequence) } ?? "none")",
            "firstFailureStage=\(firstFailure?.stage.rawValue ?? "none")",
            "firstFailureOperation=\(firstFailure.map { Self.operation(for: $0.stage) } ?? "none")",
            "events:"
        ]
        lines += events.map(Self.invitationLine(for:))
        latestInvitationTrace = lines.joined(separator: "\n")
    }

    private static func invitationLine(for event: FamilyTransitionDiagnosticEvent) -> String {
        var fields = [
            String(format: "%03d", event.sequence),
            "stage=\(event.stage.rawValue)",
            "outcome=\(event.outcome.rawValue)",
            "operation=\(operation(for: event.stage))"
        ]
        if let lockState = event.lockState { fields.append("lockState=\(lockState.rawValue)") }
        if let householdMatchesTarget = event.householdMatchesTarget {
            fields.append("householdMatchesTarget=\(householdMatchesTarget)")
        }
        if let attemptMatchesExpected = event.attemptMatchesExpected {
            fields.append("acquisitionNonceMatchesExpected=\(attemptMatchesExpected)")
        }
        if let participantMatchesExpected = event.participantMatchesExpected {
            fields.append("cloudAccountMatchesExpected=\(participantMatchesExpected)")
        }
        if let accountGenerationStable = event.accountGenerationStable {
            fields.append("accountGenerationStable=\(accountGenerationStable)")
        }
        if let factCount = event.factCount { fields.append("factCount=\(factCount)") }
        fields += invitationDetailFields(event.invitationDetail)
        for error in event.cloudErrors {
            fields.append(
                "cloudError[path=\(error.path),domain=\(error.domain),code=\(error.code.rawValue),"
                    + "codeName=\(error.codeName),source=\(error.source.rawValue),"
                    + "retryAfterSeconds=\(error.retryAfterSeconds.map { String($0) } ?? "none")]"
            )
        }
        return fields.joined(separator: " ")
    }

    private static func invitationDetailFields(_ detail: InvitationDiagnosticDetail?) -> [String] {
        guard let detail else { return [] }
        switch detail {
        case .context:
            return ["detail=attemptContext"]
        case .accountIdentity(let digest, let generation, let stable):
            return [
                "detail=cloudAccountIdentity",
                "cloudKitUserRecordNameSHA256=\(digest)",
                "accountGeneration=\(generation)",
                "accountGenerationStable=\(value(stable))"
            ]
        case .expectedOwnerMembership(let expected):
            return [
                "detail=expectedOwnerMembership",
                "expected.householdID=\(expected.householdID.uuidString)",
                "expected.memberProfileID=\(expected.memberID?.uuidString ?? "unavailable")",
                "expected.role=\(expected.role?.rawValue ?? "unavailable")",
                "expected.ownerLocation=\(expected.ownerLocation)",
                "expected.claimBindingKind=\(expected.claimBindingKind)",
                "expected.ownerAuthorityDerivedFromCurrentAccount="
                    + "\(expected.ownerAuthorityDerivedFromCurrentAccount)"
            ]
        case .membershipLock(let lock):
            return [
                "detail=existingAccountMembershipLock",
                "lock.present=\(lock.present)",
                "lock.householdID=\(lock.householdID?.uuidString ?? "none")",
                "lock.memberProfileID=notStored",
                "lock.role=notStored",
                "lock.state=\(lock.state?.rawValue ?? "none")",
                "lock.accountGeneration=\(lock.accountGeneration)",
                "lock.claimBindingPresent=\(lock.claimBindingPresent)",
                "lock.claimBindingMatchesExpectedOwner=\(value(lock.claimBindingMatchesExpectedOwner))",
                "lock.ownerAuthorityBindingPresent=\(lock.ownerAuthorityBindingPresent)",
                "lock.ownerAuthorityBindingMatchesCurrentAccount="
                    + "\(value(lock.ownerAuthorityBindingMatchesCurrentAccount))",
                "lock.acquisitionNonceRelationship=\(lock.acquisitionNonceRelationship.rawValue)"
            ]
        case .ownerComparison(let comparison):
            return [
                "detail=ownerMembershipComparison",
                "compare.location.isOwner=\(comparison.locationIsOwner)",
                "compare.session.householdID_eq_location.householdID="
                    + "\(comparison.sessionHouseholdMatchesLocation)",
                "compare.session.location_eq_location=\(comparison.sessionLocationMatches)",
                "compare.session.cloudParticipantID_eq_currentCloudAccount="
                    + "\(comparison.sessionParticipantMatchesCurrentAccount)",
                "compare.selectedMember.present=\(comparison.selectedMemberPresent)",
                "compare.selectedMember.role_eq_parent=\(comparison.selectedMemberRoleIsParent)",
                "compare.fetchedJournal.selectedMember.role_eq_parent="
                    + "\(comparison.selectedMemberExistsAsParentInFetchedJournal)",
                "compare.derivedBinding_eq_expectedOwner="
                    + "\(comparison.derivedBindingMatchesExpectedOwner)",
                "compare.lock.householdID_eq_location.householdID="
                    + "\(comparison.lockHouseholdMatchesLocation)",
                "compare.lock.state_eq_active=\(comparison.lockStateIsActive)",
                "compare.lock.claimBinding.present=\(comparison.lockClaimBindingPresent)",
                "compare.lock.claimBinding_eq_derivedBinding="
                    + "\(comparison.lockClaimBindingMatchesDerivedBinding)",
                "compare.lock.ownerAuthorityBinding.present="
                    + "\(comparison.lockOwnerAuthorityBindingPresent)",
                "compare.lock.ownerAuthorityBinding_eq_currentCloudAccount="
                    + "\(comparison.lockOwnerAuthorityBindingMatchesCurrentAccount)",
                "compare.session.claimBinding.present=\(comparison.localClaimBindingPresent)",
                "compare.session.claimBinding_eq_derivedBinding="
                    + "\(value(comparison.localClaimBindingMatchesDerivedBinding))",
                "comparison.permitsActiveOwnerReuse=\(comparison.permitsActiveOwnerReuse)"
            ]
        case .ownerBranch(let branch, let result):
            return [
                "detail=ownerMembershipBranch",
                "branch=\(branch.rawValue)",
                "branchResult=\(result)"
            ]
        case .lifecycleAuthority(let observation):
            var fields = [
                "detail=lifecycleAuthorityComparison",
                "lifecycle.attempt=\(observation.attempt)",
                "lifecycle.phase=\(observation.phase.rawValue)",
                "lifecycle.result=\(observation.result.rawValue)",
                "lifecycle.stateMatchesRequested=\(value(observation.stateMatchesRequested))"
            ]
            if let comparison = observation.comparison {
                let identity = comparison.identityRepresentation
                fields += [
                    "lifecycle.recordTypeMatches=\(comparison.recordTypeMatches)",
                    "lifecycle.formatVersionMatches=\(comparison.formatVersionMatches)",
                    "lifecycle.state=\(comparison.state?.rawValue ?? "unknown")",
                    "lifecycle.stateRecognized=\(comparison.stateRecognized)",
                    "lifecycle.creatorPresent=\(comparison.creatorPresent)",
                    "lifecycle.creatorMatchesCurrentAccount="
                        + "\(value(comparison.creatorMatchesCurrentAccount))",
                    "lifecycle.modifierPresent=\(comparison.modifierPresent)",
                    "lifecycle.modifierMatchesCurrentAccount="
                        + "\(value(comparison.modifierMatchesCurrentAccount))",
                    "lifecycle.expectedCurrentRecordNameIsCurrentUserDefaultName="
                        + "\(value(identity?.expectedCurrentRecordNameIsCurrentUserDefaultName))",
                    "lifecycle.creatorRecordNameMatchesExpectedCurrentUser="
                        + "\(value(identity?.creatorRecordNameMatchesExpectedCurrentUser))",
                    "lifecycle.creatorRecordNameIsCurrentUserDefaultName="
                        + "\(value(identity?.creatorRecordNameIsCurrentUserDefaultName))",
                    "lifecycle.modifierRecordNameMatchesExpectedCurrentUser="
                        + "\(value(identity?.modifierRecordNameMatchesExpectedCurrentUser))",
                    "lifecycle.modifierRecordNameIsCurrentUserDefaultName="
                        + "\(value(identity?.modifierRecordNameIsCurrentUserDefaultName))",
                    "lifecycle.creatorModifierRecordNamesMatch="
                        + "\(value(identity?.creatorModifierRecordNamesMatch))",
                    "lifecycle.creatorZoneNameIsDefault="
                        + "\(value(identity?.creatorZoneNameIsDefault))",
                    "lifecycle.creatorZoneOwnerIsCurrentUserDefaultName="
                        + "\(value(identity?.creatorZoneOwnerIsCurrentUserDefaultName))",
                    "lifecycle.creatorZoneOwnerMatchesExpectedCurrentUser="
                        + "\(value(identity?.creatorZoneOwnerMatchesExpectedCurrentUser))",
                    "lifecycle.modifierZoneNameIsDefault="
                        + "\(value(identity?.modifierZoneNameIsDefault))",
                    "lifecycle.modifierZoneOwnerIsCurrentUserDefaultName="
                        + "\(value(identity?.modifierZoneOwnerIsCurrentUserDefaultName))",
                    "lifecycle.modifierZoneOwnerMatchesExpectedCurrentUser="
                        + "\(value(identity?.modifierZoneOwnerMatchesExpectedCurrentUser))",
                    "lifecycle.recordAccepted=\(comparison.isAccepted)"
                ]
            }
            return fields
        case .internalError(let components):
            return ["detail=internalErrorBeforeRethrow"] + internalErrorFields(components)
        case .userFacingConversion(let components, let mapping):
            return ["detail=internalErrorBeforeUserFacingConversion", "mapping=\(mapping)"]
                + internalErrorFields(components)
        }
    }

    private static func internalErrorFields(_ components: [InvitationInternalErrorComponent]) -> [String] {
        components.enumerated().map { index, component in
            "errorChain[\(index)]=depth:\(component.depth),kind:\(component.kind.rawValue),"
                + "case:\(component.caseName ?? "none"),domain:\(component.domain ?? "none"),"
                + "code:\(component.code.map { String($0) } ?? "none")"
        }
    }

    private static func internalErrorChain(from error: Error) -> [InvitationInternalErrorComponent] {
        var result: [InvitationInternalErrorComponent] = []
        func append(_ current: Error, depth: Int) {
            guard depth < 8 else { return }
            if let householdError = current as? HouseholdError {
                result.append(InvitationInternalErrorComponent(
                    depth: depth,
                    kind: .household,
                    caseName: householdErrorName(householdError),
                    domain: nil,
                    code: nil
                ))
                return
            }
            if let cloudError = current as? CKError {
                result.append(InvitationInternalErrorComponent(
                    depth: depth,
                    kind: .cloudKit,
                    caseName: String(describing: cloudError.code),
                    domain: CKErrorDomain,
                    code: cloudError.code.rawValue
                ))
            } else if current is CancellationError {
                result.append(InvitationInternalErrorComponent(
                    depth: depth,
                    kind: .cancellation,
                    caseName: "CancellationError",
                    domain: nil,
                    code: nil
                ))
            } else {
                let nsError = current as NSError
                let kind: InvitationInternalErrorKind
                let safeDomain: String?
                switch nsError.domain {
                case NSCocoaErrorDomain:
                    kind = .cocoa
                    safeDomain = NSCocoaErrorDomain
                case NSURLErrorDomain:
                    kind = .url
                    safeDomain = NSURLErrorDomain
                case NSPOSIXErrorDomain:
                    kind = .posix
                    safeDomain = NSPOSIXErrorDomain
                default:
                    kind = .unclassified
                    safeDomain = nil
                }
                result.append(InvitationInternalErrorComponent(
                    depth: depth,
                    kind: kind,
                    caseName: nil,
                    domain: safeDomain,
                    code: nsError.code
                ))
            }
            let nsError = current as NSError
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                append(underlying, depth: depth + 1)
            }
        }
        append(error, depth: 0)
        return result
    }

    private static func householdErrorName(_ error: HouseholdError) -> String {
        switch error {
        case .invalidAllowance: "invalidAllowance"
        case .completionLocked: "completionLocked"
        case .permission: "permission"
        case .invalidName: "invalidName"
        case .duplicateName: "duplicateName"
        case .missingChildren: "missingChildren"
        case .invalidAssignment: "invalidAssignment"
        case .unavailableDay: "unavailableDay"
        case .noHousehold: "noHousehold"
        case .alreadyHasHousehold: "alreadyHasHousehold"
        case .cloudUnavailable: "cloudUnavailable"
        case .wrongAccount: "wrongAccount"
        case .invitation: "invitation"
        case .readOnly: "readOnly"
        case .invitationNotFound: "invitationNotFound"
        case .invitationExpired: "invitationExpired"
        case .invitationRevoked: "invitationRevoked"
        case .invitationConsumed: "invitationConsumed"
        case .invitationUnavailable: "invitationUnavailable"
        case .invitationOwnerRequired: "invitationOwnerRequired"
        case .accountMembershipConflict: "accountMembershipConflict"
        case .ownerMembershipUnavailable: "ownerMembershipUnavailable"
        case .missingProfile: "missingProfile"
        case .lastParent: "lastParent"
        case .pendingChanges: "pendingChanges"
        case .malformedData: "malformedData"
        case .familyStillSyncing: "familyStillSyncing"
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func operation(for stage: FamilyTransitionDiagnosticStage) -> String {
        switch stage {
        case .preflight: "HouseholdTransport.ownerTransitionPreflight"
        case .childRecoveryPreflight: "HouseholdTransport.childRecoveryPreflight"
        case .invitationStart: "HouseholdStore.issueInvitation"
        case .invitationDiagnosticPreamble: "HouseholdStore.collectInvitationDiagnosticPreamble"
        case .invitationDiagnosticIdentityRead: "CKContainer.userRecordID.readOnlyDiagnostics"
        case .invitationDiagnosticMembershipLockRead:
            "CKDatabase.record.AccountMembershipLock.readOnlyDiagnostics"
        case .cloudAccountIdentity: "CKContainer.userRecordID"
        case .invitationAccessPruning: "HouseholdStore.pruneUnavailableInvitationAccess"
        case .invitationGeneration: "InvitationCode.generate"
        case .zoneConnectionBootstrap: "HouseholdStore.connect"
        case .initialFactSynchronization: "HouseholdStore.synchronize.initialBootstrap"
        case .preInvitationSynchronization: "HouseholdStore.synchronize.preInvitation"
        case .ownerMembershipValidation: "HouseholdStore.reconcileAccountMembershipLock"
        case .participantLookup: "CKContainer.userRecordID"
        case .membershipValidationTimeWrite: "CKDatabase.modifyRecords.AccountMembershipValidationTime"
        case .membershipLockRead: "CKDatabase.record.AccountMembershipLock"
        case .membershipLockAcquire: "CKDatabase.modifyRecords.AccountMembershipLock.acquire"
        case .membershipLockReplace: "CKDatabase.modifyRecords.AccountMembershipLock.replace"
        case .zoneCreate: "CKDatabase.save.CKRecordZone"
        case .journalFetch: "CKDatabase.recordZoneChanges.HouseholdFact"
        case .journalUpload: "CKDatabase.modifyRecords.HouseholdFact"
        case .membershipLockActivate: "CKDatabase.modifyRecords.AccountMembershipLock.activate"
        case .lifecycleAuthorityPrepare: "CKDatabase.fetchSave.FamilyLifecycleAuthority"
        case .lifecycleDeletionPublish: "CKDatabase.save.FamilyLifecycleAuthority.deletion"
        case .lifecycleDeletionCheck: "CKDatabase.fetch.FamilyLifecycleAuthority"
        case .validationTimeWrite: "CKDatabase.modifyRecords.InvitationValidationTime"
        case .shareFetch: "CKDatabase.record.CKShare"
        case .shareCreate: "CKDatabase.save.CKShare"
        case .shareOwnerValidation: "CloudKitHouseholdTransport.share.ownerGuard"
        case .invitationAccessOwnerValidation:
            "CloudKitHouseholdTransport.createInvitationAccess.ownerGuard"
        case .participantCreate: "CKShare.addParticipant+CKDatabase.save.CKShare"
        case .invitationStateValidation: "HouseholdStore.issueInvitation.stateGuard"
        case .connectionStateValidation: "HouseholdStore.connect.sessionGuard"
        case .lifecycleAuthorityValidation: "HouseholdStore.lifecycleAuthority.activeGuard"
        case .invitationAppend: "HouseholdStore.append.InvitationFact"
        case .invitationFactUpload: "CKDatabase.modifyRecords.InvitationFact"
        case .internalErrorCapture: "HouseholdStore.issueInvitation.catch"
        case .userFacingErrorConversion: "Error.localizedDescription"
        case .completed: "HouseholdStore.issueInvitation"
        }
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
                "lockOwnerAuthorityMatchesTargetOwner=\(value(snapshot.lockOwnerAuthorityMatchesTargetOwner))",
                "lifecycleState=\(snapshot.lifecycleState?.rawValue ?? "unknown")",
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
                "lockHasOwnerAuthorityBinding=\(value(snapshot.lockHasOwnerAuthorityBinding))",
                "lifecycleState=\(snapshot.lifecycleState?.rawValue ?? "unknown")",
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
                + "retryAfter=\(retryAfter):count=\(error.count):domain=\(error.domain):path=\(error.path)"
            fields.append(errorField)
        }
        return "family-transition " + fields.joined(separator: " ")
    }

    private static func value(_ value: Bool?) -> String { value.map { String($0) } ?? "unknown" }
    private static func number(_ value: Int?) -> String { value.map { String($0) } ?? "unknown" }
}

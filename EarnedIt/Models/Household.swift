import Foundation

/// A civil date in the household's fixed Gregorian timezone, not a midnight instant.
struct CivilDay: RawRepresentable, Codable, Hashable, Comparable, CustomStringConvertible {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.count == 10,
              let date = AppCalendar.persistedDay(for: rawValue),
              AppCalendar.persistedDayIdentifier(for: date) == rawValue else { return nil }
        self.rawValue = rawValue
    }

    init(_ date: Date, calendar: Calendar) {
        rawValue = AppCalendar.dayIdentifier(for: date, calendar: calendar)
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let day = CivilDay(rawValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid civil date"))
        }
        self = day
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    var description: String { rawValue }

    func date(in calendar: Calendar) -> Date {
        let parts = rawValue.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    func adding(days: Int, calendar: Calendar) -> CivilDay {
        CivilDay(calendar.date(byAdding: .day, value: days, to: date(in: calendar))!, calendar: calendar)
    }
}

enum Weekday: Int, Codable, CaseIterable, Identifiable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .sunday: "Sunday"
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        }
    }
}

struct Household: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let timeZoneID: String
    let createdDay: CivilDay
    let creatorDeviceID: UUID
    var isSetupComplete = false

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    var weekdayLists: [WeekdayList] {
        Weekday.allCases.map { WeekdayList(householdID: id, weekday: $0) }
    }
}

/// Canonical identity is household plus weekday, even when this list is empty.
struct WeekdayList: Identifiable, Equatable {
    let householdID: UUID
    let weekday: Weekday
    var id: String { "\(householdID)/\(weekday.rawValue)" }
}

struct FamilyMember: Codable, Equatable, Identifiable {
    let id: UUID
    let householdID: UUID
    var displayName: String
    let role: UserRole
    var avatar: AvatarOption
    let joinedDay: CivilDay
    var archivedFrom: CivilDay?

    func isActive(on day: CivilDay) -> Bool {
        joinedDay <= day && (archivedFrom == nil || day < archivedFrom!)
    }
}

enum RequirementMode: String, Codable, CaseIterable, Identifiable {
    case particular, anyOne, multiple, all, alternating

    static let assignmentChoices: [Self] = [.all, .particular, .alternating]

    var id: String { rawValue }
    var title: String {
        switch self {
        case .particular: "One child"
        case .anyOne: "Any one eligible child"
        case .multiple: "Specific children"
        case .all: "All children"
        case .alternating: "Alternate / take turns"
        }
    }
}

/// Revisions are immutable. Edits begin tomorrow; the chore keeps its identity.
struct ChoreRevision: Codable, Equatable, Identifiable {
    let id: UUID
    let householdID: UUID
    let choreID: UUID
    let weekday: Weekday
    let effectiveDay: CivilDay
    let title: String
    let notes: String
    let category: ResponsibilityCategory
    let mode: RequirementMode
    let memberIDs: [UUID]
    let isArchived: Bool
    let schedulingMode: ChoreSchedulingMode

    init(id: UUID, householdID: UUID, choreID: UUID, weekday: Weekday, effectiveDay: CivilDay,
         title: String, notes: String, category: ResponsibilityCategory, mode: RequirementMode,
         memberIDs: [UUID], isArchived: Bool, schedulingMode: ChoreSchedulingMode = .scheduled) {
        self.id = id
        self.householdID = householdID
        self.choreID = choreID
        self.weekday = weekday
        self.effectiveDay = effectiveDay
        self.title = title
        self.notes = notes
        self.category = category
        self.mode = mode
        self.memberIDs = memberIDs
        self.isArchived = isArchived
        self.schedulingMode = schedulingMode
    }
}

extension ChoreRevision {
    private enum CodingKeys: String, CodingKey {
        case id, householdID, choreID, weekday, effectiveDay, title, notes, category, mode, memberIDs, isArchived
        case schedulingMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        householdID = try container.decode(UUID.self, forKey: .householdID)
        choreID = try container.decode(UUID.self, forKey: .choreID)
        weekday = try container.decode(Weekday.self, forKey: .weekday)
        effectiveDay = try container.decode(CivilDay.self, forKey: .effectiveDay)
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decode(String.self, forKey: .notes)
        category = try container.decode(ResponsibilityCategory.self, forKey: .category)
        mode = try container.decode(RequirementMode.self, forKey: .mode)
        memberIDs = try container.decode([UUID].self, forKey: .memberIDs)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        schedulingMode = try container.decodeIfPresent(ChoreSchedulingMode.self, forKey: .schedulingMode) ?? .scheduled
    }
}

enum ChoreOccurrenceState: String, Codable, Equatable {
    case available
    case notNeeded
}

struct ChoreOccurrenceDisposition: Codable, Equatable {
    let choreID: UUID
    let revisionID: UUID
    let day: CivilDay
    let state: ChoreOccurrenceState
    let alternatingSkipBehavior: AlternatingSkipBehavior?
    let recordedByMemberID: UUID
    let assignedMemberID: UUID?

    init(choreID: UUID, revisionID: UUID, day: CivilDay, state: ChoreOccurrenceState,
         alternatingSkipBehavior: AlternatingSkipBehavior?, recordedByMemberID: UUID,
         assignedMemberID: UUID? = nil) {
        self.choreID = choreID
        self.revisionID = revisionID
        self.day = day
        self.state = state
        self.alternatingSkipBehavior = alternatingSkipBehavior
        self.recordedByMemberID = recordedByMemberID
        self.assignedMemberID = assignedMemberID
    }

    var key: String { "\(choreID)/\(day)" }
}

/// Advances an inactive alternating As Needed chore only when the expected child is still next.
/// The expected owner makes concurrent duplicate skips deterministic and idempotent.
struct AlternatingTurnAdvance: Codable, Equatable {
    let choreID: UUID
    let revisionID: UUID
    let expectedMemberID: UUID
    let day: CivilDay
    let recordedByMemberID: UUID
}

/// Declares the minimum journal protocol needed to interpret every later fact safely.
/// Older clients fail decoding this explicit fact case instead of silently collapsing
/// occurrence-aware actions into their legacy chore/day projection.
struct JournalCapability: Codable, Equatable {
    static let occurrenceAwareChores = 2
    static let puntApprovals = 3
    static let familyExtras = 4

    let minimumVersion: Int
    let recordedByMemberID: UUID
}

struct AsNeededOccurrence: Codable, Equatable, Identifiable {
    let id: UUID
    let choreID: UUID
    let revisionID: UUID
    let day: CivilDay
    let eligibleMemberIDs: [UUID]
    let requiredMemberIDs: [UUID]
    let assignedMemberID: UUID?
    let expectedControlHeadID: UUID?
    let recordedByMemberID: UUID
}

struct AsNeededOccurrenceCompletion: Codable, Equatable {
    let occurrenceID: UUID
    let choreID: UUID
    let revisionID: UUID
    let memberID: UUID
    let day: CivilDay
    let state: DailyStateKind
    let eligibleMemberIDs: [UUID]
    let mode: RequirementMode
    let recordedByMemberID: UUID

    var datedCompletion: DatedCompletion {
        DatedCompletion(choreID: choreID, revisionID: revisionID, memberID: memberID,
                        day: day, state: state, eligibleMemberIDs: eligibleMemberIDs,
                        mode: mode, recordedByMemberID: recordedByMemberID)
    }
}

enum AsNeededOccurrenceResolutionState: String, Codable, Equatable {
    case withdrawn
}

struct AsNeededOccurrenceResolution: Codable, Equatable {
    let occurrenceID: UUID
    let choreID: UUID
    let revisionID: UUID
    let day: CivilDay
    let state: AsNeededOccurrenceResolutionState
    let expectedControlHeadID: UUID
    let recordedByMemberID: UUID
}

struct AsNeededTurnAdvance: Codable, Equatable {
    let choreID: UUID
    let revisionID: UUID
    let expectedMemberID: UUID
    let day: CivilDay
    let expectedControlHeadID: UUID?
    let recordedByMemberID: UUID
}

struct ScheduledOccurrenceRestoration: Codable, Equatable {
    let choreID: UUID
    let revisionID: UUID
    let day: CivilDay
    let dispositionFactID: UUID
    let recordedByMemberID: UUID
}

/// A durable removal boundary that a later offline configuration cannot undo.
struct ChoreDeletion: Codable, Equatable {
    let choreID: UUID
    let day: CivilDay
    let recordedByMemberID: UUID
    let revisionID: UUID?
    let eligibleMemberIDs: [UUID]?
    let turnOwnerID: UUID?
    let wasNotNeeded: Bool?
    let resolvedContributions: [DatedCompletion]?
    let resolvedExcusedMemberIDs: [UUID]?

    init(choreID: UUID, day: CivilDay, recordedByMemberID: UUID, revisionID: UUID? = nil,
         eligibleMemberIDs: [UUID]? = nil, turnOwnerID: UUID? = nil, wasNotNeeded: Bool? = nil,
         resolvedContributions: [DatedCompletion]? = nil, resolvedExcusedMemberIDs: [UUID]? = nil) {
        self.choreID = choreID
        self.day = day
        self.recordedByMemberID = recordedByMemberID
        self.revisionID = revisionID
        self.eligibleMemberIDs = eligibleMemberIDs
        self.turnOwnerID = turnOwnerID
        self.wasNotNeeded = wasNotNeeded
        self.resolvedContributions = resolvedContributions
        self.resolvedExcusedMemberIDs = resolvedExcusedMemberIDs
    }
}

struct ResolvedAsNeededDeletionOccurrence: Codable, Equatable, Identifiable {
    let id: UUID
    let revisionID: UUID
    let day: CivilDay
    let eligibleMemberIDs: [UUID]
    let requiredMemberIDs: [UUID]
    let assignedMemberID: UUID?
    let contributions: [DatedCompletion]
    let excusedMemberIDs: [UUID]
}

struct OccurrenceAwareChoreDeletion: Codable, Equatable {
    let choreID: UUID
    let day: CivilDay
    let recordedByMemberID: UUID
    let revisionID: UUID
    let resolvedOccurrences: [ResolvedAsNeededDeletionOccurrence]
}

struct DatedCompletion: Codable, Equatable {
    let choreID: UUID
    let revisionID: UUID
    let memberID: UUID
    let day: CivilDay
    let state: DailyStateKind
    /// Assignment at contribution time preserves meaning across concurrent revisions.
    let eligibleMemberIDs: [UUID]
    let mode: RequirementMode
    let recordedByMemberID: UUID

    var key: String { "\(choreID)/\(day)/\(memberID)" }
}

struct Excuse: Codable, Equatable {
    let memberID: UUID
    let day: CivilDay
    let isExcused: Bool
    var key: String { "\(memberID)/\(day)" }
}

struct ProfileRequest: Codable, Equatable, Identifiable {
    let id: UUID
    let deviceID: UUID
    let cloudParticipantID: String
    let deviceName: String
    let memberIDs: [UUID]
}

struct ProfileGrant: Codable, Equatable {
    let requestID: UUID
    let deviceID: UUID
    let cloudParticipantID: String
    let memberIDs: [UUID]
    let approvedBy: UUID
    var key: String { "\(cloudParticipantID)/\(deviceID)" }
}

/// A parent-issued, short-lived authorization for exactly one existing family profile.
/// The clear-text code is never persisted in the household journal.
struct FamilyInvitation: Codable, Equatable, Identifiable {
    let id: UUID
    let householdID: UUID
    let claimFactID: UUID
    let memberID: UUID
    let role: UserRole
    let codeDigest: String
    let createdAt: Date
    let expiresAt: Date
    let createdByMemberID: UUID
    let cloudShareParticipantID: String
    let cloudShareURLDigest: String?
}

struct InvitationClaim: Codable, Equatable {
    let invitationID: UUID
    let deviceID: UUID
    let cloudParticipantID: String
    let memberID: UUID
    let codeDigest: String
    let claimedAt: Date
}

struct InvitationRevocation: Codable, Equatable {
    let invitationID: UUID
    let revokedByMemberID: UUID
}

enum HouseholdFactBody: Codable, Equatable {
    case swapRequest(SwapRequest)
    case swapDecision(SwapDecision)
    case bonusAward(BonusAward)
    case choreNudge(ChoreNudge)
    case puntRequest(PuntRequest)
    case puntDecision(PuntDecision)
    case household(Household)
    case member(FamilyMember)
    case chore(ChoreRevision)
    case completion(DatedCompletion)
    case occurrence(ChoreOccurrenceDisposition)
    case alternatingTurnAdvance(AlternatingTurnAdvance)
    case journalCapability(JournalCapability)
    case asNeededOccurrence(AsNeededOccurrence)
    case asNeededOccurrenceCompletion(AsNeededOccurrenceCompletion)
    case asNeededOccurrenceResolution(AsNeededOccurrenceResolution)
    case asNeededTurnAdvance(AsNeededTurnAdvance)
    case scheduledOccurrenceRestoration(ScheduledOccurrenceRestoration)
    case choreDeletion(ChoreDeletion)
    case occurrenceAwareChoreDeletion(OccurrenceAwareChoreDeletion)
    case allowance(AllowanceRevision)
    case excuse(Excuse)
    case request(ProfileRequest)
    case grant(ProfileGrant)
    case invitation(FamilyInvitation)
    case invitationClaim(InvitationClaim)
    case invitationRevocation(InvitationRevocation)
}

/// Lamport order plus UUID gives deterministic resolution without device clock ordering.
struct HouseholdFact: Codable, Equatable, Identifiable {
    let id: UUID
    let householdID: UUID
    let sequence: Int64
    let authorDeviceID: UUID
    let authorMemberID: UUID?
    let body: HouseholdFactBody

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.sequence == rhs.sequence ? lhs.id.uuidString < rhs.id.uuidString : lhs.sequence < rhs.sequence
    }
}

struct HouseholdSnapshot: Equatable {
    let replaysSwaps: Bool
    private(set) var orderedFacts: [HouseholdFact] = []
    var household: Household?
    var members: [FamilyMember] = []
    var revisions: [ChoreRevision] = []
    var completions: [DatedCompletion] = []
    var recordedAssignments: [DatedCompletion] = []
    var occurrenceDispositions: [ChoreOccurrenceDisposition] = []
    var alternatingTurnAdvances: [AlternatingTurnAdvance] = []
    var choreDeletions: [ChoreDeletion] = []
    var occurrenceAwareChoreDeletions: [OccurrenceAwareChoreDeletion] = []
    private(set) var creatorMemberID: UUID?
    private var parentCreationOrder: [UUID] = []
    var allowances: [AllowanceRevision] = []
    var excuses: [Excuse] = []
    var requests: [ProfileRequest] = []
    var grants: [ProfileGrant] = []
    var invitations: [FamilyInvitation] = []
    var invitationClaims: [InvitationClaim] = []
    var invitationRevocations: [InvitationRevocation] = []

    var requiredJournalCapability: Int {
        orderedFacts.compactMap { fact in
            switch fact.body {
            case .journalCapability(let capability): return capability.minimumVersion
            case .swapRequest, .swapDecision, .bonusAward, .choreNudge: return JournalCapability.familyExtras
            case .puntRequest, .puntDecision: return JournalCapability.puntApprovals
            default: return nil
            }
        }.max() ?? 1
    }

    var occurrenceCapabilityIndex: Int {
        orderedFacts.firstIndex { fact in
            switch fact.body {
            case .swapRequest, .swapDecision, .bonusAward, .choreNudge, .puntRequest, .puntDecision: return true
            case .journalCapability(let capability):
                return capability.minimumVersion >= JournalCapability.occurrenceAwareChores
            default: return false
            }
        } ?? orderedFacts.endIndex
    }

    init(facts: [HouseholdFact] = [], replaysSwaps: Bool = true) {
        self.replaysSwaps = replaysSwaps
        var membersByID: [UUID: FamilyMember] = [:]
        var creationSequence: [UUID: Int64] = [:]
        var completionsByKey: [String: DatedCompletion] = [:]
        var occurrencesByKey: [String: ChoreOccurrenceDisposition] = [:]
        var excusesByKey: [String: Excuse] = [:]
        var requestsByID: [UUID: ProfileRequest] = [:]
        var grantsByKey: [String: ProfileGrant] = [:]
        var invitationsByID: [UUID: FamilyInvitation] = [:]
        var claimsByInvitationID: [UUID: InvitationClaim] = [:]
        var revocationsByInvitationID: [UUID: InvitationRevocation] = [:]
        var deletedChoreIDs: Set<UUID> = []
        orderedFacts = facts.sorted(by: HouseholdFact.precedes)
        for fact in orderedFacts {
            switch fact.body {
            case .swapRequest, .swapDecision, .bonusAward, .choreNudge, .puntRequest, .puntDecision: break
            case .household(let value):
                household = value
                if creatorMemberID == nil { creatorMemberID = fact.authorMemberID }
            case .member(let value):
                if creationSequence[value.id] == nil { creationSequence[value.id] = fact.sequence }
                membersByID[value.id] = value
            case .chore(let value):
                guard !deletedChoreIDs.contains(value.choreID) else { continue }
                revisions.append(value)
            case .completion(let value):
                guard !deletedChoreIDs.contains(value.choreID) else { continue }
                completionsByKey[value.key] = value
                recordedAssignments.append(value)
            case .occurrence(let value):
                guard !deletedChoreIDs.contains(value.choreID) else { continue }
                occurrencesByKey[value.key] = value
            case .alternatingTurnAdvance(let value):
                guard !deletedChoreIDs.contains(value.choreID) else { continue }
                alternatingTurnAdvances.append(value)
            case .journalCapability:
                break
            case .asNeededOccurrence(let value):
                guard !deletedChoreIDs.contains(value.choreID) else { continue }
            case .asNeededOccurrenceCompletion(let value):
                guard !deletedChoreIDs.contains(value.choreID) else { continue }
            case .asNeededOccurrenceResolution(let value):
                guard !deletedChoreIDs.contains(value.choreID) else { continue }
            case .asNeededTurnAdvance(let value):
                guard !deletedChoreIDs.contains(value.choreID) else { continue }
            case .scheduledOccurrenceRestoration(let value):
                guard !deletedChoreIDs.contains(value.choreID) else { continue }
            case .choreDeletion(let value):
                guard deletedChoreIDs.insert(value.choreID).inserted else { continue }
                choreDeletions.append(value)
            case .occurrenceAwareChoreDeletion(let value):
                guard deletedChoreIDs.insert(value.choreID).inserted else { continue }
                occurrenceAwareChoreDeletions.append(value)
            case .allowance(let value): allowances.append(value)
            case .excuse(let value): excusesByKey[value.key] = value
            case .request(let value): requestsByID[value.id] = value
            case .grant(let value): grantsByKey[value.key] = value
            case .invitation(let value): invitationsByID[value.id] = value
            case .invitationClaim(let value): claimsByInvitationID[value.invitationID] = value
            case .invitationRevocation(let value): revocationsByInvitationID[value.invitationID] = value
            }
        }
        let parents = membersByID.values.filter { $0.role == .parent }.sorted {
            let lhs = creationSequence[$0.id] ?? 0
            let rhs = creationSequence[$1.id] ?? 0
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs < rhs
        }
        parentCreationOrder = parents.map(\.id)
        members = membersByID.values.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        completions = completionsByKey.values.sorted { $0.key < $1.key }
        occurrenceDispositions = occurrencesByKey.values.sorted { $0.key < $1.key }
        excuses = excusesByKey.values.sorted { $0.key < $1.key }
        requests = requestsByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        grants = grantsByKey.values.sorted { $0.key < $1.key }
        invitations = invitationsByID.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        invitationClaims = claimsByInvitationID.values.sorted { $0.invitationID.uuidString < $1.invitationID.uuidString }
        invitationRevocations = revocationsByInvitationID.values.sorted { $0.invitationID.uuidString < $1.invitationID.uuidString }
    }

    func configuration(choreID: UUID, on day: CivilDay) -> ChoreRevision? {
        // Revisions are already in deterministic fact order. Effective date takes priority.
        revisions.filter { $0.choreID == choreID && $0.effectiveDay <= day }
            .enumerated().max {
                $0.element.effectiveDay == $1.element.effectiveDay
                    ? $0.offset < $1.offset : $0.element.effectiveDay < $1.element.effectiveDay
            }?.element
    }

    func alternatingCompletion(choreID: UUID, on day: CivilDay, memberID: UUID) -> DatedCompletion? {
        guard let revision = configuration(choreID: choreID, on: day),
              revision.mode == .alternating else { return nil }
        return recordedAssignments.last {
            $0.choreID == choreID && $0.day == day && $0.memberID == memberID
                && $0.revisionID == revision.id && $0.mode == .alternating
        }
    }

    func isChoreDeleted(_ choreID: UUID, on day: CivilDay) -> Bool {
        choreDeletions.contains { $0.choreID == choreID && $0.day <= day }
            || occurrenceAwareChoreDeletions.contains { $0.choreID == choreID && $0.day <= day }
    }

    func isActive(_ member: FamilyMember, on day: CivilDay) -> Bool {
        guard let member = self.member(member.id) else { return false }
        if member.isActive(on: day) { return true }
        guard member.role == .parent, member.joinedDay <= day,
              !members.contains(where: { $0.role == .parent && $0.isActive(on: day) }) else { return false }
        return parentCreationOrder.first { id in members.contains { $0.id == id && $0.joinedDay <= day } } == member.id
    }

    func member(_ id: UUID) -> FamilyMember? { members.first { $0.id == id } }

    func scheduledOccurrence(choreID: UUID, revisionID: UUID,
                             on day: CivilDay, hasDone: Bool) -> ChoreOccurrenceDisposition? {
        var active: (factID: UUID, value: ChoreOccurrenceDisposition)?
        let capabilityIndex = occurrenceCapabilityIndex
        factsLoop: for (index, fact) in orderedFacts.enumerated() {
            switch fact.body {
            case .choreDeletion(let deletion) where deletion.choreID == choreID:
                break factsLoop
            case .occurrenceAwareChoreDeletion(let deletion) where deletion.choreID == choreID:
                break factsLoop
            case .occurrence(let value) where value.choreID == choreID
                && value.revisionID == revisionID && value.day == day
                && value.state == .notNeeded:
                active = (fact.id, value)
            case .scheduledOccurrenceRestoration(let restoration) where restoration.choreID == choreID
                && restoration.revisionID == revisionID && restoration.day == day
                && restoration.dispositionFactID == active?.factID && index > capabilityIndex:
                active = nil
            default:
                continue
            }
        }
        return hasDone ? nil : active?.value
    }

    func scheduledNotNeededFactID(choreID: UUID, revisionID: UUID,
                                  on day: CivilDay) -> UUID? {
        var activeID: UUID?
        let capabilityIndex = occurrenceCapabilityIndex
        factsLoop: for (index, fact) in orderedFacts.enumerated() {
            switch fact.body {
            case .choreDeletion(let deletion) where deletion.choreID == choreID:
                break factsLoop
            case .occurrenceAwareChoreDeletion(let deletion) where deletion.choreID == choreID:
                break factsLoop
            case .occurrence(let value) where value.choreID == choreID
                && value.revisionID == revisionID && value.day == day
                && value.state == .notNeeded:
                activeID = fact.id
            case .scheduledOccurrenceRestoration(let restoration) where restoration.choreID == choreID
                && restoration.revisionID == revisionID && restoration.day == day
                && restoration.dispositionFactID == activeID && index > capabilityIndex:
                activeID = nil
            default:
                continue
            }
        }
        return activeID
    }

    func invitation(_ id: UUID) -> FamilyInvitation? { invitations.first { $0.id == id } }
    func invitationClaim(_ id: UUID) -> InvitationClaim? { invitationClaims.first { $0.invitationID == id } }
    func isInvitationRevoked(_ id: UUID) -> Bool { invitationRevocations.contains { $0.invitationID == id } }
}

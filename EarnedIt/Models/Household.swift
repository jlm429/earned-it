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

enum HouseholdFactBody: Codable, Equatable {
    case household(Household)
    case member(FamilyMember)
    case chore(ChoreRevision)
    case completion(DatedCompletion)
    case allowance(AllowanceRevision)
    case excuse(Excuse)
    case request(ProfileRequest)
    case grant(ProfileGrant)
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
    var household: Household?
    var members: [FamilyMember] = []
    var revisions: [ChoreRevision] = []
    var completions: [DatedCompletion] = []
    var recordedAssignments: [DatedCompletion] = []
    private var parentCreationOrder: [UUID] = []
    var allowances: [AllowanceRevision] = []
    var excuses: [Excuse] = []
    var requests: [ProfileRequest] = []
    var grants: [ProfileGrant] = []

    init(facts: [HouseholdFact] = []) {
        var membersByID: [UUID: FamilyMember] = [:]
        var creationSequence: [UUID: Int64] = [:]
        var completionsByKey: [String: DatedCompletion] = [:]
        var excusesByKey: [String: Excuse] = [:]
        var requestsByID: [UUID: ProfileRequest] = [:]
        var grantsByKey: [String: ProfileGrant] = [:]
        for fact in facts.sorted(by: HouseholdFact.precedes) {
            switch fact.body {
            case .household(let value): household = value
            case .member(let value):
                if creationSequence[value.id] == nil { creationSequence[value.id] = fact.sequence }
                membersByID[value.id] = value
            case .chore(let value): revisions.append(value)
            case .completion(let value):
                completionsByKey[value.key] = value
                recordedAssignments.append(value)
            case .allowance(let value): allowances.append(value)
            case .excuse(let value): excusesByKey[value.key] = value
            case .request(let value): requestsByID[value.id] = value
            case .grant(let value): grantsByKey[value.key] = value
            }
        }
        let parents = membersByID.values.filter { $0.role == .parent }.sorted {
            let lhs = creationSequence[$0.id] ?? 0
            let rhs = creationSequence[$1.id] ?? 0
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs < rhs
        }
        parentCreationOrder = parents.map(\.id)
        members = membersByID.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        completions = completionsByKey.values.sorted { $0.key < $1.key }
        excuses = excusesByKey.values.sorted { $0.key < $1.key }
        requests = requestsByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        grants = grantsByKey.values.sorted { $0.key < $1.key }
    }

    func configuration(choreID: UUID, on day: CivilDay) -> ChoreRevision? {
        // Revisions are already in deterministic fact order. Effective date takes priority.
        revisions.filter { $0.choreID == choreID && $0.effectiveDay <= day }
            .enumerated().max {
                $0.element.effectiveDay == $1.element.effectiveDay
                    ? $0.offset < $1.offset : $0.element.effectiveDay < $1.element.effectiveDay
            }?.element
    }

    func isActive(_ member: FamilyMember, on day: CivilDay) -> Bool {
        guard let member = self.member(member.id) else { return false }
        if member.isActive(on: day) { return true }
        guard member.role == .parent, member.joinedDay <= day,
              !members.contains(where: { $0.role == .parent && $0.isActive(on: day) }) else { return false }
        return parentCreationOrder.first { id in members.contains { $0.id == id && $0.joinedDay <= day } } == member.id
    }

    func member(_ id: UUID) -> FamilyMember? { members.first { $0.id == id } }
}

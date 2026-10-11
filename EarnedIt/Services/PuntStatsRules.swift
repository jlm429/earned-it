import Foundation

enum PuntStatsWeek: String, CaseIterable, Identifiable {
    case thisWeek = "This Week"
    case lastWeek = "Last Week"
    var id: String { rawValue }

    func start(today: CivilDay, calendar: Calendar) -> CivilDay {
        let monday = CivilDay(AppCalendar.weekStart(containing: today.date(in: calendar), calendar: calendar),
                              calendar: calendar)
        return monday.adding(days: self == .lastWeek ? -7 : 0, calendar: calendar)
    }
}

struct SiblingPuntStats: Identifiable, Equatable {
    let id: UUID
    let name: String
    var punted = 0
    var covered = 0

    var puntedText: String { "You punted to \(name) \(times(punted))." }
    var coveredText: String { "You covered for \(name) \(times(covered))." }
    private func times(_ count: Int) -> String { "\(count) \(count == 1 ? "time" : "times")" }
}

struct PuntStats: Equatable {
    var siblings: [SiblingPuntStats] = []
    var punted: Int { siblings.reduce(0) { $0 + $1.punted } }
    var covered: Int { siblings.reduce(0) { $0 + $1.covered } }
    var isEmpty: Bool { siblings.isEmpty }
}

enum PuntStatsRules {
    /// Read the same effective ownership as chores, never count raw approval facts.
    static func summary(memberID: UUID, week: PuntStatsWeek, today: CivilDay,
                        snapshot: HouseholdSnapshot) -> PuntStats {
        guard let household = snapshot.household else { return PuntStats() }
        let start = week.start(today: today, calendar: household.calendar)
        let end = start.adding(days: 7, calendar: household.calendar)
        // Effective acceptance requires the decision's civil day to match its scope day.
        let scopes = Set(snapshot.orderedFacts.compactMap { fact -> PuntScope? in
            guard case .puntRequest(let request) = fact.body,
                  request.scope.day >= start, request.scope.day < end else { return nil }
            return request.scope
        })
        var siblings: [UUID: SiblingPuntStats] = [:]
        for scope in scopes {
            guard let owner = PuntRules.originalOwner(scope: scope, snapshot: snapshot),
                  let accepted = PuntRules.project(scope: scope, originalOwnerID: owner,
                                                   snapshot: snapshot, today: today).accepted else { continue }
            let request = accepted.request
            let sent = request.requesterID == memberID
            guard sent || request.recipientID == memberID else { continue }
            let siblingID = sent ? request.recipientID : request.requesterID
            let name = snapshot.member(siblingID)?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            var sibling = siblings[siblingID] ?? SiblingPuntStats(id: siblingID,
                name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "your sibling")
            if sent { sibling.punted += 1 } else { sibling.covered += 1 }
            siblings[siblingID] = sibling
        }
        // Identity order stays stable across renames, equal names, and merged fact order.
        return PuntStats(siblings: siblings.values.sorted { $0.id.uuidString < $1.id.uuidString })
    }
}

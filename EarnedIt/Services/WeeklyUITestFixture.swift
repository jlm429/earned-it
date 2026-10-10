#if DEBUG
import Foundation
import SwiftUI

/// Explicit debug-only fixture. Never used with the actual family journal.
@MainActor
enum WeeklyUITestFixture {
    static var enabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-test-store") && arguments.contains("--ui-test-weekly-fixture")
    }
    static var now = ISO8601DateFormatter().date(from: "2026-09-07T16:00:00Z")!

    static func prepare(_ store: HouseholdStore) throws {
        guard enabled else { return }
        if store.household == nil {
            try store.createFamily(name: "Test Family", parentName: "Test Parent", timeZone: TimeZone(identifier: "America/New_York")!)
            let child = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
            _ = try store.saveMember(name: "Alek", role: .child, avatar: .rocket)
            let monday = try store.saveChore(weekday: .monday, title: "Water plants", mode: .all, memberIDs: [])
            _ = try store.saveChore(weekday: .sunday, title: "Pack school bag", mode: .all, memberIDs: [])
            try store.setCompletion(choreID: monday, memberID: child.id, date: now, state: .done)
            try store.finishSetup()
        }
        if let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-date=") }),
           let date = ISO8601DateFormatter().date(from: String(flag.dropFirst("--ui-test-date=".count))) {
            now = date
            store.significantTimeChanged()
        }
    }
}

/// Seeds only the disposable UI-test journal with legacy and offline facts.
@MainActor
enum PuntUITestFixture {
    static func prepare(repository: HouseholdRepository) throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard WeeklyUITestFixture.enabled,
              arguments.contains("--ui-test-punt-regressions") || arguments.contains("--ui-test-activity-overflow") else { return }
        var store = try HouseholdStore(repository: repository, clock: { WeeklyUITestFixture.now },
                                       automaticSync: false, activityAlerts: DisabledActivityAlerts())
        guard store.household == nil else { return }
        try store.createFamily(name: "Test Family", parentName: "Test Parent",
                               timeZone: TimeZone(identifier: "America/New_York")!)
        let parent = store.selectedMember!
        let hanna = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
        let alek = try store.saveMember(name: "Alek", role: .child, avatar: .rocket)
        try store.finishSetup()
        func scheduled(_ title: String) throws -> UUID {
            try store.saveChore(weekday: .monday, title: title, mode: .alternating,
                                memberIDs: [hanna.id, alek.id], firstAlternatingMemberID: hanna.id)
        }
        func request(_ chore: UUID) throws -> UUID {
            try store.selectProfile(hanna.id)
            try store.requestPunt(choreID: chore, recipientID: alek.id)
            return store.activity.first { $0.punt?.status == .pending && $0.punt?.request.scope.choreID == chore }!.id
        }
        if arguments.contains("--ui-test-activity-overflow") {
            let chore = try scheduled("Punt dishwasher")
            _ = try request(chore)
            try store.selectProfile(parent.id)
            for index in 1...51 {
                _ = try store.saveChore(weekday: .monday, title: "Update \(index)", mode: .all, memberIDs: [])
            }
            try store.selectProfile(alek.id)
            return
        }
        let legacy = try store.saveChore(weekday: .monday, title: "Legacy task", mode: .alternating,
            memberIDs: [hanna.id, alek.id], schedulingMode: .asNeeded, firstAlternatingMemberID: hanna.id)
        let revision = store.snapshot.configuration(choreID: legacy, on: store.day)!
        let householdID = store.household!.id
        var sequence = store.snapshot.orderedFacts.last!.sequence
        func fact(_ body: HouseholdFactBody, author: UUID) -> HouseholdFact {
            sequence += 1
            return HouseholdFact(id: UUID(), householdID: householdID, sequence: sequence,
                authorDeviceID: store.session.deviceID, authorMemberID: author, body: body)
        }
        let activation = fact(.occurrence(ChoreOccurrenceDisposition(choreID: legacy, revisionID: revision.id,
            day: store.day, state: .available, alternatingSkipBehavior: nil,
            recordedByMemberID: parent.id, assignedMemberID: hanna.id)), author: parent.id)
        let completion = fact(.completion(DatedCompletion(choreID: legacy, revisionID: revision.id,
            memberID: hanna.id, day: store.day, state: .done, eligibleMemberIDs: [hanna.id],
            mode: .alternating, recordedByMemberID: hanna.id)), author: hanna.id)
        // Legacy facts must precede the first punt's implicit capability boundary.
        try repository.commit(facts: [activation, completion])
        store = try HouseholdStore(repository: repository, clock: { WeeklyUITestFixture.now },
                                   automaticSync: false, activityAlerts: DisabledActivityAlerts())
        let restore = try scheduled("Restore task")
        _ = try request(restore)
        try store.selectProfile(parent.id)
        let staleChore = try scheduled("Stale task")
        let acceptedID = try request(staleChore)
        try store.selectProfile(alek.id)
        try store.decidePunt(requestFactID: acceptedID, kind: .accepted)
        let scope = store.dailyList().first { $0.choreID == staleChore }!
        try store.selectProfile(parent.id)
        sequence = store.snapshot.orderedFacts.last!.sequence
        let stale = fact(.completion(DatedCompletion(choreID: staleChore, revisionID: scope.configuration.id,
            memberID: hanna.id, day: store.day, state: .done, eligibleMemberIDs: [hanna.id],
            mode: .alternating, recordedByMemberID: hanna.id)), author: hanna.id)
        let duplicate = fact(.puntDecision(PuntDecision(requestFactID: acceptedID,
            scope: PuntRules.scope(for: scope), day: store.day, memberID: alek.id, kind: .accepted)), author: alek.id)
        try repository.commit(facts: [stale, duplicate])
    }
}

/// Uses only the dedicated DEBUG test journal and the household clock.
@MainActor
enum PuntStatsUITestFixture {
    static func prepare(repository: HouseholdRepository) throws {
        guard WeeklyUITestFixture.enabled,
              ProcessInfo.processInfo.arguments.contains("--ui-test-punt-stats") else { return }
        let store = try HouseholdStore(repository: repository, clock: { WeeklyUITestFixture.now },
                                       automaticSync: false, activityAlerts: DisabledActivityAlerts())
        guard store.household == nil else { return }
        try store.createFamily(name: "Test Family", parentName: "Test Parent",
                               timeZone: TimeZone(identifier: "America/New_York")!)
        let parent = store.selectedMember!
        let hanna = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
        let alek = try store.saveMember(name: "Alek", role: .child, avatar: .rocket)
        try store.finishSetup()
        for index in 0..<3 {
            try store.selectProfile(parent.id)
            let sender = index == 0 ? hanna : alek
            let recipient = index == 0 ? alek : hanna
            let chore = try store.saveChore(weekday: .monday, title: "Stats chore \(index)", mode: .alternating,
                memberIDs: [hanna.id, alek.id], firstAlternatingMemberID: sender.id)
            try store.selectProfile(sender.id)
            try store.requestPunt(choreID: chore, recipientID: recipient.id)
            let pending = store.activity.first { $0.punt?.status == .pending }!.id
            try store.selectProfile(recipient.id)
            try store.decidePunt(requestFactID: pending, kind: .accepted)
        }
        WeeklyUITestFixture.now = ISO8601DateFormatter().date(from: "2026-09-14T16:00:00Z")!
        store.refreshDate()
        try store.selectProfile(hanna.id)
    }
}

struct WeeklyTestClockControl: View {
    @Environment(HouseholdStore.self) private var store
    var body: some View {
        if WeeklyUITestFixture.enabled && !ProcessInfo.processInfo.arguments.contains("--ui-test-hide-clock") {
            Menu("Test date") {
                Button("Sunday") { advance("2026-09-13T16:00:00Z") }
                Button("Next Monday") { advance("2026-09-14T16:00:00Z") }
                Button("Next Tuesday") { advance("2026-09-15T16:00:00Z") }
            }
            .accessibilityIdentifier("test-clock")
        }
    }
    private func advance(_ text: String) {
        WeeklyUITestFixture.now = ISO8601DateFormatter().date(from: text)!
        store.significantTimeChanged()
    }
}
#endif

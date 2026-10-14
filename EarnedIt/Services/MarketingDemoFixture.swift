#if DEBUG && targetEnvironment(simulator)
import Foundation

/// A fictional household in a separate simulator journal, using normal store operations.
/// This type and all of its launch arguments are absent from Release and physical devices.
@MainActor
enum MarketingDemoFixture {
    static var enabled: Bool {
        isEnabled(arguments: ProcessInfo.processInfo.arguments)
    }

    static func isEnabled(arguments: [String]) -> Bool {
        return arguments.contains("--ui-test-store") && arguments.contains("--marketing-demo")
    }
    static var now = ISO8601DateFormatter().date(from: "2026-10-05T16:00:00Z")!
    static let displayDate = ISO8601DateFormatter().date(from: "2026-10-14T16:00:00Z")!

    static func prepare(_ store: HouseholdStore,
                        arguments: [String] = ProcessInfo.processInfo.arguments) throws {
        guard isEnabled(arguments: arguments) else { return }
        if store.household == nil {
            try store.createFamily(name: "The Smiths", parentName: "Alex Smith",
                                   timeZone: TimeZone(identifier: "America/New_York")!)
            let parent = store.selectedMember!
            let remy = try store.saveMember(name: "Remy Smith", role: .child, avatar: .fox)
            let piper = try store.saveMember(name: "Piper Smith", role: .child, avatar: .flower)
            try store.saveAllowance(memberID: remy.id, text: "12", currencyCode: "USD", locale: Locale(identifier: "en_US"))
            try store.saveAllowance(memberID: piper.id, text: "10", currencyCode: "USD", locale: Locale(identifier: "en_US"))
            for weekday in Weekday.allCases {
                _ = try store.saveChore(weekday: weekday, title: "Make your bed", category: .personal, mode: .all, memberIDs: [])
                _ = try store.saveChore(weekday: weekday, title: "Set the table", mode: .alternating,
                                        memberIDs: [remy.id, piper.id], firstAlternatingMemberID: remy.id)
                _ = try store.saveChore(weekday: weekday, title: "Pack your school bag", category: .school, mode: .all, memberIDs: [])
                _ = try store.saveChore(weekday: weekday, title: "Water the plants", mode: .particular, memberIDs: [piper.id])
            }
            try store.finishSetup()
            for offset in 0...9 {
                now = store.calendar.date(byAdding: .day, value: offset,
                    to: ISO8601DateFormatter().date(from: "2026-10-05T16:00:00Z")!)!
                store.significantTimeChanged()
                for chore in store.dailyList() {
                    for member in chore.eligibleMembers {
                        // Today's school bags are still to do. Earlier days are fully accounted for.
                        if offset == 9 && chore.configuration.title == "Pack your school bag" { continue }
                        try store.setCompletion(choreID: chore.choreID, memberID: member.id, date: now, state: .done)
                    }
                }
            }
            try store.selectProfile(parent.id)
        }
        now = displayDate
        store.significantTimeChanged()
        let requested = arguments.first { $0.hasPrefix("--marketing-member=") }
            .map { String($0.dropFirst("--marketing-member=".count)) } ?? "alex-smith"
        guard let member = store.snapshot.members.first(where: { $0.displayName.accessibilitySlug == requested }) else {
            throw HouseholdError.malformedData
        }
        try store.selectProfile(member.id)
        // Keep the previous week's accomplishment visible without a transient celebration on capture.
        if member.role == .child { _ = try store.consumeCelebration(for: member.id) }
    }
}
#endif

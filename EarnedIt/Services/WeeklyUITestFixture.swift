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

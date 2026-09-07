import SwiftUI

struct MainRoleView: View {
    @Environment(HouseholdStore.self) private var store
    let user: FamilyMember
    let today: Date

    var body: some View {
        NavigationStack {
            Group {
                switch user.role {
                case .parent: ParentDashboardView(parent: user, today: today)
                case .child: ChildHomeView(child: user, today: today)
                }
            }
            .toolbar {
                #if DEBUG
                ToolbarItem(placement: .topBarTrailing) { WeeklyTestClockControl() }
                #endif
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        store.perform { try store.selectProfile(nil) }
                    } label: { Label("Switch Profile", systemImage: "person.2") }
                    .accessibilityIdentifier("switch-user")
                }
            }
        }
    }
}

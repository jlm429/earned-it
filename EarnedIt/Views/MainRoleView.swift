import SwiftData
import SwiftUI

struct MainRoleView: View {
    @Environment(\.modelContext) private var modelContext
    let user: FamilyUser
    let today: Date

    var body: some View {
        NavigationStack {
            Group {
                switch user.role {
                case .parent:
                    ParentDashboardView(parent: user, today: today)
                case .child:
                    ChildHomeView(child: user, today: today)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        try? SettingsStore.remove(SettingsStore.selectedUserIDKey, context: modelContext)
                    } label: {
                        Label("Switch User", systemImage: "person.2")
                    }
                    .accessibilityIdentifier("switch-user")
                }
            }
        }
    }
}

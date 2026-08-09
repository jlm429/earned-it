import SwiftData
import SwiftUI

struct MainRoleView: View {
    @Environment(\.modelContext) private var modelContext
    let user: FamilyUser

    var body: some View {
        NavigationStack {
            Group {
                switch user.role {
                case .parent:
                    ParentDashboardView(parent: user)
                case .child:
                    ChildHomeView(child: user)
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

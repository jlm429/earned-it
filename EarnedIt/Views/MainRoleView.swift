import SwiftData
import SwiftUI

struct MainRoleView: View {
    @Environment(\.modelContext) private var modelContext
    let user: FamilyUser
    let today: Date
    @State private var errorMessage: String?

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
                        do {
                            try SettingsStore.remove(SettingsStore.selectedUserIDKey, context: modelContext)
                        } catch {
                            modelContext.rollback()
                            errorMessage = error.localizedDescription
                        }
                    } label: {
                        Label("Switch User", systemImage: "person.2")
                    }
                    .accessibilityIdentifier("switch-user")
                }
            }
            .alert("Unable to Switch User", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
        }
    }
}

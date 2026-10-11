import SwiftUI

struct MainRoleView: View {
    @Environment(HouseholdStore.self) private var store
    let user: FamilyMember
    let today: Date
    @State private var activityNavigation = ActivityNavigation.shared

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { activityNavigation.isPresented = true } label: {
                        Label("Activity, \(store.unreadActivityCount) unread", systemImage: "bell.badge")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("family-activity-button")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink {
                            HouseholdSettingsView()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .accessibilityIdentifier("about-settings")
                        Divider()
                        Link("Privacy Policy", destination: AppLinks.privacyPolicy)
                        Link("Support", destination: AppLinks.support)
                    } label: {
                        Label("About Earned It", systemImage: "info.circle")
                    }
                    .accessibilityIdentifier("about-menu")
                }
            }
            .sheet(isPresented: $activityNavigation.isPresented) { FamilyActivityView() }
        }
    }
}

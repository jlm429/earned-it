import SwiftUI

struct WeeklySummaryView: View {
    @Environment(HouseholdStore.self) private var store
    let child: FamilyMember

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ProfileHeader(user: child, title: child.displayName, subtitle: "Weekly allowance & bonus history",
                              accessibilityIdentifier: "history-profile-header")
                ForEach(store.allowanceHistory(for: child.id)) { week in
                    SectionCard(tint: week.earned ? AppTheme.success : nil) {
                        VStack(alignment: .leading, spacing: 16) {
                            AllowanceWeekCard(week: week)
                            BonusHistoryView(memberID: child.id, week: week)
                            if let actor = store.selectedMember {
                                WeeklyItemsView(week: week, actor: actor)
                            }
                        }
                    }
                }
                if !store.bonusHistory(for: child.id).isEmpty {
                    DisclosureGroup("All bonus awards") { BonusHistoryView(memberID: child.id) }
                        .padding().background(ThemedSurface())
                }
                Text("Current week and up to 12 finished weeks. Done and Not Needed count; excused days are excluded. Optional chores cannot replace required items.")
                    .font(.footnote).foregroundStyle(AppTheme.secondaryText)
            }.padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .background(AppTheme.canvas)
        .navigationTitle("Weekly History")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("weekly-summary")
    }
}

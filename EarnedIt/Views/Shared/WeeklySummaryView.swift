import SwiftUI

struct WeeklySummaryView: View {
    @Environment(HouseholdStore.self) private var store
    let child: FamilyMember

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(store.allowanceHistory(for: child.id)) { week in
                    SectionCard {
                        VStack(alignment: .leading, spacing: 16) {
                            AllowanceWeekCard(week: week)
                            if let actor = store.selectedMember {
                                WeeklyItemsView(week: week, actor: actor)
                            }
                        }
                    }
                }
                Text("Current week and up to 12 finished weeks. Done and Not Needed count; excused days are excluded. Optional chores cannot replace required items.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Weekly History")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("weekly-summary")
    }
}

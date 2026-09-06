import SwiftUI

struct ParentChildDetailView: View {
    @Environment(HouseholdStore.self) private var store
    let parent: FamilyMember
    let child: FamilyMember
    let today: Date
    @State private var selectedDate: Date?
    @State private var weekOffset = 0

    private var date: Date { selectedDate ?? today }
    private var weekDate: Date { store.calendar.date(byAdding: .day, value: 7 * weekOffset, to: today) ?? today }
    private var days: [DayFacts] { store.weekFacts(for: child.id, containing: weekDate) }
    private var summary: WeeklySummary {
        WeeklyScoringService.summary(days: days, today: min(today, days.last?.date ?? today), calendar: store.calendar)
    }
    private var isExcused: Bool {
        store.snapshot.excuses.contains { $0.memberID == child.id && $0.day == CivilDay(date, calendar: store.calendar) && $0.isExcused }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SectionCard {
                    HStack(spacing: 12) {
                        AvatarView(user: child)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(child.displayName).font(.title2.bold())
                            Label("\(MetricsService.streak(childID: child.id, snapshot: store.snapshot, today: today)) day streak", systemImage: "flame.fill")
                        }
                    }
                }
                SectionCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Button("Previous Week", systemImage: "chevron.left") { weekOffset -= 1 }
                            Spacer()
                            Text(weekOffset == 0 ? "This week" : weekDate.formatted(.dateTime.month().day())).font(.subheadline)
                            Spacer()
                            Button("Next Week", systemImage: "chevron.right") { weekOffset += 1 }.disabled(weekOffset == 0)
                        }.labelStyle(.iconOnly)
                        WeekStrip(days: days, today: today, compact: false)
                        StatusBadge(status: summary.status)
                        Text("\(summary.accountedCount) of \(summary.expectedCount) expected items accounted for")
                            .accessibilityIdentifier("parent-weekly-count")
                        if let completion = summary.completion {
                            Text(completion, format: .percent.precision(.fractionLength(0))).font(.title.bold())
                        }
                        if let earned = WeeklyScoringService.allowanceEarned(days: days, asOf: today, calendar: store.calendar) {
                            Label(earned ? "Allowance earned" : "Allowance not earned", systemImage: earned ? "checkmark.seal.fill" : "calendar.badge.clock")
                        }
                        Text("Required chores count for each required child. Any-one chores add credit only for the child who contributes. Excused days are excluded.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if child.joinedDay <= store.day {
                    SectionCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Excuse a day").font(.headline)
                            Text("Day").font(.subheadline.weight(.medium))
                        DatePicker("Day", selection: Binding(get: { date }, set: { selectedDate = $0 }),
                                       in: child.joinedDay.date(in: store.calendar)...today, displayedComponents: .date)
                                .labelsHidden()
                            Toggle("Excused from scoring", isOn: Binding(get: { isExcused }, set: { value in
                                store.perform { try store.setExcused(memberID: child.id, date: date, excused: value) }
                            }))
                            .accessibilityIdentifier("excuse-day")
                            Text("An excused day neither extends nor breaks a streak.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(child.displayName)
        .accessibilityIdentifier("parent-child-detail")
    }
}

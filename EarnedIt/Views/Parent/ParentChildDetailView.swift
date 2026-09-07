import SwiftUI

struct ParentChildDetailView: View {
    @Environment(HouseholdStore.self) private var store
    let parent: FamilyMember
    let child: FamilyMember
    let today: Date
    @State private var selectedDate: Date?
    @State private var weekOffset = 0
    @State private var editingAllowance = false

    private var date: Date { selectedDate ?? today }
    private var weekDate: Date { store.calendar.date(byAdding: .day, value: 7 * weekOffset, to: today) ?? today }
    private var days: [DayFacts] { store.weekFacts(for: child.id, containing: weekDate) }
    private var week: AllowanceWeek { store.allowanceWeek(for: child.id, containing: weekDate) }
    private var historyCount: Int { store.allowanceHistory(for: child.id).count }
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
                                .disabled(-weekOffset >= historyCount - 1)
                                .accessibilityIdentifier("previous-week")
                            Spacer()
                            Button("Next Week", systemImage: "chevron.right") { weekOffset += 1 }
                                .disabled(weekOffset == 0).accessibilityIdentifier("next-week")
                        }.labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.large)
                        AllowanceWeekCard(week: week)
                        WeekStrip(days: days, today: today, compact: false)
                        WeeklyItemsView(week: week, actor: parent)
                        NavigationLink("View all retained weeks") { WeeklySummaryView(child: child) }
                            .accessibilityIdentifier("retained-weeks")
                        Text("Current week plus up to 12 finished weeks. Done and Not Needed count; excused days are excluded. Optional contributions do not replace required items.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if store.snapshot.isActive(child, on: store.day) {
                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Current weekly allowance").font(.headline)
                            Text(store.allowanceWeek(for: child.id).amount?.formatted() ?? "Not set")
                            Button("Edit Weekly Allowance") { editingAllowance = true }
                                .buttonStyle(.bordered).controlSize(.large)
                                .accessibilityIdentifier("edit-allowance")
                            Text("Tracks eligibility, not payments. Changes apply to the current week onward.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
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
        .sheet(isPresented: $editingAllowance) {
            AllowanceEditorView(child: child, amount: store.allowanceWeek(for: child.id).amount)
        }
        .accessibilityIdentifier("parent-child-detail")
    }
}

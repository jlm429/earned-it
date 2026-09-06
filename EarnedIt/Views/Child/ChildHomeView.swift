import SwiftUI

struct ChildHomeView: View {
    @Environment(HouseholdStore.self) private var store
    let child: FamilyMember
    let today: Date

    private var weekFacts: [DayFacts] { store.weekFacts(for: child.id) }
    private var streak: Int { MetricsService.streak(childID: child.id, snapshot: store.snapshot, today: today) }
    private var previousAllowance: Bool? {
        let start = AppCalendar.weekStart(containing: today, calendar: store.calendar)
        let previous = store.calendar.date(byAdding: .day, value: -1, to: start) ?? start
        return WeeklyScoringService.allowanceEarned(days: store.weekFacts(for: child.id, containing: previous), asOf: today, calendar: store.calendar)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SectionCard {
                    HStack(spacing: 14) {
                        AvatarView(user: child, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hi, \(child.displayName)!").font(.title2.bold())
                            Text(today, format: .dateTime.weekday(.wide).month(.wide).day()).foregroundStyle(.secondary)
                        }
                    }
                }
                SectionCard {
                    VStack(alignment: .leading, spacing: 14) {
                        StatusBadge(status: WeeklyScoringService.summary(days: weekFacts, today: today, calendar: store.calendar).status)
                        Label("\(streak) day streak", systemImage: "flame.fill").font(.subheadline.weight(.semibold))
                        WeekStrip(days: weekFacts, today: today, compact: true)
                        if let previousAllowance {
                            Label(previousAllowance ? "Allowance earned last week" : "Allowance was not earned last week",
                                  systemImage: previousAllowance ? "checkmark.seal.fill" : "calendar.badge.clock")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        NavigationLink {
                            WeeklySummaryView(child: child, days: weekFacts, today: today, isParentView: false, streak: streak)
                        } label: { Label("View this week", systemImage: "chart.bar.fill") }
                            .accessibilityIdentifier("view-weekly-summary")
                        SyncStatusView()
                    }
                }
                if store.snapshot.excuses.contains(where: { $0.memberID == child.id && $0.day == store.day && $0.isExcused }) {
                    Label("Today is excused. It won’t affect your week or streak.", systemImage: "heart.fill")
                        .foregroundStyle(.blue)
                }
                SharedDailyList(actor: child, date: today)
                SectionCard {
                    let quote = QuoteService.quote(for: today, calendar: store.calendar)
                    VStack(alignment: .leading, spacing: 8) {
                        Label("A thought for today", systemImage: "quote.opening").font(.headline)
                        Text(quote.text)
                        Text(quote.attribution).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Today")
        .refreshable { do { try await store.synchronize() } catch { store.errorMessage = error.localizedDescription } }
        .accessibilityIdentifier("child-home")
    }
}

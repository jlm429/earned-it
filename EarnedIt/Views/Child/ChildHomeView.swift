import SwiftUI

struct ChildHomeView: View {
    @Environment(HouseholdStore.self) private var store
    let child: FamilyMember
    let today: Date
    @State private var celebratingWeekID: String?

    private var current: AllowanceWeek { store.allowanceWeek(for: child.id) }
    private var previous: AllowanceWeek? { store.allowanceHistory(for: child.id).dropFirst().first }
    private var streak: Int { MetricsService.streak(childID: child.id, snapshot: store.snapshot, today: today) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    AvatarView(user: child, size: 62)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hi, \(child.displayName)!").font(.title.bold())
                        Text("A little effort, every day.").foregroundStyle(.primary.opacity(0.7))
                    }
                }
                SectionCard {
                    VStack(alignment: .leading, spacing: 14) {
                        AllowanceWeekCard(week: current)
                        Label("\(streak) day streak", systemImage: "flame.fill").font(.subheadline.weight(.semibold))
                        WeekStrip(days: store.weekFacts(for: child.id), today: today, compact: true)
                        NavigationLink { WeeklySummaryView(child: child) } label: {
                            Label("This week & history", systemImage: "calendar").frame(minHeight: 44)
                        }.accessibilityIdentifier("view-weekly-summary")
                        SyncStatusView()
                    }
                }
                if let previous, !previous.items.isEmpty {
                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            WeekHeading(week: previous)
                            if previous.earned {
                                Label { Text("Earned It").foregroundStyle(.primary) } icon: {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                }
                                    .font(.title2.bold())
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("Earned It. Every required item accounted for.")
                                    .accessibilityIdentifier("earned-it-badge")
                                if celebratingWeekID == previous.id {
                                    Text("Way to go!").font(.title.bold()).accessibilityIdentifier("week-celebration")
                                    Text("You accounted for every required item. Your effort adds up!")
                                } else {
                                    Text("Every required item accounted for.")
                                }
                            } else {
                                Label("Check in with your parent", systemImage: "bubble.left.and.bubble.right")
                                    .font(.headline).accessibilityIdentifier("parent-check-in")
                                Text("\(previous.missing.count == 1 ? "There is 1 missing item" : "There are \(previous.missing.count) missing items") from this finished week. You can review them together. You have a fresh week ahead.")
                                    .font(.subheadline)
                                NavigationLink("Review last week’s items") { WeeklySummaryView(child: child) }
                                    .frame(minHeight: 44).accessibilityIdentifier("review-last-week")
                            }
                        }
                    }
                }
                if store.snapshot.excuses.contains(where: { $0.memberID == child.id && $0.day == store.day && $0.isExcused }) {
                    Label("Today is excused. It won’t affect your week or streak.", systemImage: "heart.fill")
                        .foregroundStyle(.blue)
                }
                SharedDailyList(actor: child, date: today)
                NavigationLink {
                    DatedChoresView(actor: child, day: store.day.adding(days: -1, calendar: store.calendar))
                } label: { Label("Finish yesterday’s items", systemImage: "calendar.badge.clock").frame(minHeight: 44) }
                    .accessibilityIdentifier("yesterday-items")
                Text("You have the scheduled day and the next calendar day to mark an item. After that, ask your parent for a correction. Dates use your family timezone.")
                    .font(.footnote).foregroundStyle(.primary.opacity(0.7))
                SectionCard {
                    let quote = QuoteService.quote(for: today, calendar: store.calendar)
                    VStack(alignment: .leading, spacing: 8) {
                        Label("A thought for today", systemImage: "quote.opening").font(.headline)
                        Text(quote.text)
                        Text(quote.attribution).font(.caption).foregroundStyle(.primary.opacity(0.7))
                    }
                }
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Today")
        .refreshable { do { try await store.synchronize() } catch { store.errorMessage = error.localizedDescription } }
        .task(id: "\(previous?.id ?? "")/\(previous?.earned ?? false)") {
            guard previous?.earned == true else { celebratingWeekID = nil; return }
            do {
                if try store.consumeCelebration(for: child.id) { celebratingWeekID = previous?.id }
            } catch { store.errorMessage = error.localizedDescription }
        }
        .accessibilityIdentifier("child-home")
    }
}

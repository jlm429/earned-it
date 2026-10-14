import SwiftUI

struct ChildHomeView: View {
    @Environment(HouseholdStore.self) private var store
    let child: FamilyMember
    let today: Date
    @State private var celebratingWeekID: String?
    @MotionPreference private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var current: AllowanceWeek { store.allowanceWeek(for: child.id) }
    private var previous: AllowanceWeek? { store.allowanceHistory(for: child.id).dropFirst().first }
    private var streak: Int { MetricsService.streak(childID: child.id, snapshot: store.snapshot, today: today) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ProfileHeader(
                    user: child,
                    title: "Hi, \(child.displayName)!",
                    subtitle: "Small steps. Something to be proud of.",
                    accessibilityIdentifier: "child-profile-header"
                )
                HomeColumns {
                    weekOverview
                } secondary: {
                    VStack(alignment: .leading, spacing: 24) {
                        SharedDailyList(actor: child, date: today)
                        supportingContent
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.canvas)
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .sensoryFeedback(.success, trigger: celebratingWeekID) { _, newValue in
            newValue != nil
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: celebratingWeekID)
        .task(id: "\(previous?.id ?? "")/\(previous?.earned ?? false)") {
            guard previous?.earned == true else { celebratingWeekID = nil; return }
            do {
                if try store.consumeCelebration(for: child.id) { celebratingWeekID = previous?.id }
            } catch { store.errorMessage = error.localizedDescription }
        }
        .accessibilityIdentifier("child-home")
    }

    private var weekOverview: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 18) {
                FeatureHeading(title: "YOUR EFFORT ADDS UP", systemImage: "sparkle")
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 18) { allowance; progressRing }
                } else {
                    HStack(spacing: 16) { allowance; Spacer(minLength: 0); progressRing }
                }
                Text("\(current.accountedCount) of \(current.items.count) required items accounted for this week")
                    .font(.subheadline).foregroundStyle(AppTheme.heroSecondary)
                    .accessibilityIdentifier("child-weekly-count")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HeroSurface())
            SectionCard {
                VStack(alignment: .leading, spacing: 16) {
                    ViewThatFits(in: .horizontal) {
                        HStack { WeekHeading(week: current); Spacer(minLength: 8); streakLabel }
                        VStack(alignment: .leading, spacing: 12) { WeekHeading(week: current); streakLabel }
                    }
                    WeekStrip(days: store.weekFacts(for: child.id), today: today, compact: true)
                    NavigationLink { WeeklySummaryView(child: child) } label: {
                        HStack {
                            Text("This week & history").font(.subheadline.weight(.semibold))
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right").font(.subheadline.weight(.semibold))
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("view-weekly-summary")
                }
            }
            if SyncStatusView.isVisible(in: store) { SyncStatusView() }
        }
    }

    private var allowance: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(current.amount?.formatted() ?? "Your week")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(AppTheme.heroText).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(current.amount?.weeklyAllowanceAccessibilityLabel ?? "Weekly allowance not set")
                .accessibilityIdentifier("child-weekly-allowance-value")
            Text(current.amount == nil ? "Allowance not set" : "Weekly allowance")
                .font(.subheadline).foregroundStyle(AppTheme.heroSecondary)
            Text(current.earned ? "Earned It" : "Every required item counts.")
                .font(.caption).foregroundStyle(AppTheme.heroSecondary)
        }
    }

    private var progressRing: some View {
        ProgressRing(completed: current.accountedCount, total: current.items.count, onHero: true)
    }

    private var streakLabel: some View {
        Label("\(streak) day streak", systemImage: "flame.fill")
            .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.sunshine)
            .padding(8).background(AppTheme.sunshine.opacity(0.10), in: Capsule())
    }

    private var supportingContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let previous, !previous.items.isEmpty {
                SectionCard(tint: previous.earned ? AppTheme.success : AppTheme.warning) {
                    VStack(alignment: .leading, spacing: 12) {
                        WeekHeading(week: previous)
                        if previous.earned {
                            Label { Text("Earned It").foregroundStyle(.primary) } icon: {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(AppTheme.success)
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
                    .foregroundStyle(AppTheme.info)
            }
            NavigationLink {
                DatedChoresView(actor: child, day: store.day.adding(days: -1, calendar: store.calendar))
            } label: { Label("Finish yesterday’s items", systemImage: "calendar.badge.clock").frame(minHeight: 44) }
                .accessibilityIdentifier("yesterday-items")
            Text("You have the scheduled day and the next calendar day to mark an item. After that, ask your parent for a correction. Dates use your family timezone.")
                .font(.footnote).foregroundStyle(AppTheme.secondaryText)
            SectionCard(tint: AppTheme.warning) {
                let quote = QuoteService.quote(for: today, calendar: store.calendar)
                VStack(alignment: .leading, spacing: 8) {
                    Label("A thought for today", systemImage: "quote.opening").font(.headline)
                    Text(quote.text)
                }
            }
        }
    }
}

import SwiftUI

struct ParentDashboardView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    let parent: FamilyMember
    let today: Date
    @State private var selectedDate: Date?

    private var date: Date { selectedDate ?? today }
    private var chores: [DailyChore] {
        ChoreRules.visibleList(store.dailyList(on: date), to: parent)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DailyOverviewCard(chores: chores, familyName: store.household?.name ?? "Your family")
                familyHeader
                HomeColumns {
                    SharedDailyList(actor: parent, date: date)
                } secondary: {
                    weeklyProgress
                }
            }
            .padding(16)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.canvas)
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink { WeekdayListsView() } label: { Label("Chores", systemImage: "calendar") }
                    .accessibilityIdentifier("weekday-lists-link")
                NavigationLink { FamilyManagementView(parent: parent) } label: { Label("Manage Family", systemImage: "person.3") }
                    .accessibilityIdentifier("family-management")
            }
        }
        .refreshable { await store.refresh() }
        .accessibilityIdentifier("parent-dashboard")
    }

    private var familyHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    familyDayLabel
                    Spacer(minLength: 12)
                    familyDayPicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    familyDayLabel
                    familyDayPicker
                }
            }
            if SyncStatusView.isVisible(in: store) { SyncStatusView() }
            if let selectedDate, !store.calendar.isDate(selectedDate, inSameDayAs: today) {
                Button("Back to Today", systemImage: "arrow.uturn.backward") { self.selectedDate = nil }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
    }

    private var weeklyProgress: some View {
        ParentWeeklyProgressView(parent: parent, today: today)
    }

    private var familyDayLabel: some View {
        Label("Family day", systemImage: "calendar")
            .font(.subheadline.weight(.medium)).foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var familyDayPicker: some View {
        DatePicker("Family day", selection: Binding(get: { date }, set: { selectedDate = $0 }),
                   in: min(store.household?.createdDay.date(in: store.calendar) ?? today, today)...today,
                   displayedComponents: .date)
            .labelsHidden().accessibilityIdentifier("family-day")
    }
}

/// Summarizes the visible daily list without changing retained historical outcomes.
struct DailyOverviewCard: View {
    let chores: [DailyChore]
    var familyName = "Your family"
    @Environment(\.dynamicTypeSize) private var typeSize
    private var required: [DailyChore] { chores.filter { !$0.isNotNeeded && !$0.eligibleMembers.isEmpty } }
    private var complete: Int { required.filter(\.isFullyComplete).count }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) { summary; ring }
            } else {
                HStack(spacing: 16) { summary; Spacer(minLength: 0); ring }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeroSurface())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("daily-overview")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            FeatureHeading(title: "THE DAILY PICTURE", systemImage: "sun.max")
            Text(familyName)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(AppTheme.heroText).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("parent-profile-header")
            Text(required.isEmpty ? "No chores expected for this day." : "\(complete) of \(required.count) chores accounted for")
                .font(.subheadline).foregroundStyle(AppTheme.heroSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ring: some View {
        ProgressRing(completed: complete, total: required.count)
    }
}

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
            VStack(alignment: .leading, spacing: 24) {
                familyHeader
                DailyOverviewCard(chores: chores)
                HomeColumns {
                    SharedDailyList(actor: parent, date: date)
                } secondary: {
                    weeklyProgress
                }
            }
            .padding(20)
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
            ProfileHeader(
                user: parent,
                title: store.household?.name ?? "Family overview",
                subtitle: "A little teamwork. A little more together.",
                accessibilityIdentifier: "parent-profile-header"
            )
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
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "Weekly progress", systemImage: "chart.bar.fill")
            if let child = store.snapshot.members.first(where: { $0.role == .child }) {
                WeekHeading(week: store.allowanceWeek(for: child.id))
            }
            ForEach(store.snapshot.members.filter { $0.role == .child }) { child in
                let week = store.allowanceWeek(for: child.id)
                NavigationLink {
                    ParentChildDetailView(parent: parent, child: child, today: today)
                } label: {
                    SectionCard(tint: week.earned ? AppTheme.success : nil) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 12) {
                                AvatarView(user: child, size: 48)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(child.displayName).font(.headline).foregroundStyle(.primary)
                                    Label("\(MetricsService.streak(childID: child.id, snapshot: store.snapshot, today: today)) day streak",
                                          systemImage: "flame.fill")
                                        .font(.caption.weight(.medium)).foregroundStyle(AppTheme.sunshine)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(AppTheme.secondaryText)
                            }
                            if !week.items.isEmpty {
                                WeeklyProgressBar(week: week,
                                    accessibilityIdentifier: "parent-weekly-progress-\(child.displayName.accessibilitySlug)")
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack {
                                    StatusBadge(status: week.status)
                                    Spacer(minLength: 8)
                                    allowanceLabel(week)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    StatusBadge(status: week.status)
                                    allowanceLabel(week)
                                }
                            }
                        }
                    }
                }
                .buttonStyle(PressFeedbackStyle())
                .accessibilityIdentifier("parent-child-\(child.displayName.accessibilitySlug)")
                .accessibilityValue(week.amount?.weeklyAllowanceAccessibilityLabel ?? "Weekly allowance not set")
            }
            if store.children.isEmpty {
                SectionCard {
                    Label("Make room for your family", systemImage: "person.badge.plus").font(.headline)
                    Text("Add a child in Manage Family to see their week here.").foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
    }

    private func allowanceLabel(_ week: AllowanceWeek) -> some View {
        Text(week.amount?.formatted() ?? "Allowance not set")
            .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.secondaryText)
    }

    private var familyDayLabel: some View {
        Label("Family day", systemImage: "calendar")
            .font(.subheadline.weight(.medium)).foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: true, vertical: true)
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
    @Environment(\.dynamicTypeSize) private var typeSize
    private var required: [DailyChore] { chores.filter { !$0.isNotNeeded && !$0.eligibleMembers.isEmpty } }
    private var complete: Int { required.filter(\.isFullyComplete).count }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 20) { summary; ring }
            } else {
                HStack(spacing: 20) { summary; Spacer(minLength: 0); ring }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeroSurface())
        .accessibilityIdentifier("daily-overview")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            FeatureHeading(title: "THE DAILY PICTURE", systemImage: "sun.max")
            Text(required.isEmpty ? "Room to breathe." : complete == required.count ? "All taken care of." : "Good things add up.")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(AppTheme.heroText).fixedSize(horizontal: false, vertical: true)
            Text(required.isEmpty ? "No chores expected for this day." : "\(complete) of \(required.count) chores accounted for")
                .font(.subheadline).foregroundStyle(AppTheme.heroSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ring: some View {
        ProgressRing(completed: complete, total: required.count)
    }
}

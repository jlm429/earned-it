import SwiftData
import SwiftUI

struct ParentDashboardView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \FamilyUser.createdAt) private var users: [FamilyUser]
    @Query private var responsibilities: [Responsibility]
    @Query private var records: [DailyRecord]
    @Query private var excusedDays: [ExcusedDay]

    let parent: FamilyUser
    let today: Date

    @State private var showingNewResponsibility = false
    @State private var showingNewChild = false

    private var children: [FamilyUser] {
        users
            .filter { $0.role == .child }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionCard {
                    HStack(spacing: 14) {
                        AvatarView(user: parent, size: 58)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Family overview")
                                .font(.title2.bold())
                            Text("Today at a glance")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if children.isEmpty {
                    ContentUnavailableView(
                        "No children yet",
                        systemImage: "person.badge.plus",
                        description: Text("Add a child to start their daily list and weekly progress.")
                    )
                    Button("Add Child") { showingNewChild = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("dashboard-add-child")
                } else {
                    ForEach(children) { child in
                        NavigationLink {
                            ParentChildDetailView(parent: parent, child: child, today: today)
                        } label: {
                            ParentChildCard(
                                child: child,
                                today: today,
                                responsibilities: responsibilities,
                                records: records,
                                excusedDays: excusedDays
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("parent-child-\(child.displayName.accessibilitySlug)")
                    }
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(dynamicTypeSize.isAccessibilitySize ? "Dashboard" : "Parent Dashboard")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    FamilyManagementView(parent: parent)
                } label: {
                    Label("Family Management", systemImage: "person.3")
                }
                .accessibilityIdentifier("family-management")

                Button {
                    showingNewResponsibility = true
                } label: {
                    Label("Add Responsibility", systemImage: "plus")
                }
                .disabled(children.isEmpty)
                .accessibilityIdentifier("add-responsibility")
            }
        }
        .sheet(isPresented: $showingNewResponsibility) {
            ResponsibilityFormView(actor: parent, children: children)
        }
        .sheet(isPresented: $showingNewChild) {
            FamilyUserFormView(role: .child)
        }
        .accessibilityIdentifier("parent-dashboard")
    }
}

private struct ParentChildCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let child: FamilyUser
    let today: Date
    let responsibilities: [Responsibility]
    let records: [DailyRecord]
    let excusedDays: [ExcusedDay]

    private var currentItems: [Responsibility] {
        responsibilities.filter {
            $0.assignedChildID == child.id && $0.isExpected(on: today, calendar: AppCalendar.current)
        }
    }

    private var accountedToday: Int {
        currentItems.filter { item in state(for: item).isAccountedFor }.count
    }

    private var unmarkedToday: Int {
        currentItems.filter { state(for: $0) == .unmarked }.count
    }

    private var weekFacts: [DayFacts] {
        MetricsService.currentWeekFacts(
            childID: child.id,
            today: today,
            responsibilities: responsibilities,
            records: records,
            excusedDays: excusedDays
        )
    }

    private var streak: Int {
        StreakService.currentStreak(
            days: MetricsService.streakFacts(
                childID: child.id,
                today: today,
                responsibilities: responsibilities,
                records: records,
                excusedDays: excusedDays
            ),
            today: today
        )
    }

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    AvatarView(user: child)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(child.displayName)
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        StatusBadge(status: WeeklyScoringService.summary(days: weekFacts, today: today).status)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        metrics
                    }
                } else {
                    HStack(spacing: 18) {
                        metrics
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(child.displayName), \(accountedToday) of \(currentItems.count) accounted today, \(unmarkedToday) unmarked, \(streak) day streak")
    }

    @ViewBuilder
    private var metrics: some View {
        metric("Today", value: "\(accountedToday)/\(currentItems.count)", systemImage: "checkmark.circle")
        metric("Unmarked", value: "\(unmarkedToday)", systemImage: "circle.dotted")
        metric("Streak", value: "\(streak)", systemImage: "flame")
    }

    private func metric(_ label: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func state(for responsibility: Responsibility) -> DailyStateKind {
        records.first {
            $0.responsibilityID == responsibility.id
                && AppCalendar.isPersistedDay($0.day, sameDayAs: today)
        }?.state ?? .unmarked
    }
}

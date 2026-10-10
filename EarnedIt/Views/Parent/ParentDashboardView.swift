import SwiftUI

struct ParentDashboardView: View {
    @Environment(HouseholdStore.self) private var store
    let parent: FamilyMember
    let today: Date
    @State private var selectedDate: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionCard(tint: AppTheme.accent) {
                    VStack(alignment: .leading, spacing: 14) {
                        ProfileHeader(
                            user: parent,
                            title: store.household?.name ?? "Family overview",
                            subtitle: "Today at a glance",
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
                        if let selectedDate, !store.calendar.isDate(selectedDate, inSameDayAs: today) {
                            Button("Back to Today", systemImage: "arrow.uturn.backward") { self.selectedDate = nil }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                        }
                        SyncStatusView()
                    }
                }
                SharedDailyList(actor: parent, date: selectedDate ?? today)
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
                            HStack(spacing: 12) {
                                AvatarView(user: child)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(child.displayName).font(.headline).foregroundStyle(.primary)
                                    StatusBadge(status: week.status)
                                    if !week.items.isEmpty {
                                        WeeklyProgressBar(
                                            week: week,
                                            accessibilityIdentifier: "parent-weekly-progress-\(child.displayName.accessibilitySlug)"
                                        )
                                    }
                                    Label(week.amount?.formatted() ?? "Allowance not set", systemImage: "banknote")
                                        .font(.subheadline)
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("parent-child-\(child.displayName.accessibilitySlug)")
                }
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.canvas)
        .navigationTitle("Family Today")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink { WeekdayListsView() } label: { Label("Chores", systemImage: "calendar") }
                    .accessibilityIdentifier("weekday-lists-link")
                NavigationLink { FamilyManagementView(parent: parent) } label: { Label("Manage Family", systemImage: "person.3") }
                    .accessibilityIdentifier("family-management")
            }
        }
        .refreshable { do { try await store.synchronize() } catch { store.errorMessage = error.localizedDescription } }
        .accessibilityIdentifier("parent-dashboard")
    }

    private var familyDayLabel: some View {
        Label("Family day", systemImage: "calendar")
            .font(.subheadline.weight(.medium))
    }

    private var familyDayPicker: some View {
        DatePicker(
            "Family day",
            selection: Binding(get: { selectedDate ?? today }, set: { selectedDate = $0 }),
            in: min(store.household?.createdDay.date(in: store.calendar) ?? today, today)...today,
            displayedComponents: .date
        )
        .labelsHidden()
        .accessibilityIdentifier("family-day")
    }
}

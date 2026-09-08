import SwiftUI

struct ParentDashboardView: View {
    @Environment(HouseholdStore.self) private var store
    let parent: FamilyMember
    let today: Date
    @State private var selectedDate: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            AvatarView(user: parent, size: 58)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(store.household?.name ?? "Family overview").font(.title2.bold())
                                Text("See who helped and who’s still needed.").foregroundStyle(.primary.opacity(0.7))
                            }
                        }
                        Text("Family day").font(.subheadline.weight(.medium))
                        DatePicker("Family day", selection: Binding(
                            get: { selectedDate ?? today }, set: { selectedDate = $0 }
                        ), in: min(store.household?.createdDay.date(in: store.calendar) ?? today, today)...today, displayedComponents: .date)
                            .labelsHidden()
                            .accessibilityIdentifier("family-day")
                        if let selectedDate, !store.calendar.isDate(selectedDate, inSameDayAs: today) {
                            Button("Back to Today") { self.selectedDate = nil }
                        }
                        SyncStatusView()
                    }
                }
                SharedDailyList(actor: parent, date: selectedDate ?? today)
                Text("Weekly progress").font(.title2.bold())
                if let child = store.snapshot.members.first(where: { $0.role == .child }) {
                    WeekHeading(week: store.allowanceWeek(for: child.id))
                    Text("A fresh allowance week starts every Monday.").font(.subheadline).foregroundStyle(.primary.opacity(0.7))
                }
                ForEach(store.snapshot.members.filter { $0.role == .child }) { child in
                    NavigationLink {
                        ParentChildDetailView(parent: parent, child: child, today: today)
                    } label: {
                        SectionCard {
                            HStack(spacing: 12) {
                                AvatarView(user: child)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(child.displayName).font(.headline).foregroundStyle(.primary)
                                    StatusBadge(status: store.allowanceWeek(for: child.id).status)
                                    Text(store.allowanceWeek(for: child.id).amount?.formatted() ?? "Allowance not set")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("parent-child-\(child.displayName.accessibilitySlug)")
                }
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Family Today")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink { WeekdayListsView() } label: { Label("Weekday Lists", systemImage: "calendar") }
                    .accessibilityIdentifier("weekday-lists-link")
                NavigationLink { FamilyManagementView(parent: parent) } label: { Label("Family & Sharing", systemImage: "person.3") }
                    .accessibilityIdentifier("family-management")
            }
        }
        .refreshable { do { try await store.synchronize() } catch { store.errorMessage = error.localizedDescription } }
        .accessibilityIdentifier("parent-dashboard")
    }
}

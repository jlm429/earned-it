import SwiftUI

struct ParentWeeklyProgressView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let parent: FamilyMember
    let today: Date
    @State private var selectedWeek: CivilDay?

    private var weeks: [CivilDay] { AllowanceService.progressWeekStarts(snapshot: store.snapshot, today: today) }
    private var selectedIndex: Int { selectedWeek.flatMap { weeks.firstIndex(of: $0) } ?? max(0, weeks.count - 1) }
    private var children: [FamilyMember] { store.snapshot.members.filter { $0.role == .child } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "Weekly progress", systemImage: "chart.bar.fill")
            if children.isEmpty {
                SectionCard {
                    Label("Make room for your family", systemImage: "person.badge.plus").font(.headline)
                    Text("Add a child in Manage Family to see their week here.").foregroundStyle(AppTheme.secondaryText)
                }
            } else if !weeks.isEmpty {
                navigation
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(weeks, id: \.self) { start in
                            weekPage(start)
                                .containerRelativeFrame(.horizontal)
                                .accessibilityHidden(start != (selectedWeek ?? weeks.last))
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                .defaultScrollAnchor(.trailing)
                .scrollPosition(id: $selectedWeek)
                .accessibilityIdentifier("parent-weekly-pager")
                .onAppear { if selectedWeek == nil { selectedWeek = weeks.last } }
                .onChange(of: weeks) { _, available in
                    if let selectedWeek, !available.contains(selectedWeek) { self.selectedWeek = available.last }
                }
                Text(weeks.count < 7 ? "History starts with your family’s first week." : "Swipe to review the previous six weeks.")
                    .font(.footnote).foregroundStyle(AppTheme.secondaryText)
            }
        }
    }

    private var navigation: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { previousButton; Spacer(); nextButton }
                    currentButton
                }
            } else {
                HStack(spacing: 12) {
                    previousButton
                    Spacer(minLength: 0)
                    currentButton
                    Spacer(minLength: 0)
                    nextButton
                }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var previousButton: some View {
        Button("Previous week", systemImage: "chevron.left") { move(by: -1) }
            .disabled(selectedIndex == 0)
            .accessibilityIdentifier("progress-previous-week")
    }

    private var nextButton: some View {
        Button("Next week", systemImage: "chevron.right") { move(by: 1) }
            .disabled(selectedIndex == weeks.count - 1)
            .accessibilityIdentifier("progress-next-week")
    }

    private var currentButton: some View {
        Button { select(weeks.last) } label: {
            Text("Current week").fixedSize(horizontal: false, vertical: true)
        }
        .disabled(selectedIndex == weeks.count - 1)
        .accessibilityIdentifier("progress-current-week")
    }

    private func move(by offset: Int) {
        let index = selectedIndex + offset
        guard weeks.indices.contains(index) else { return }
        select(weeks[index])
    }

    private func select(_ week: CivilDay?) {
        withAnimation(reduceMotion ? nil : .snappy) { selectedWeek = week }
    }

    private func weekPage(_ start: CivilDay) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let child = children.first {
                WeekHeading(week: store.allowanceWeek(for: child.id, containing: start.date(in: store.calendar)))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("progress-week-\(start)")
            }
            ForEach(children) { child in
                let week = store.allowanceWeek(for: child.id, containing: start.date(in: store.calendar))
                NavigationLink {
                    ParentChildDetailView(parent: parent, child: child, today: today,
                                          initialWeekOffset: (weeks.firstIndex(of: start) ?? 0) - (weeks.count - 1))
                } label: {
                    childCard(child, week: week)
                }
                .buttonStyle(PressFeedbackStyle())
                .accessibilityIdentifier("parent-child-\(child.displayName.accessibilitySlug)")
                .accessibilityValue(week.amount?.weeklyAllowanceAccessibilityLabel ?? "Weekly allowance not set")
            }
        }
        .padding(.horizontal, 1)
        .accessibilityElement(children: .contain)
    }

    private func childCard(_ child: FamilyMember, week: AllowanceWeek) -> some View {
        SectionCard(tint: week.earned ? AppTheme.success : nil) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    AvatarView(user: child, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(child.displayName).font(.headline).foregroundStyle(.primary)
                        if !week.isFinished {
                            Label("\(MetricsService.streak(childID: child.id, snapshot: store.snapshot, today: today)) day streak",
                                  systemImage: "flame.fill")
                                .font(.caption.weight(.medium)).foregroundStyle(AppTheme.sunshine)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(AppTheme.secondaryText)
                }
                if week.items.isEmpty {
                    Text("No required items recorded").font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                } else {
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

    private func allowanceLabel(_ week: AllowanceWeek) -> some View {
        Text(week.amount?.formatted() ?? "Allowance not set")
            .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.secondaryText)
    }
}

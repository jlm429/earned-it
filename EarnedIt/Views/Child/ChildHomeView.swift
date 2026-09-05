import SwiftData
import SwiftUI

struct ChildHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var responsibilities: [Responsibility]
    @Query private var records: [DailyRecord]
    @Query private var excusedDays: [ExcusedDay]

    let child: FamilyUser
    let today: Date

    @State private var presentedForm: PresentedResponsibility?
    @State private var errorMessage: String?

    private var todayItems: [Responsibility] {
        responsibilities
            .filter { $0.assignedChildID == child.id && $0.isExpected(on: today, calendar: AppCalendar.current) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
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

    private var weeklySummary: WeeklySummary {
        WeeklyScoringService.summary(days: weekFacts, today: today)
    }

    private var previousAllowanceEarned: Bool? {
        let completedWeek = MetricsService.previousCompletedWeekFacts(
            childID: child.id,
            today: today,
            responsibilities: responsibilities,
            records: records,
            excusedDays: excusedDays
        )
        return WeeklyScoringService.allowanceEarned(days: completedWeek, asOf: today)
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

    private var isTodayExcused: Bool {
        excusedDays.contains {
            $0.childID == child.id && AppCalendar.isPersistedDay($0.day, sameDayAs: today)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                greetingCard
                quoteCard
                progressCard
                todayList
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Today")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentedForm = .new
                } label: {
                    Label("Add Responsibility", systemImage: "plus")
                }
                .accessibilityIdentifier("add-responsibility")
            }
        }
        .sheet(item: $presentedForm) { presentation in
            ResponsibilityFormView(
                actor: child,
                children: [child],
                existing: presentation.responsibility
            )
        }
        .alert("Unable to Update", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .accessibilityIdentifier("child-home")
    }

    private var greetingCard: some View {
        SectionCard {
            HStack(spacing: 14) {
                AvatarView(user: child, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hi, \(child.displayName)!")
                        .font(.title2.bold())
                    Text(today, format: .dateTime.weekday(.wide).month(.wide).day())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var quoteCard: some View {
        let quote = QuoteService.quote(for: today)
        return SectionCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("A thought for today", systemImage: "quote.opening")
                    .font(.headline)
                Text(quote.text)
                    .font(.body)
                Text(quote.attribution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("daily-quote-\(quote.id)")
    }

    private var progressCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    StatusBadge(status: weeklySummary.status)
                    Spacer()
                    Label("\(streak) day streak", systemImage: "flame.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                WeekStrip(days: weekFacts, today: today, compact: true)
                if let previousAllowanceEarned {
                    Label(
                        previousAllowanceEarned ? "Allowance earned last week" : "Allowance was not earned last week",
                        systemImage: previousAllowanceEarned ? "checkmark.seal.fill" : "calendar.badge.clock"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("previous-week-allowance")
                }
                NavigationLink {
                    WeeklySummaryView(
                        child: child,
                        days: weekFacts,
                        today: today,
                        isParentView: false,
                        streak: streak
                    )
                } label: {
                    Label("View this week", systemImage: "chart.bar.fill")
                }
                .accessibilityIdentifier("view-weekly-summary")
            }
        }
    }

    private var todayList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today’s List")
                    .font(.title2.bold())
                Spacer()
                let accounted = todayItems.filter { state(for: $0).isAccountedFor }.count
                Text("\(accounted) of \(todayItems.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(accounted) of \(todayItems.count) accounted for")
            }

            if isTodayExcused {
                Label("Today is excused. It will not affect your week or streak.", systemImage: "heart.fill")
                    .foregroundStyle(.blue)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }

            if todayItems.isEmpty {
                ContentUnavailableView(
                    "Nothing expected today",
                    systemImage: "checkmark.circle",
                    description: Text("You can add a responsibility whenever you’re ready.")
                )
                Button("Add Chore") { presentedForm = .new }
                    .accessibilityIdentifier("empty-add-chore")
            } else {
                ForEach(todayItems) { responsibility in
                    ResponsibilityRow(
                        responsibility: responsibility,
                        state: state(for: responsibility),
                        availableStates: [.unmarked, .done, .notNeeded],
                        isExcused: isTodayExcused,
                        canManageDefinition: PermissionService.canManageDefinition(user: child, responsibility: responsibility),
                        onStateChange: { update($0, for: responsibility) },
                        onEdit: { presentedForm = .edit(responsibility) },
                        onArchive: { archive(responsibility) }
                    )
                }
            }
        }
    }

    private func state(for responsibility: Responsibility) -> DailyStateKind {
        records.first {
            $0.responsibilityID == responsibility.id
                && AppCalendar.isPersistedDay($0.day, sameDayAs: today)
        }?.state ?? .unmarked
    }

    private func update(_ state: DailyStateKind, for responsibility: Responsibility) {
        do {
            try DataCoordinator.setState(
                state,
                actor: child,
                responsibility: responsibility,
                date: today,
                records: records,
                context: modelContext
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func archive(_ responsibility: Responsibility) {
        do {
            try DataCoordinator.archive(responsibility, actor: child, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum PresentedResponsibility: Identifiable {
    case new
    case edit(Responsibility)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let item): item.id.uuidString
        }
    }

    var responsibility: Responsibility? {
        if case .edit(let item) = self { return item }
        return nil
    }
}

import SwiftData
import SwiftUI

struct ParentChildDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var responsibilities: [Responsibility]
    @Query private var records: [DailyRecord]
    @Query private var excusedDays: [ExcusedDay]

    let parent: FamilyUser
    let child: FamilyUser

    @State private var today = Date.now
    @State private var selectedDate = Date.now
    @State private var presentedForm: PresentedResponsibility?
    @State private var errorMessage: String?

    private var selectedItems: [Responsibility] {
        responsibilities
            .filter { $0.assignedChildID == child.id && $0.isExpected(on: selectedDate, calendar: AppCalendar.current) }
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

    private var summary: WeeklySummary {
        WeeklyScoringService.summary(days: weekFacts, today: today)
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

    private var isSelectedDayExcused: Bool {
        excusedDays.contains {
            $0.childID == child.id && AppCalendar.current.isDate($0.day, inSameDayAs: selectedDate)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                summaryCard
                dayPickerCard

                if isSelectedDayExcused {
                    Label("This day is excused and excluded from scoring and streak changes.", systemImage: "heart.fill")
                        .foregroundStyle(.blue)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("excused-day-banner")
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Responsibilities")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if selectedItems.isEmpty {
                        ContentUnavailableView(
                            "No expected items",
                            systemImage: "minus.circle",
                            description: Text("This day is neutral.")
                        )
                    } else {
                        ForEach(selectedItems) { responsibility in
                            ResponsibilityRow(
                                responsibility: responsibility,
                                state: state(for: responsibility),
                                availableStates: DailyStateKind.allCases,
                                isExcused: false,
                                canManageDefinition: true,
                                onStateChange: { update($0, for: responsibility) },
                                onEdit: { presentedForm = .edit(responsibility) },
                                onArchive: { archive(responsibility) }
                            )
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(child.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentedForm = .new
                } label: {
                    Label("Add Responsibility", systemImage: "plus")
                }
                .accessibilityIdentifier("add-responsibility-child-detail")
            }
        }
        .sheet(item: $presentedForm) { presentation in
            ResponsibilityFormView(
                actor: parent,
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
        .accessibilityIdentifier("parent-child-detail")
    }

    private var summaryCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    AvatarView(user: child)
                    VStack(alignment: .leading, spacing: 4) {
                        StatusBadge(status: summary.status)
                        Text("\(summary.accountedCount) of \(summary.expectedCount) this week")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("\(streak)", systemImage: "flame.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("\(streak) day streak")
                }
                WeekStrip(days: weekFacts, today: today, compact: false)
                NavigationLink {
                    WeeklySummaryView(
                        child: child,
                        days: weekFacts,
                        today: today,
                        isParentView: true,
                        streak: streak
                    )
                } label: {
                    Label("Open Weekly Summary", systemImage: "chart.bar.fill")
                }
                .accessibilityIdentifier("view-weekly-summary")
            }
        }
    }

    private var dayPickerCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("Day", selection: $selectedDate, in: ...today, displayedComponents: .date)
                    .accessibilityIdentifier("parent-day-picker")
                Button {
                    toggleExcused()
                } label: {
                    Label(
                        isSelectedDayExcused ? "Remove Excused Day" : "Excuse Entire Day",
                        systemImage: isSelectedDayExcused ? "heart.slash" : "heart"
                    )
                }
                .accessibilityIdentifier("toggle-excused-day")
            }
        }
    }

    private func state(for responsibility: Responsibility) -> DailyStateKind {
        records.first {
            $0.responsibilityID == responsibility.id && AppCalendar.current.isDate($0.day, inSameDayAs: selectedDate)
        }?.state ?? .unmarked
    }

    private func update(_ state: DailyStateKind, for responsibility: Responsibility) {
        do {
            try DataCoordinator.setState(
                state,
                actor: parent,
                responsibility: responsibility,
                date: selectedDate,
                today: today,
                records: records,
                context: modelContext
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleExcused() {
        do {
            try DataCoordinator.toggleExcused(
                childID: child.id,
                date: selectedDate,
                excusedDays: excusedDays,
                context: modelContext
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func archive(_ responsibility: Responsibility) {
        do {
            try DataCoordinator.archive(responsibility, actor: parent, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

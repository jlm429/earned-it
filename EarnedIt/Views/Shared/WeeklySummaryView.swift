import SwiftUI

struct WeeklySummaryView: View {
    @Environment(\.calendar) private var calendar
    let child: FamilyMember
    let days: [DayFacts]
    let today: Date
    let isParentView: Bool
    let streak: Int

    private var summary: WeeklySummary {
        WeeklyScoringService.summary(days: days, today: today, calendar: calendar)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SectionCard {
                    HStack(spacing: 14) {
                        AvatarView(user: child)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(child.displayName)
                                .font(.title2.bold())
                            StatusBadge(status: summary.status)
                        }
                    }
                }

                SectionCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Monday through Sunday")
                            .font(.headline)
                        WeekStrip(days: days, today: today, compact: !isParentView)
                    }
                }

                SectionCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("\(streak) day streak", systemImage: "flame.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        if isParentView {
                            Text("\(summary.accountedCount) of \(summary.expectedCount) expected items accounted for")
                                .foregroundStyle(.secondary)
                            if let completion = summary.completion {
                                Text(completion, format: .percent.precision(.fractionLength(0)))
                                    .font(.title.bold())
                                    .accessibilityLabel("Weekly completion \(Int(completion * 100)) percent")
                            }
                        } else {
                            Text(childAllowanceMessage)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if isParentView {
                    SectionCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Status guide")
                                .font(.headline)
                            StatusBadge(status: .green)
                            Text("95% or more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            StatusBadge(status: .yellow)
                            Text("85% through under 95%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            StatusBadge(status: .red)
                            Text("Below 85%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Weekly Summary")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("weekly-summary")
    }

    private var childAllowanceMessage: String {
        if let earned = WeeklyScoringService.allowanceEarned(days: days, asOf: today, calendar: calendar) {
            return earned ? "Allowance earned this week" : "Keep going next week"
        }
        switch summary.status {
        case .green, .yellow: return "On track for allowance"
        case .red: return "A little more to go"
        case .neutral: return "No items expected yet"
        }
    }
}

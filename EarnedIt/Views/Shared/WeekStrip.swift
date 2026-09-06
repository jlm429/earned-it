import SwiftUI

struct WeekStrip: View {
    let days: [DayFacts]
    let today: Date
    let compact: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Environment(\.calendar) private var calendar

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize && !compact {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, facts in
                    accessibleDay(facts)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, facts in
                    standardDay(facts)
                }
            }
        }
    }

    private func accessibleDay(_ facts: DayFacts) -> some View {
        let status = WeeklyScoringService.dayStatus(facts, today: today, calendar: calendar)
        return HStack(spacing: 12) {
            Image(systemName: status.symbolName)
                .font(.caption.bold())
                .foregroundStyle(status.tint)
                .frame(width: 30, height: 30)
                .background(status.tint.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(facts.date, format: .dateTime.weekday(.wide))
                    .font(.caption.weight(.semibold))
                Text(status.shortLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: facts, status: status))
        .accessibilityIdentifier(accessibilityIdentifier(for: facts))
    }

    private func standardDay(_ facts: DayFacts) -> some View {
        let status = WeeklyScoringService.dayStatus(facts, today: today, calendar: calendar)
        return VStack(spacing: 6) {
            Text(facts.date, format: .dateTime.weekday(.narrow))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Image(systemName: status.symbolName)
                .font(.caption.bold())
                .foregroundStyle(status.tint)
                .frame(width: 30, height: 30)
                .background(status.tint.opacity(0.13), in: Circle())
            if !compact {
                Text(status.shortLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: facts, status: status))
        .accessibilityIdentifier(accessibilityIdentifier(for: facts))
    }

    private func accessibilityLabel(for facts: DayFacts, status: DayStatus) -> String {
        "\(facts.date.formatted(.dateTime.weekday(.wide))), \(status.rawValue)"
    }

    private func accessibilityIdentifier(for facts: DayFacts) -> String {
        "week-day-\(facts.date.formatted(.dateTime.weekday(.abbreviated)).lowercased())"
    }
}

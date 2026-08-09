import SwiftUI

struct WeekStrip: View {
    let days: [DayFacts]
    let today: Date
    let compact: Bool

    private let calendar = AppCalendar.current

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, facts in
                let status = WeeklyScoringService.dayStatus(facts, today: today, calendar: calendar)
                VStack(spacing: 6) {
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
                .accessibilityLabel("\(facts.date.formatted(.dateTime.weekday(.wide))), \(status.rawValue)")
                .accessibilityIdentifier("week-day-\(facts.date.formatted(.dateTime.weekday(.abbreviated)).lowercased())")
            }
        }
    }
}

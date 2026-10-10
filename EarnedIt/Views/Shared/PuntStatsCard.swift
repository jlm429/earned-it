import SwiftUI

struct PuntStatsCard: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var week: PuntStatsWeek = .thisWeek
    let memberID: UUID

    var body: some View {
        let stats = PuntStatsRules.summary(memberID: memberID, week: week, today: store.day,
                                           snapshot: store.snapshot)
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Punt Stats", systemImage: "person.2")
                    .font(.headline)
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) { weekButtons }
                } else {
                    HStack(spacing: 8) { weekButtons }
                }
                if stats.isEmpty {
                    Text("No accepted punts \(week == .thisWeek ? "this" : "last") week.")
                        .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("punt-stats-empty")
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 24) { totals(stats) }.fixedSize()
                        VStack(alignment: .leading, spacing: 8) { totals(stats) }
                    }
                    ForEach(stats.siblings) { sibling in
                        VStack(alignment: .leading, spacing: 4) {
                            if sibling.punted > 0 { Text(sibling.puntedText) }
                            if sibling.covered > 0 { Text(sibling.coveredText) }
                        }
                        .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("punt-stats")
    }

    private var weekButtons: some View {
        ForEach(PuntStatsWeek.allCases) { option in
            Button { week = option } label: {
                Label(option.rawValue, systemImage: week == option ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline.weight(week == option ? .semibold : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(week == option ? AppTheme.accent : AppTheme.secondaryText)
            .accessibilityAddTraits(week == option ? .isSelected : [])
            .accessibilityIdentifier(option == .thisWeek ? "punt-stats-this-week" : "punt-stats-last-week")
        }
    }

    @ViewBuilder
    private func totals(_ stats: PuntStats) -> some View {
        Text("You punted: \(stats.punted)")
            .accessibilityIdentifier("punt-stats-punted")
        Text("You covered: \(stats.covered)")
            .accessibilityIdentifier("punt-stats-covered")
    }
}

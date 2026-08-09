import SwiftUI

struct ResponsibilityRow: View {
    let responsibility: Responsibility
    let state: DailyStateKind
    let availableStates: [DailyStateKind]
    let isExcused: Bool
    let canManageDefinition: Bool
    let onStateChange: (DailyStateKind) -> Void
    let onEdit: () -> Void
    let onArchive: () -> Void

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: responsibility.category.symbolName)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(responsibility.title)
                            .font(.headline)
                            .accessibilityIdentifier("responsibility-row-\(responsibility.title.accessibilitySlug)")
                        Text(responsibility.category.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !responsibility.notes.isEmpty {
                            Text(responsibility.notes)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if canManageDefinition {
                        Menu {
                            Button("Edit", systemImage: "pencil", action: onEdit)
                            Button("Archive", systemImage: "archivebox", role: .destructive, action: onArchive)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                        }
                        .accessibilityLabel("Manage \(responsibility.title)")
                        .accessibilityIdentifier("responsibility-actions-\(responsibility.title.accessibilitySlug)")
                    }
                }

                if isExcused {
                    Label("Excused day", systemImage: "heart.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                } else {
                    Menu {
                        ForEach(availableStates) { option in
                            Button {
                                onStateChange(option)
                            } label: {
                                Label(option.rawValue, systemImage: option.symbolName)
                            }
                            .accessibilityIdentifier("set-state-\(option.rawValue.accessibilitySlug)")
                        }
                    } label: {
                        HStack {
                            Label(state.rawValue, systemImage: state.symbolName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(state.tint)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .accessibilityLabel("\(responsibility.title) state, \(state.rawValue)")
                    .accessibilityHint("Choose a daily state")
                    .accessibilityIdentifier("state-control-\(responsibility.title.accessibilitySlug)")
                }
            }
        }
    }
}

import SwiftUI

struct ResponsibilityRow: View {
    @Environment(HouseholdStore.self) private var store
    let chore: DailyChore
    let actor: FamilyMember

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 8) {
                ChoreFlowLayout {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(chore.configuration.title).font(.headline)
                        Text(statusLabel).font(.caption).foregroundStyle(.primary.opacity(0.7))
                            .accessibilityIdentifier("full-status-\(chore.configuration.title.accessibilitySlug)")
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    ForEach(chore.eligibleMembers) { member in
                        memberControl(member)
                    }
                }
                if !chore.configuration.notes.isEmpty {
                    Text(chore.configuration.notes).font(.subheadline).foregroundStyle(.primary.opacity(0.7))
                }
                if chore.eligibleMembers.isEmpty {
                    Text("No eligible children for this date.").font(.subheadline).foregroundStyle(.primary.opacity(0.7))
                }
                if actor.role == .parent && !chore.historicalContributions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Earlier assignment history").font(.caption.weight(.semibold))
                            .foregroundStyle(.primary.opacity(0.7))
                        ForEach(chore.historicalContributions) { contribution in
                            historicalContributionLabel(contribution)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chore-\(chore.configuration.title.accessibilitySlug)")
    }

    private var completionLabel: String {
        if chore.eligibleMembers.isEmpty { return "No eligible children" }
        if chore.isFullyComplete {
            let status = chore.notNeededMembers.isEmpty ? "Complete" : "Accounted for"
            return chore.requiredMembers.isEmpty ? "Any one: \(status)" : status
        }
        return chore.requiredMembers.isEmpty ? "Any one child needed" : "\(chore.remainingMembers.count) still needed"
    }

    private var statusLabel: String {
        guard let turn = chore.turnLabel(for: actor) else { return completionLabel }
        return chore.turnOwner == nil ? turn : "\(turn) · \(completionLabel)"
    }

    @ViewBuilder
    private func memberControl(_ member: FamilyMember) -> some View {
        let state = chore.state(for: member.id)
        let nextState: DailyStateKind = state == .done ? (chore.day == chore.today || actor.role == .child ? .unmarked : .missed) : .done
        let canChange = !store.cloudIsReadOnly && !store.cloudAccessBlocked
            && PermissionService.canSetState(actor: actor, target: member.id, chore: chore, state: nextState)
        if canChange {
            Button { update(member, state: nextState) } label: {
                memberLabel(member, state: state)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(member.displayName), \(chore.configuration.title), \(state.rawValue)")
            .accessibilityValue(state.rawValue)
            .accessibilityHint(state == .done ? "Tap to undo completion. More states in Actions." : "Tap to mark done. More states in Actions.")
            .accessibilityAddTraits(state == .done ? .isSelected : [])
            .accessibilityIdentifier("state-\(chore.configuration.title.accessibilitySlug)-\(member.displayName.accessibilitySlug)")
            .contextMenu { stateActions(for: member) }
            .accessibilityActions { stateActions(for: member) }
        } else {
            memberLabel(member, state: state)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(member.displayName), \(chore.configuration.title), \(state.rawValue)")
                .accessibilityValue("View only")
                .accessibilityIdentifier("state-\(chore.configuration.title.accessibilitySlug)-\(member.displayName.accessibilitySlug)")
        }
    }

    private func memberLabel(_ member: FamilyMember, state: DailyStateKind) -> some View {
        HStack(spacing: 6) {
            Image(systemName: state.symbolName)
                .foregroundStyle(state == .done ? Color.primary : state.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName).font(.subheadline.weight(.medium))
                if state == .notNeeded || state == .missed {
                    Text(state == .notNeeded ? "Not needed" : "Missed").font(.caption)
                }
            }
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 44, minHeight: 44)
        .background(state.isAccountedFor ? state.tint.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private func historicalContributionLabel(_ contribution: HistoricalContribution) -> some View {
        HStack(spacing: 6) {
            Image(systemName: contribution.state.symbolName)
                .foregroundStyle(contribution.state.tint)
                .accessibilityHidden(true)
            Text("\(contribution.member.displayName): \(contribution.state.rawValue)").font(.caption)
        }
        .foregroundStyle(.primary.opacity(0.7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(contribution.member.displayName), earlier assignment, \(contribution.state.rawValue)")
        .accessibilityValue("View only")
        .accessibilityIdentifier("history-\(chore.configuration.title.accessibilitySlug)-\(contribution.member.displayName.accessibilitySlug)")
    }

    @ViewBuilder
    private func stateActions(for member: FamilyMember) -> some View {
        ForEach(DailyStateKind.allCases.filter {
            PermissionService.canSetState(actor: actor, target: member.id, chore: chore, state: $0)
        }) { state in
            Button(state.rawValue, systemImage: state.symbolName) { update(member, state: state) }
        }
    }

    private func update(_ member: FamilyMember, state: DailyStateKind) {
        store.perform {
            try store.setCompletion(choreID: chore.id, memberID: member.id,
                                    date: chore.day.date(in: store.calendar), state: state)
        }
    }
}

/// Keeps names at their readable size and wraps whole controls before narrowing long text.
private struct ChoreFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let available = max(0, width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing })
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, available), height: nil))
            if x > 0 && x + size.width > available {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: available, height: y + rowHeight), frames)
    }
}

struct SharedDailyList: View {
    @Environment(HouseholdStore.self) private var store
    let actor: FamilyMember
    let date: Date

    private var chores: [DailyChore] {
        ChoreRules.visibleList(store.dailyList(on: date), to: actor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.calendar.isDate(date, inSameDayAs: store.today) ? "Today’s Chores" : "Chores for This Day").font(.title2.bold())
            if chores.isEmpty {
                ContentUnavailableView("Nothing expected", systemImage: "checkmark.circle",
                    description: Text(actor.role == .parent ? "Configure a shared weekday list to get started." : "Enjoy your day. Your family’s list has nothing for you here."))
            } else {
                ForEach(chores) { chore in ResponsibilityRow(chore: chore, actor: actor) }
                if !store.cloudIsReadOnly && !store.cloudAccessBlocked && chores.contains(where: { chore in
                    chore.eligibleMembers.contains { member in
                        PermissionService.canSetState(actor: actor, target: member.id, chore: chore, state: .done)
                    }
                }) {
                    Text("Tap a name to mark done or undo. Touch and hold for other states.")
                        .font(.caption).foregroundStyle(.primary.opacity(0.7))
                }
            }
        }
    }
}

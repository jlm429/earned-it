import SwiftUI

struct SwapControls: View {
    @Environment(HouseholdStore.self) private var store
    let chore: DailyChore
    let actor: FamilyMember
    @State private var recipient: FamilyMember?

    private var exchange: ProjectedSwap? {
        store.swaps.last { $0.request.scope.choreID == chore.choreID
            && ($0.request.scope.day == chore.day || $0.request.repaymentDay == chore.day && $0.wasAccepted) }
    }

    var body: some View {
        if let exchange {
            SwapSummary(swap: exchange)
            if exchange.status == .pending && actor.id == exchange.request.requesterID {
                Button("Cancel Swap Request", role: .cancel) {
                    store.perform { try store.decideSwap(requestFactID: exchange.id, kind: .cancelled) }
                }.frame(minHeight: 44).accessibilityIdentifier("cancel-swap-request")
            }
        }
        if !store.swapCandidates(for: chore).isEmpty {
            Menu {
                ForEach(store.swapCandidates(for: chore), id: \.0.id) { child, _ in
                    Button("Ask \(child.displayName)") { recipient = child }
                }
            } label: {
                Label("Swap Turns", systemImage: "arrow.triangle.2.circlepath")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("request-swap-\(chore.configuration.title.accessibilitySlug)")
            .confirmationDialog("Swap with \(recipient?.displayName ?? "a sibling")?", isPresented: Binding(
                get: { recipient != nil }, set: { if !$0 { recipient = nil } }
            ), titleVisibility: .visible) {
                if let recipient {
                    Button("Send Swap Request") {
                        store.perform { try store.requestSwap(choreID: chore.choreID, recipientID: recipient.id) }
                        self.recipient = nil
                    }
                }
                Button("Cancel", role: .cancel) { recipient = nil }
            } message: {
                let day = store.swapCandidates(for: chore).first { $0.0.id == recipient?.id }?.1
                Text("They cover today. You cover their \(day.map { AppCalendar.displayDay($0, calendar: store.calendar) } ?? "next scheduled") turn of this chore. They must accept today before anything changes. You can each have one swap until both turns are finished.")
            }
        }
    }
}

struct SwapSummary: View {
    @Environment(HouseholdStore.self) private var store
    let swap: ProjectedSwap

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(status, systemImage: swap.status == .pending ? "clock" : "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.medium)).foregroundStyle(AppTheme.info)
            if swap.wasAccepted {
                Text("\(name(swap.request.recipientID)): \(AppCalendar.displayDay(swap.request.scope.day, calendar: store.calendar)) · \(name(swap.request.requesterID)): \(AppCalendar.displayDay(swap.request.repaymentDay, calendar: store.calendar))")
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
            }
        }
    }

    private func name(_ id: UUID) -> String { store.snapshot.member(id)?.displayName ?? "Sibling" }

    private var status: String {
        switch swap.status {
        case .pending: "Waiting for \(name(swap.request.recipientID)). Your turns stay as they are."
        case .accepted: "Swap accepted"
        case .declined: "Swap declined. Your turn stays with you."
        case .cancelled: "Request cancelled"
        case .expired: "Request ended. Check your current turns."
        case .completed: "Both turns accounted for. Thank you, team!"
        case .ended: "Exchange ended. Recorded chores still count."
        case .released: "Plans changed. The return turn is released."
        }
    }
}

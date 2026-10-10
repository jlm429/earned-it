import SwiftUI

struct PuntControls: View {
    @Environment(HouseholdStore.self) private var store
    let chore: DailyChore
    let actor: FamilyMember
    @State private var recipient: FamilyMember?

    var body: some View {
        if let projection = store.puntProjection(for: chore) {
            VStack(alignment: .leading, spacing: 8) {
                if let pending = projection.pending {
                    Label("Waiting for \(store.snapshot.member(pending.request.recipientID)?.displayName ?? "approval")",
                          systemImage: "clock")
                        .font(.subheadline).foregroundStyle(AppTheme.info)
                    Text("The current child stays responsible until this request is accepted.")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    if actor.id == pending.request.requesterID {
                        Button("Cancel Punt Request", role: .cancel) {
                            store.perform { try store.decidePunt(requestFactID: pending.id, kind: .cancelled) }
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("cancel-punt-\(chore.configuration.title.accessibilitySlug)")
                    }
                } else if let accepted = projection.accepted {
                    Label("Punt accepted by \(store.snapshot.member(accepted.request.recipientID)?.displayName ?? "child")",
                          systemImage: "person.2.fill")
                        .font(.subheadline).foregroundStyle(AppTheme.success)
                } else if !store.puntRecipients(for: chore).isEmpty {
                    if let last = projection.requests.last {
                        Text("Punt \(last.status.rawValue). Your turn stays with you.")
                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    }
                    Menu {
                        ForEach(store.puntRecipients(for: chore)) { child in
                            Button("Ask \(child.displayName)") { recipient = child }
                        }
                    } label: {
                        Label("Request a Punt", systemImage: "arrow.right.arrow.left")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.cloudIsReadOnly || store.cloudAccessBlocked)
                    .accessibilityIdentifier("request-punt-\(chore.configuration.title.accessibilitySlug)")
                }
            }
            .tint(AppTheme.accent)
            .confirmationDialog("Ask \(recipient?.displayName ?? "a sibling") to take this turn?", isPresented: Binding(
                get: { recipient != nil }, set: { if !$0 { recipient = nil } }
            ), titleVisibility: .visible) {
                if let recipient {
                    Button("Send Punt Request") {
                        store.perform {
                            try store.requestPunt(choreID: chore.choreID, occurrenceID: chore.occurrenceID,
                                                  recipientID: recipient.id)
                        }
                        self.recipient = nil
                    }
                }
                Button("Cancel", role: .cancel) { recipient = nil }
            } message: {
                Text("They must accept before this chore becomes their responsibility. Only today's occurrence changes. Future turns stay in order.")
            }
        }
    }
}

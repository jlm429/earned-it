import SwiftUI

/// Connection is derived from the existing invitation claim, never a second access grant.
struct ChildConnectionRow: View {
    @Environment(HouseholdStore.self) private var store
    let child: FamilyMember
    var onInvitationPresentationChange: (Bool) -> Void = { _ in }
    @State private var inviting = false

    private var connected: Bool {
        store.snapshot.invitations.contains {
            $0.memberID == child.id && !store.snapshot.isInvitationRevoked($0.id)
                && store.snapshot.invitationClaim($0.id) != nil
        } || store.snapshot.grants.contains { $0.memberIDs.contains(child.id) }
    }

    private var invitationWaiting: Bool {
        store.familyInvitations.contains { $0.memberID == child.id && store.invitationStatus($0) == .available }
    }

    var body: some View {
        Group {
            if connected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(AppTheme.success)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label(invitationWaiting ? "Invitation waiting" : "Not connected yet", systemImage: "person.crop.circle.badge.clock")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    if store.session.location == nil || store.session.location?.isOwner == true {
                        Button("Connect \(child.displayName)", systemImage: "person.badge.plus") { inviting = true }
                            .frame(minHeight: 44).accessibilityIdentifier("connect-\(child.displayName.accessibilitySlug)")
                    } else {
                        Text("Ask the family owner to send an invitation.").font(.footnote)
                    }
                }
            }
        }
        .sheet(isPresented: $inviting) { FamilyInvitationView(childID: child.id) }
        .onChange(of: inviting) { _, presented in onInvitationPresentationChange(presented) }
    }
}

struct ChildConnectionStep: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let child: FamilyMember
    @State private var inviting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    AvatarView(user: child, size: 52)
                    Text("\(child.displayName) is on the team!")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Connect their device next so they can see and check off their own chores.")
                    .fixedSize(horizontal: false, vertical: true)
                if store.session.location == nil || store.session.location?.isOwner == true {
                    Button { inviting = true } label: {
                        Label { Text("Connect Now").fixedSize(horizontal: false, vertical: true) } icon: {
                            Image(systemName: "person.badge.plus")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("connect-child-now")
                } else {
                    Text("Ask the family owner to send an invitation for this profile.")
                }
                Button { dismiss() } label: {
                    Text("Add Device Later").fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered).controlSize(.large)
                .accessibilityIdentifier("connect-child-later")
                Text("No device yet? Their profile and chores are ready. “Not connected yet” stays visible in your family until they join.")
                    .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.canvas)
        .sheet(isPresented: $inviting) { FamilyInvitationView(childID: child.id) }
    }
}

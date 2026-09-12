import SwiftUI

struct FamilyManagementView: View {
    @Environment(HouseholdStore.self) private var store
    let parent: FamilyMember
    @State private var addingRole: UserRole?
    @State private var editing: FamilyMember?
    @State private var archiving: FamilyMember?
    @State private var approving: ProfileRequest?
    @State private var inviting = false
    @State private var revokingInvitation: FamilyInvitation?
    @State private var busy = false

    var body: some View {
        List {
            Section("Family members") {
                ForEach(store.snapshot.members.filter { $0.archivedFrom == nil || store.snapshot.isActive($0, on: store.day) }) { member in
                    HStack(spacing: 12) {
                        AvatarView(user: member, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(member.displayName).font(.headline)
                            Text(member.role.title).font(.caption).foregroundStyle(.secondary)
                            if member.joinedDay > store.day { Text("Joins lists tomorrow").font(.caption) }
                            if member.archivedFrom != nil && !store.snapshot.isActive(member, on: store.tomorrow) { Text("Archived from tomorrow").font(.caption) }
                        }
                        Spacer()
                        Menu {
                            Button("Edit Member") { editing = member }
                            Button("Archive Member", role: .destructive) { archiving = member }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Manage \(member.displayName)")
                    }
                }
                Button("Add Parent") { addingRole = .parent }
                Button("Add Child") { addingRole = .child }.accessibilityIdentifier("family-add-child")
            }
            Section("Invite & connect") {
                SyncStatusView()
                if store.session.location == nil {
                    Button("Connect Family to iCloud") { run { try await store.connect() } }
                        .disabled(busy).accessibilityIdentifier("connect-icloud")
                }
                Button("Invite a Parent or Child", systemImage: "person.badge.plus") { inviting = true }
                    .disabled(busy)
                    .accessibilityIdentifier("invite-profile")
                if store.session.location != nil, store.session.location?.isOwner != true {
                    Text("Apple requires the family owner to create and revoke participant access. Other approved parents retain full family management access in Earned It.")
                }
                Text("Each invitation is bound to one role and profile, expires after 24 hours, and uses Apple’s private one-time sharing access.")
                    .font(.footnote).foregroundStyle(.secondary)
                if busy { ProgressView("Connecting…") }
            }
            if !store.familyInvitations.isEmpty {
                Section("Invitations") {
                    ForEach(store.familyInvitations) { invitation in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(invitationMember(invitation)).font(.headline)
                            Label(invitationStatusText(invitation), systemImage: invitationStatusSymbol(invitation))
                                .font(.caption).foregroundStyle(.secondary)
                            if store.invitationStatus(invitation) != .revoked {
                                Button(store.invitationStatus(invitation) == .consumed ? "Remove Installation Access" : "Revoke Invitation",
                                       role: .destructive) {
                                    revokingInvitation = invitation
                                }
                                .accessibilityIdentifier("revoke-invitation")
                            }
                        }
                    }
                }
            }
            if !store.pendingRequests.isEmpty {
                Section("Profile requests") {
                    ForEach(store.pendingRequests) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(request.deviceName).font(.headline)
                            Text(profileNames(request.memberIDs)).foregroundStyle(.secondary)
                            Button("Review Profiles") { approving = request }
                                .accessibilityIdentifier("review-profile-request")
                            Button("Decline", role: .destructive) {
                                store.perform { try store.approve(request, memberIDs: []) }
                            }
                        }
                    }
                }
            }
            if !store.snapshot.grants.isEmpty {
                Section("Approved installations") {
                    ForEach(store.snapshot.grants.filter { !$0.memberIDs.isEmpty }, id: \.key) { grant in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.snapshot.requests.first { $0.id == grant.requestID }?.deviceName ?? "Family installation")
                                .font(.headline)
                            Text(profileNames(grant.memberIDs)).foregroundStyle(.secondary)
                            Button("Remove Profile Access", role: .destructive) {
                                store.perform { try store.revoke(grant) }
                            }
                        }
                    }
                }
            }
            Section { NavigationLink("Settings") { HouseholdSettingsView() }.accessibilityIdentifier("household-settings") }
        }
        .navigationTitle("Family & Sharing")
        .sheet(item: $addingRole) { role in FamilyUserFormView(role: role) }
        .sheet(item: $editing) { member in FamilyUserFormView(role: member.role, existing: member) }
        .sheet(isPresented: $inviting) { FamilyInvitationView() }
        .alert("Archive family member?", isPresented: Binding(
            get: { archiving != nil }, set: { if !$0 { archiving = nil } }
        )) {
            Button("Archive from Tomorrow", role: .destructive) {
                if let member = archiving { store.perform { try store.archiveMember(member.id) } }
                archiving = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Today’s expectations and dated history stay intact.") }
        .alert("Approve these profiles?", isPresented: Binding(
            get: { approving != nil }, set: { if !$0 { approving = nil } }
        )) {
            Button("Approve Profiles") {
                if let request = approving { store.perform { try store.approve(request, memberIDs: request.memberIDs) } }
                approving = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(approving.map { "\($0.deviceName) can switch between: \(profileNames($0.memberIDs)). Parent profiles can manage the family." } ?? "")
        }
        .alert("Revoke this invitation?", isPresented: Binding(
            get: { revokingInvitation != nil }, set: { if !$0 { revokingInvitation = nil } }
        )) {
            Button("Revoke Access", role: .destructive) {
                if let invitation = revokingInvitation { run { try await store.revokeInvitation(invitation) } }
                revokingInvitation = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The code will stop working. If it was already used, this installation loses Apple and profile access without changing family data.")
        }
        .accessibilityIdentifier("family-management-screen")
    }

    private func profileNames(_ ids: [UUID]) -> String {
        ids.compactMap { store.snapshot.member($0) }.map { "\($0.displayName) (\($0.role.title))" }.joined(separator: ", ")
    }

    private func invitationMember(_ invitation: FamilyInvitation) -> String {
        guard let member = store.snapshot.member(invitation.memberID) else { return invitation.role.title }
        return "\(member.displayName) · \(member.role.title)"
    }

    private func invitationStatusText(_ invitation: FamilyInvitation) -> String {
        switch store.invitationStatus(invitation) {
        case .available: "Expires \(invitation.expiresAt.formatted(date: .abbreviated, time: .shortened))"
        case .expired: "Expired"
        case .revoked: "Revoked"
        case .consumed: "Joined"
        }
    }

    private func invitationStatusSymbol(_ invitation: FamilyInvitation) -> String {
        switch store.invitationStatus(invitation) {
        case .available: "clock"
        case .expired: "clock.badge.exclamationmark"
        case .revoked: "xmark.shield"
        case .consumed: "checkmark.shield"
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { store.errorMessage = error.localizedDescription }
        }
    }
}

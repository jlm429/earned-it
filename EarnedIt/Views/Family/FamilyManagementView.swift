import SwiftUI

struct FamilyManagementView: View {
    @Environment(HouseholdStore.self) private var store
    let parent: FamilyMember
    @State private var addingRole: UserRole?
    @State private var editing: FamilyMember?
    @State private var archiving: FamilyMember?
    @State private var approving: ProfileRequest?
    @State private var inviting = false
    @State private var recoveredInvitation: RecoveredFamilyInvitation?
    @State private var revokingInvitation: FamilyInvitation?
    @State private var busy = false

    var body: some View {
        List {
            Section("Family Members") {
                ForEach(store.snapshot.members.filter { $0.archivedFrom == nil || store.snapshot.isActive($0, on: store.day) }) { member in
                    HStack(spacing: 12) {
                        AvatarView(user: member, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(member.displayName).font(.headline)
                            Text(member.role.title).font(.caption).foregroundStyle(.secondary)
                            if member.joinedDay > store.day { Text("Joins lists tomorrow").font(.caption) }
                            if member.archivedFrom != nil && !store.snapshot.isActive(member, on: store.tomorrow) { Text("Leaves family lists tomorrow").font(.caption) }
                        }
                        Spacer()
                        Menu {
                            Button("Edit Member") { editing = member }
                            Button("Remove Family Member", role: .destructive) { archiving = member }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Manage \(member.displayName)")
                    }
                }
                Button("Add Child") { addingRole = .child }.accessibilityIdentifier("family-add-child")
                Button("Add Parent Profile") { addingRole = .parent }
            }
            Section("Sharing") {
                SyncStatusView()
                Button("Invite Family Member", systemImage: "person.badge.plus") { inviting = true }
                    .disabled(busy)
                    .accessibilityIdentifier("invite-profile")
                if store.session.location != nil, store.session.location?.isOwner != true {
                    Text("Only the person who first shared this family can invite or remove devices. Other parents can still manage the family in Earned It.")
                }
                Text("Each invitation is for one family member and expires after 24 hours. Earned It will turn on family sharing automatically when needed.")
                    .font(.footnote).foregroundStyle(.secondary)
                if busy { ProgressView("Updating…") }
            }
            if !store.familyInvitations.isEmpty {
                Section("Invitations") {
                    ForEach(store.familyInvitations) { invitation in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(invitationMember(invitation)).font(.headline)
                            Label(invitationStatusText(invitation), systemImage: invitationStatusSymbol(invitation))
                                .font(.caption).foregroundStyle(.secondary)
                            VStack(spacing: 12) {
                                if store.canRecoverInvitation(invitation) {
                                    Button { recover(invitation) } label: {
                                        invitationActionLabel(
                                            "Show Invitation Again",
                                            systemImage: "qrcode"
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.large)
                                    .disabled(busy)
                                    .accessibilityLabel(
                                        "Show invitation again for \(invitationMember(invitation))"
                                    )
                                    .accessibilityHint("Opens the existing one-time invitation without creating another.")
                                    .accessibilityIdentifier("recover-invitation")
                                }
                                if store.invitationStatus(invitation) != .revoked {
                                    Button(role: .destructive) {
                                        revokingInvitation = invitation
                                    } label: {
                                        invitationActionLabel(
                                            store.invitationStatus(invitation) == .consumed
                                                ? "Remove Device Access" : "Revoke Invitation",
                                            systemImage: "xmark.shield"
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.large)
                                    .tint(.red)
                                    .disabled(busy)
                                    .accessibilityLabel(
                                        "\(store.invitationStatus(invitation) == .consumed ? "Remove device access" : "Revoke invitation") for \(invitationMember(invitation))"
                                    )
                                    .accessibilityHint("Requires confirmation before removing invitation access.")
                                    .accessibilityIdentifier("revoke-invitation")
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }
            if !store.pendingRequests.isEmpty {
                Section("Access Requests") {
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
                Section("Devices with Access") {
                    ForEach(store.snapshot.grants.filter { !$0.memberIDs.isEmpty }, id: \.key) { grant in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.snapshot.requests.first { $0.id == grant.requestID }?.deviceName ?? "Family device")
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
        .refreshable { await refreshFamily() }
        .navigationTitle("Manage Family")
        .sheet(item: $addingRole) { role in FamilyUserFormView(role: role) }
        .sheet(item: $editing) { member in FamilyUserFormView(role: member.role, existing: member) }
        .sheet(isPresented: $inviting) { FamilyInvitationView() }
        .sheet(item: $recoveredInvitation) { invitation in
            RecoveredFamilyInvitationView(recovered: invitation)
        }
        .alert(archiving.map { "Remove \"\($0.displayName)\"?" } ?? "Remove Family Member?", isPresented: Binding(
            get: { archiving != nil }, set: { if !$0 { archiving = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let member = archiving { store.perform { try store.archiveMember(member.id) } }
                archiving = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("They will leave new family lists tomorrow. Their past activity stays in family history.") }
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
            Text("The code will stop working. If it was already used, that device will lose family access without changing family data.")
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

    private func invitationActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { store.errorMessage = error.localizedDescription }
        }
    }

    private func recover(_ invitation: FamilyInvitation) {
        busy = true
        Task {
            defer { busy = false }
            do { recoveredInvitation = try await store.recoverInvitation(invitation) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    private func refreshFamily() async {
        do { try await store.synchronize() }
        catch { store.errorMessage = error.localizedDescription }
    }
}

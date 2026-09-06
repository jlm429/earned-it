import CloudKit
import SwiftUI

struct FamilyManagementView: View {
    @Environment(HouseholdStore.self) private var store
    let parent: FamilyMember
    @State private var addingRole: UserRole?
    @State private var editing: FamilyMember?
    @State private var archiving: FamilyMember?
    @State private var approving: ProfileRequest?
    @State private var cloudShare: SharePresentation?
    @State private var busy = false

    var body: some View {
        List {
            Section("Family members") {
                ForEach(store.snapshot.members.filter { $0.archivedFrom == nil || $0.isActive(on: store.day) }) { member in
                    HStack(spacing: 12) {
                        AvatarView(user: member, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(member.displayName).font(.headline)
                            Text(member.role.title).font(.caption).foregroundStyle(.secondary)
                            if member.joinedDay > store.day { Text("Joins lists tomorrow").font(.caption) }
                            if member.archivedFrom != nil { Text("Archived from tomorrow").font(.caption) }
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
                if store.session.location == nil || store.session.location?.isOwner == true {
                    Button("Invite or Manage Sharing", systemImage: "person.badge.plus") {
                        run { cloudShare = SharePresentation(share: try await store.makeShare()) }
                    }
                    .disabled(busy).accessibilityIdentifier("invite-family")
                } else {
                    Text("The family owner manages iCloud invitations. You can approve profile requests below.")
                }
                Text("Invite trusted family members. An iCloud editor can change all shared records. Profile permissions guide this app’s controls; they are not an iCloud security boundary.")
                    .font(.footnote).foregroundStyle(.secondary)
                if busy { ProgressView("Connecting…") }
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
        .sheet(item: $cloudShare) { presentation in
            CloudSharingView(share: presentation.share) { error in
                if let error { store.errorMessage = error.localizedDescription }
                store.scheduleSync()
            }
        }
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
        .accessibilityIdentifier("family-management-screen")
    }

    private func profileNames(_ ids: [UUID]) -> String {
        ids.compactMap { store.snapshot.member($0) }.map { "\($0.displayName) (\($0.role.title))" }.joined(separator: ", ")
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { store.errorMessage = error.localizedDescription }
        }
    }
}

private struct SharePresentation: Identifiable {
    let id = UUID()
    let share: CKShare
}

struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let onCompletion: (Error?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCompletion: onCompletion) }
    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share,
            container: CKContainer(identifier: CloudKitHouseholdTransport.containerIdentifier))
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onCompletion: (Error?) -> Void
        init(onCompletion: @escaping (Error?) -> Void) { self.onCompletion = onCompletion }
        func itemTitle(for csc: UICloudSharingController) -> String? { "Earned It Family" }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) { onCompletion(error) }
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) { onCompletion(nil) }
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) { onCompletion(nil) }
    }
}

import SwiftUI

struct UserSelectionView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var invitationCode = ""
    @State private var redeeming = false
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Who’s using Earned It?")
                        .font(.title.bold()).multilineTextAlignment(.center)
                    Text(store.household?.name ?? "Family").foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                        ForEach(store.profiles) { member in
                            Button { store.perform { try store.selectProfile(member.id) } } label: {
                                VStack(spacing: 10) {
                                    AvatarView(user: member, size: 72)
                                    Text(member.displayName).font(.headline).foregroundStyle(.primary)
                                    Text(member.role.title).font(.subheadline).foregroundStyle(.secondary)
                                }
                                .multilineTextAlignment(.center)
                                .padding(18).frame(maxWidth: .infinity, minHeight: 154)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Continue as \(member.displayName), \(member.role.title)")
                            .accessibilityIdentifier("user-card-\(member.displayName.accessibilitySlug)")
                        }
                    }
                    if store.profiles.isEmpty {
                        invitationAccess
                        NavigationLink("Connection Settings") { HouseholdSettingsView() }
                    }
                    SyncStatusView()
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Profiles")
            .sheet(isPresented: $scanning) {
                InvitationScannerSheet { payload in
                    if let credential = InvitationCredential(text: payload) { invitationCode = credential.code }
                    redeem(payload)
                }
            }
            .accessibilityIdentifier("profile-selection")
        }
    }

    private var invitationAccess: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Finish joining", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.title2.bold())
                Text("Enter or scan the one-time code a parent created for this profile. You cannot choose a different role or family member here.")
                TextField("XXXX-XXXX-XX", text: $invitationCode)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textContentType(.oneTimeCode)
                    .font(.body.monospaced())
                    .accessibilityIdentifier("connected-invitation-code")
                if store.currentRequest != nil {
                    Text("A request from an older app version is still pending. A parent can approve it, or send a new invitation code.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 10) {
                    Button("Use Invitation") { redeem(invitationCode) }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .disabled(redeeming || InvitationCode.normalized(invitationCode) == nil)
                        .accessibilityIdentifier("redeem-connected-invitation")
                    Button("Scan", systemImage: "qrcode.viewfinder") { scanning = true }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .disabled(redeeming)
                }
                if redeeming { ProgressView("Checking invitation…") }
            }
        }
    }

    private func redeem(_ text: String) {
        guard !redeeming else { return }
        redeeming = true
        Task {
            defer { redeeming = false }
            do { try await store.redeemInvitation(text) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}

struct SyncStatusView: View {
    @Environment(HouseholdStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.session.location != nil {
                Label(store.syncMessage, systemImage: store.cloudAccessBlocked ? "exclamationmark.icloud" : "icloud")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("sync-status")
                if !store.rejectedChanges.isEmpty {
                    Text("\(store.rejectedChanges.count) changes kept on this device but not shared. Ask a parent to restore profile access, then refresh. Archived profiles need parent review.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("rejected-changes")
                }
                if store.pendingCount > 0 { Text("\(store.pendingCount) changes waiting to sync").font(.caption).foregroundStyle(.secondary) }
                Button("Refresh Family", systemImage: "arrow.clockwise") {
                    Task { do { try await store.synchronize() } catch { store.errorMessage = error.localizedDescription } }
                }
                .disabled(store.isSyncing)
                .accessibilityIdentifier("refresh-family")
            }
        }
    }
}

import SwiftUI

struct UserSelectionView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var requestedIDs: Set<UUID> = []
    @State private var deviceName = "Family device"

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
                        profileRequest
                        NavigationLink("Connection Settings") { HouseholdSettingsView() }
                    }
                    SyncStatusView()
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Profiles")
            .accessibilityIdentifier("profile-selection")
        }
    }

    private var profileRequest: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Connect your profiles").font(.title2.bold())
                Text("Choose the people who use this installation. A parent will approve your request in Family & Sharing.")
                TextField("Device label", text: $deviceName).textFieldStyle(.roundedBorder)
                ForEach(store.snapshot.members.filter { store.snapshot.isActive($0, on: store.day) }) { member in
                    Toggle("\(member.displayName) · \(member.role.title)", isOn: Binding(
                        get: { requestedIDs.contains(member.id) },
                        set: { if $0 { requestedIDs.insert(member.id) } else { requestedIDs.remove(member.id) } }
                    ))
                }
                if store.currentRequest != nil {
                    Text("Request sent. Refresh after a parent approves.").foregroundStyle(.secondary)
                }
                Button("Request Profiles") {
                    store.perform { try store.requestProfiles(Array(requestedIDs), deviceName: deviceName) }
                }
                .disabled(requestedIDs.isEmpty || store.cloudIsReadOnly)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("request-profiles")
            }
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

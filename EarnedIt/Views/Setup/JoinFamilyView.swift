import SwiftUI

struct JoinFamilyView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var invitationLink = ""
    @State private var busy = false
    @State private var scanning = false
    @State private var errorMessage: String?
    @State private var connectedFamilies: [CloudFamily] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Your parent chose your role and profile before sending the invitation.",
                          systemImage: "person.crop.circle.badge.checkmark")
                    Label("Your invitation securely connects this device to the existing family.",
                          systemImage: "lock.icloud")
                } header: {
                    Text("One family, the right profile")
                }

                Section {
                    TextField("XXXX-XXXX-XX", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textContentType(.oneTimeCode)
                        .font(.body.monospaced())
                        .accessibilityLabel("Ten character invitation code")
                        .accessibilityIdentifier("invitation-code")
                    Button("Scan QR Code", systemImage: "qrcode.viewfinder") { scanning = true }
                        .disabled(busy)
                        .accessibilityIdentifier("scan-invitation")
                } header: {
                    Text("Invitation code")
                } footer: {
                    Text("Scan the QR code in Earned It or open the shared invitation to connect automatically. Codes expire after 24 hours and work once.")
                }

                Section("Invitation link") {
                    TextField("Shared invitation or iCloud link", text: $invitationLink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("invitation-link")
                    Text("Paste the complete shared invitation to connect automatically. For an older invitation, paste its iCloud link and enter the code above.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Join Family") { redeem() }
                        .disabled(busy || !canJoin)
                        .accessibilityIdentifier("accept-invitation")
                    if busy { ProgressView("Checking invitation…") }
                }

                Section {
                    Button("Find My Family", systemImage: "icloud.and.arrow.down") {
                        run { connectedFamilies = try await store.discoverOwnerRecoveries() }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("find-connected-families")
                    ForEach(connectedFamilies) { family in
                        Button(family.name) {
                            run { try await store.recoverOwnerFamily(family.location); dismiss() }
                        }
                        .accessibilityLabel("Reconnect to \(family.name)")
                    }
                } header: {
                    Text("Replacement device")
                } footer: {
                    Text("Use this if you created the family on another device. If Earned It cannot identify one family safely, ask another parent for a new invitation.")
                }
            }
            .navigationTitle("Join Existing Family")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                InvitationScannerSheet { payload in
                    if let credential = InvitationCredential(text: payload) {
                        code = credential.code
                        invitationLink = credential.shareURL?.absoluteString ?? ""
                        run { try await store.redeemInvitation(payload); if store.selectedMember != nil { dismiss() } }
                    } else if let shareURL = InvitationCredential.rawAppleShareURL(from: payload) {
                        code = ""
                        invitationLink = shareURL.absoluteString
                        run { try await store.openRawAppleInvitation(payload) }
                    }
                }
            }
            .alert("Unable to Join", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
            .accessibilityIdentifier("join-family-screen")
        }
    }

    private func redeem() {
        run {
            if invitationLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await store.redeemInvitation(code)
            } else {
                if let credential = InvitationCredential(text: invitationLink), credential.shareURL != nil {
                    try await store.redeemInvitation(invitationLink)
                    if store.selectedMember != nil { dismiss() }
                    return
                }
                if InvitationCode.normalized(code) == nil,
                   InvitationCredential.rawAppleShareURL(from: invitationLink) != nil {
                    try await store.openRawAppleInvitation(invitationLink)
                    return
                }
                guard let url = URL(string: invitationLink.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw HouseholdError.invitationNotFound
                }
                try await store.join(url: url, invitationCode: code)
            }
            if store.selectedMember != nil { dismiss() }
        }
    }

    private var canJoin: Bool {
        InvitationCode.normalized(code) != nil
            || InvitationCredential(text: invitationLink)?.shareURL != nil
            || InvitationCredential.rawAppleShareURL(from: invitationLink) != nil
    }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { errorMessage = error.localizedDescription }
        }
    }
}

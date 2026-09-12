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
                    Label("Apple’s private iCloud share connects this device to the existing family.",
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
                    Text("Codes expire after 24 hours and work once. If you received an Apple invitation separately, open it before entering the code.")
                }

                Section("Apple invitation link") {
                    TextField("Optional iCloud invitation link", text: $invitationLink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("invitation-link")
                    Text("Paste the link when the code and Apple invitation arrived together. Leave this blank if you already opened the Apple invitation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Join Family") { redeem() }
                        .disabled(busy || InvitationCode.normalized(code) == nil)
                        .accessibilityIdentifier("accept-invitation")
                    if busy { ProgressView("Checking invitation…") }
                }

                Section {
                    Button("Find Connected Families", systemImage: "icloud.and.arrow.down") {
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
                    Text("Owner recovery")
                } footer: {
                    Text("Use this on a replacement device for a family owned by this iCloud account. Ambiguous older families require a new parent invitation.")
                }
            }
            .navigationTitle("Join Existing Family")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                InvitationScannerSheet { payload in
                    guard let credential = InvitationCredential(text: payload) else { return }
                    code = credential.code
                    invitationLink = credential.shareURL?.absoluteString ?? ""
                    run { try await store.redeemInvitation(payload); dismiss() }
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
                guard let url = URL(string: invitationLink.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw HouseholdError.invitationNotFound
                }
                try await store.join(url: url, invitationCode: code)
            }
            dismiss()
        }
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

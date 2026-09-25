import SwiftUI
import UIKit

struct FamilyInvitationView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var role: UserRole = .child
    @State private var childID: UUID?
    @State private var parentName = ""
    @State private var parentAvatar: AvatarOption = .sun
    @State private var issued: IssuedFamilyInvitation?
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let issued { invitationReady(issued) }
                else { invitationForm }
            }
            .navigationTitle(issued == nil ? "Invite Family" : "Invitation Ready")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(issued == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .alert("Unable to Create Invitation", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                if store.latestInvitationDiagnostics != nil {
                    Button("Copy Diagnostics") { copyDiagnostics() }
                        .accessibilityIdentifier("copy-invitation-diagnostics")
                } else {
                    Button("Diagnostics Unavailable") {}
                        .disabled(true)
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
        }
    }

    private var invitationForm: some View {
        Form {
            Section("Who is joining?") {
                Picker("Invitation type", selection: $role) {
                    Text("Child").tag(UserRole.child)
                    Text("Parent").tag(UserRole.parent)
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("invitation-role")
            }

            if role == .child {
                Section("Child profile") {
                    Picker("Profile", selection: $childID) {
                        Text("Choose a child").tag(nil as UUID?)
                        ForEach(store.snapshot.members.filter {
                            $0.role == .child && store.snapshot.isActive($0, on: store.day)
                        }) { child in
                            Text("\(child.avatar.rawValue) \(child.displayName)").tag(child.id as UUID?)
                        }
                    }
                    .accessibilityIdentifier("invitation-child")
                    Text("This invitation opens only the selected child profile. It cannot switch to a sibling or parent.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section("New parent profile") {
                    TextField("Parent name", text: $parentName)
                        .textContentType(.name)
                        .accessibilityIdentifier("invitation-parent-name")
                    Picker("Avatar", selection: $parentAvatar) {
                        ForEach(AvatarOption.allCases) { option in Text(option.rawValue).tag(option) }
                    }
                    .pickerStyle(.inline)
                    Text("The new profile is created by an approved parent. The joining person cannot change it into another role.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Create One-Time Invitation") { createInvitation() }
                    .disabled(busy || !canCreate)
                    .accessibilityIdentifier("create-invitation")
                if busy { ProgressView("Securing invitation…") }
            } footer: {
                Text("Send one invitation or let them scan its QR code. Invitations expire after 24 hours.")
            }
        }
    }

    private func invitationReady(_ issued: IssuedFamilyInvitation) -> some View {
        FamilyInvitationDeliveryView(
            invitation: issued.invitation,
            deliveryURL: issued.invitationURL,
            code: issued.code,
            shareMessage: issued.shareMessage
        )
    }

    private var canCreate: Bool {
        role == .child ? childID != nil : !parentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func createInvitation() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                if role == .child, let childID {
                    issued = try await store.createChildInvitation(memberID: childID)
                } else if role == .parent {
                    issued = try await store.createParentInvitation(name: parentName, avatar: parentAvatar)
                }
            } catch {
                store.recordInvitationErrorBeforePresentation(error)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func copyDiagnostics() {
        guard let diagnostics = store.latestInvitationDiagnostics else { return }
        UIPasteboard.general.string = diagnostics
    }
}

private struct FamilyInvitationDeliveryView: View {
    @Environment(HouseholdStore.self) private var store
    let invitation: FamilyInvitation
    let deliveryURL: URL
    let code: String?
    let shareMessage: String

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(profileDescription)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Valid for 24 hours and one installation")
                    .foregroundStyle(.secondary)

                InvitationQRCode(payload: deliveryURL.absoluteString)
                    .frame(maxWidth: 240, maxHeight: 240)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))

                if let code {
                    VStack(spacing: 6) {
                        Text("Invitation code").font(.caption).foregroundStyle(.secondary)
                        Text(code)
                            .font(.title2.monospaced().bold())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("issued-invitation-code")
                    }
                }

                ShareLink(item: deliveryURL, subject: Text("Earned It family invitation"),
                          message: Text(shareMessage)) {
                    Label("Share Invitation", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("share-invitation")

                Text(instructions)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var profileDescription: String {
        guard let member = store.snapshot.member(invitation.memberID) else { return invitation.role.title }
        return "For \(member.displayName), \(member.role.title)"
    }

    private var instructions: String {
        if code != nil {
            return "Scan this QR code in Earned It or open the shared invitation. Follow any Apple confirmation, then Earned It finishes connecting to the profile shown above."
        }
        return "Scan this QR code or open the Apple invitation link on the joining device. Apple confirms access, then Earned It connects to the profile shown above."
    }
}

struct RecoveredFamilyInvitationView: View {
    @Environment(\.dismiss) private var dismiss
    let recovered: RecoveredFamilyInvitation

    var body: some View {
        NavigationStack {
            FamilyInvitationDeliveryView(
                invitation: recovered.invitation,
                deliveryURL: recovered.shareURL,
                code: nil,
                shareMessage: recovered.shareMessage
            )
            .navigationTitle("Invitation Ready")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

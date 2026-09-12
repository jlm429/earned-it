import SwiftUI

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
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Please try again.") }
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
                Text("Earned It uses a private Apple share plus a one-time app code. The code expires after 24 hours.")
            }
        }
    }

    private func invitationReady(_ issued: IssuedFamilyInvitation) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(profileDescription(issued.invitation))
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Valid for 24 hours and one installation")
                    .foregroundStyle(.secondary)

                InvitationQRCode(payload: issued.qrPayload)
                    .frame(maxWidth: 240, maxHeight: 240)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))

                VStack(spacing: 6) {
                    Text("Invitation code").font(.caption).foregroundStyle(.secondary)
                    Text(issued.code)
                        .font(.title2.monospaced().bold())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("issued-invitation-code")
                }

                ShareLink(item: issued.shareText, subject: Text("Earned It family invitation")) {
                    Label("Share Invitation", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("share-invitation")

                Text("Send the QR code or use Share Invitation. Apple grants access to this family, and the code binds this installation to the profile shown above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var canCreate: Bool {
        role == .child ? childID != nil : !parentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func profileDescription(_ invitation: FamilyInvitation) -> String {
        guard let member = store.snapshot.member(invitation.memberID) else { return invitation.role.title }
        return "For \(member.displayName), \(member.role.title)"
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
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

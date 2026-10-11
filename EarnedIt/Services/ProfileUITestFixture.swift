#if DEBUG
import Foundation

/// Exact invitation bindings in the disposable UI-test journal only.
@MainActor
enum ProfileUITestFixture {
    static func prepare(repository: HouseholdRepository) throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-test-store"),
              let flag = arguments.first(where: { $0.hasPrefix("--ui-test-profile-binding=") }),
              let role = UserRole(rawValue: String(flag.dropFirst("--ui-test-profile-binding=".count))) else { return }
        let store = try HouseholdStore(repository: repository, automaticSync: false)
        guard store.household == nil else { return }
        try store.createFamily(name: "Test Family", parentName: "Test Parent")
        let parent = store.selectedMember!
        let child = try store.saveMember(name: "Hanna", role: .child, avatar: .flower)
        _ = try store.saveMember(name: "Alek", role: .child, avatar: .rocket)
        _ = try store.saveChore(weekday: Weekday(rawValue: store.calendar.component(.weekday, from: store.today))!,
                               title: "Water plants", mode: .all, memberIDs: [])
        try store.finishSetup()
        let member = role == .parent ? parent : child
        try bind(member, in: store, repository: repository,
                 unclaimed: arguments.contains("--ui-test-profile-unclaimed"),
                 unselected: arguments.contains("--ui-test-profile-unselected"))
    }

    /// Simulates a different invited person's installation without a production switcher.
    static func bindRequestedMember(repository: HouseholdRepository,
                                    arguments: [String] = ProcessInfo.processInfo.arguments) throws {
        guard arguments.contains("--ui-test-store"),
              let flag = arguments.first(where: { $0.hasPrefix("--ui-test-bound-member=") }) else { return }
        let slug = String(flag.dropFirst("--ui-test-bound-member=".count))
        let store = try HouseholdStore(repository: repository, automaticSync: false)
        guard let member = store.snapshot.members.first(where: { $0.displayName.accessibilitySlug == slug }) else {
            throw HouseholdError.malformedData
        }
        try bind(member, in: store, repository: repository)
    }

    private static func bind(_ member: FamilyMember, in store: HouseholdStore,
                             repository: HouseholdRepository, unclaimed: Bool = false,
                             unselected: Bool = false) throws {
        let parent = store.snapshot.members.first { $0.role == .parent }!
        let householdID = store.household!.id
        let participant = "synthetic-profile-account-\(member.id)"
        var session = store.session
        session.deviceID = UUID()
        session.cloudParticipantID = participant
        session.selectedMemberID = unclaimed || unselected ? nil : member.id
        if !unclaimed,
           try store.snapshot.committedAccountMembership(participantID: participant) != nil {
            try repository.commit(facts: [], session: session)
            return
        }
        let invitationID = UUID()
        let claimID = UUID()
        let digest = InvitationCode.digest("2345-6789-AB")!
        let invitation = FamilyInvitation(
            id: invitationID, householdID: householdID, claimFactID: claimID,
            memberID: member.id, role: member.role, codeDigest: digest, createdAt: store.today,
            expiresAt: .distantFuture, createdByMemberID: parent.id,
            cloudShareParticipantID: "synthetic-share-participant", cloudShareURLDigest: nil
        )
        let claim = InvitationClaim(invitationID: invitationID, deviceID: session.deviceID,
                                    cloudParticipantID: participant, memberID: member.id,
                                    codeDigest: digest, claimedAt: store.today)
        let sequence = (store.snapshot.orderedFacts.map(\.sequence).max() ?? 0) + 1
        var facts = [
            HouseholdFact(id: UUID(), householdID: householdID, sequence: sequence,
                          authorDeviceID: store.session.deviceID, authorMemberID: parent.id,
                          body: .invitation(invitation))
        ]
        if !unclaimed {
            facts.append(HouseholdFact(id: claimID, householdID: householdID, sequence: sequence + 1,
                          authorDeviceID: session.deviceID, authorMemberID: member.id,
                          body: .invitationClaim(claim)))
        }
        try repository.commit(facts: facts, session: session)
    }
}
#endif

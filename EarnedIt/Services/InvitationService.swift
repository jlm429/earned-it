import CryptoKit
import Foundation
import Security

struct CloudInvitationAccess: Equatable {
    let participantID: String
    let url: URL
}

struct IssuedFamilyInvitation: Identifiable, Equatable {
    let invitation: FamilyInvitation
    let code: String
    let shareURL: URL

    var id: UUID { invitation.id }

    var qrPayload: String {
        var components = URLComponents()
        components.scheme = "earnedit-invitation"
        components.host = "join"
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "share", value: shareURL.absoluteString)
        ]
        return components.url?.absoluteString ?? code
    }

    var shareText: String {
        "Join my Earned It family. Open the Apple invitation, then use code \(code).\n\(shareURL.absoluteString)"
    }
}

/// One CloudKit participant has at most one active household claim, which fixes its exact member and role.
struct AccountFamilyMembership {
    let invitation: FamilyInvitation
    let claim: InvitationClaim
    let member: FamilyMember
}

struct InvitationCredential: Equatable {
    let code: String
    let shareURL: URL?

    init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), components.scheme == "earnedit-invitation",
           components.host == "join" {
            let codeValues = (components.queryItems ?? []).filter { $0.name == "code" }.compactMap(\.value)
            let shareValues = (components.queryItems ?? []).filter { $0.name == "share" }.compactMap(\.value)
            guard codeValues.count == 1, shareValues.count == 1,
                  let normalized = InvitationCode.normalized(codeValues[0]),
                  let shareURL = URL(string: shareValues[0]) else { return nil }
            self.code = normalized
            self.shareURL = shareURL
            return
        }
        guard let normalized = InvitationCode.normalized(trimmed) else { return nil }
        code = normalized
        shareURL = nil
    }
}

enum InvitationLifecycleStatus: Equatable {
    case available, expired, revoked, consumed
}

enum InvitationCode {
    static let lifetime: TimeInterval = 24 * 60 * 60
    private static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 10)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HouseholdError.cloudUnavailable
        }
        let raw = String(bytes.map { alphabet[Int($0) % alphabet.count] })
        return format(raw)
    }

    static func normalized(_ value: String) -> String? {
        let raw = value.uppercased().filter { $0.isLetter || $0.isNumber }
        guard raw.count == 10, raw.allSatisfy(alphabet.contains) else { return nil }
        return format(raw)
    }

    static func digest(_ code: String) -> String? {
        guard let normalized = normalized(code) else { return nil }
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func accountClaimID(householdID: UUID, participantID: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(householdID.uuidString)/\(participantID)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func format(_ raw: String) -> String {
        let characters = Array(raw)
        return String(characters[0..<4]) + "-" + String(characters[4..<8]) + "-" + String(characters[8..<10])
    }
}

extension HouseholdSnapshot {
    func invitation(matchingCode code: String) -> FamilyInvitation? {
        guard let digest = InvitationCode.digest(code) else { return nil }
        return invitations.first { $0.codeDigest == digest }
    }

    func invitationStatus(_ invitation: FamilyInvitation, now: Date) -> InvitationLifecycleStatus {
        if isInvitationRevoked(invitation.id) { return .revoked }
        if invitationClaim(invitation.id) != nil { return .consumed }
        if now >= invitation.expiresAt { return .expired }
        return .available
    }

    func accountMembership(participantID: String, now: Date) throws -> AccountFamilyMembership? {
        guard let household else { return nil }
        let day = CivilDay(now, calendar: household.calendar)
        let memberships = invitationClaims.compactMap { claim -> AccountFamilyMembership? in
            guard claim.cloudParticipantID == participantID,
                  let invitation = invitation(claim.invitationID),
                  !isInvitationRevoked(invitation.id),
                  invitation.memberID == claim.memberID,
                  invitation.codeDigest == claim.codeDigest,
                  let member = member(claim.memberID),
                  member.role == invitation.role,
                  isActive(member, on: day) else { return nil }
            return AccountFamilyMembership(invitation: invitation, claim: claim, member: member)
        }
        guard memberships.count <= 1 else { throw HouseholdError.malformedData }
        return memberships.first
    }
}

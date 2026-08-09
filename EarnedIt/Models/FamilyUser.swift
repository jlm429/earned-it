import Foundation
import SwiftData

@Model
final class FamilyUser {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var roleRawValue: String
    var avatarRawValue: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        role: UserRole,
        avatar: AvatarOption,
        createdAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        roleRawValue = role.rawValue
        avatarRawValue = avatar.rawValue
        self.createdAt = createdAt
    }

    var role: UserRole {
        get { UserRole(rawValue: roleRawValue) ?? .child }
        set { roleRawValue = newValue.rawValue }
    }

    var avatar: AvatarOption {
        get { AvatarOption(rawValue: avatarRawValue) ?? .star }
        set { avatarRawValue = newValue.rawValue }
    }
}

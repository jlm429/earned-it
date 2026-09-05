import Foundation
import SwiftData

@MainActor
enum FamilyUserService {
    @discardableResult
    static func save(
        id: UUID,
        name: String,
        role: UserRole,
        avatar: AvatarOption,
        context: ModelContext
    ) throws -> FamilyUser {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 50 else { throw NameError.invalid }
        let users = try context.fetch(FetchDescriptor<FamilyUser>())
        guard !users.contains(where: {
            $0.id != id && $0.role == role
                && $0.displayName.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) else { throw NameError.duplicate }
        do {
            let user: FamilyUser
            if let existing = users.first(where: { $0.id == id }) {
                user = existing
                user.displayName = trimmed
            } else {
                user = FamilyUser(id: id, displayName: trimmed, role: role, avatar: avatar)
                context.insert(user)
            }
            try context.save()
            return user
        } catch {
            context.rollback()
            throw error
        }
    }

    private enum NameError: LocalizedError {
        case invalid, duplicate
        var errorDescription: String? {
            switch self {
            case .invalid: "Use a display name with 1 to 50 characters."
            case .duplicate: "A person with this name and role already exists. Use a different display name to tell them apart."
            }
        }
    }
}

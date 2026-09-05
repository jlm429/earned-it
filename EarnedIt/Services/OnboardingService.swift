import Foundation
import SwiftData

enum SetupStage: String, CaseIterable {
    case welcome, parent, children, chores, guide

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .parent: "Add a Parent"
        case .children: "Add Children"
        case .chores: "Chores & Allowance"
        case .guide: "Ready for the Week"
        }
    }
}

enum SetupDisposition: String {
    case inProgress, completed, skipped
}

@MainActor
enum OnboardingService {
    static let stageKey = "onboardingStage"
    static let dispositionKey = "onboardingDisposition"

    static func stage(in settings: [AppSetting]) -> SetupStage {
        SetupStage(rawValue: SettingsStore.value(for: stageKey, in: settings) ?? "") ?? .welcome
    }

    static func disposition(in settings: [AppSetting]) -> SetupDisposition {
        if let value = SettingsStore.value(for: dispositionKey, in: settings),
           let disposition = SetupDisposition(rawValue: value) {
            return disposition
        }
        return SettingsStore.bool(for: SettingsStore.setupCompleteKey, in: settings) ? .completed : .inProgress
    }

    static func move(to stage: SetupStage, context: ModelContext) throws {
        try SettingsStore.set(stage.rawValue, for: stageKey, context: context)
    }

    static func finish(skipping: Bool = false, context: ModelContext) throws {
        let users = try context.fetch(FetchDescriptor<FamilyUser>())
        let parent = users.filter { $0.role == .parent }.sorted { $0.createdAt < $1.createdAt }.first
        guard skipping || (parent != nil && users.contains { $0.role == .child }) else {
            throw SetupError.missingFamily
        }
        try SettingsStore.setValues([
            dispositionKey: skipping ? SetupDisposition.skipped.rawValue : SetupDisposition.completed.rawValue,
            SettingsStore.setupCompleteKey: "true",
            SettingsStore.selectedUserIDKey: parent?.id.uuidString ?? ""
        ], context: context)
    }

    static func restart(resuming: Bool = false, context: ModelContext) throws {
        var values = [dispositionKey: SetupDisposition.inProgress.rawValue,
                      SettingsStore.setupCompleteKey: "false"]
        if !resuming { values[stageKey] = SetupStage.welcome.rawValue }
        try SettingsStore.setValues(values, context: context)
    }

    static func clearAll(context: ModelContext) throws {
        do {
            try context.fetch(FetchDescriptor<DailyRecord>()).forEach(context.delete)
            try context.fetch(FetchDescriptor<ExcusedDay>()).forEach(context.delete)
            try context.fetch(FetchDescriptor<Responsibility>()).forEach(context.delete)
            try context.fetch(FetchDescriptor<FamilyUser>()).forEach(context.delete)
            try context.fetch(FetchDescriptor<AppSetting>()).forEach(context.delete)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private enum SetupError: LocalizedError {
        case missingFamily
        var errorDescription: String? { "Add a parent and at least one child, or skip setup for now." }
    }
}

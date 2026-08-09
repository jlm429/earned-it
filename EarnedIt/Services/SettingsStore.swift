import Foundation
import SwiftData

enum SettingsStore {
    static let setupCompleteKey = "setupComplete"
    static let selectedUserIDKey = "selectedUserID"
    static let dataModeKey = "dataMode"

    static func value(for key: String, in settings: [AppSetting]) -> String? {
        settings.first { $0.key == key }?.value
    }

    static func bool(for key: String, in settings: [AppSetting]) -> Bool {
        value(for: key, in: settings) == "true"
    }

    static func set(_ value: String, for key: String, context: ModelContext) throws {
        let all = try context.fetch(FetchDescriptor<AppSetting>())
        if let setting = all.first(where: { $0.key == key }) {
            setting.value = value
        } else {
            context.insert(AppSetting(key: key, value: value))
        }
        try context.save()
    }

    static func remove(_ key: String, context: ModelContext) throws {
        let all = try context.fetch(FetchDescriptor<AppSetting>())
        all.filter { $0.key == key }.forEach(context.delete)
        try context.save()
    }
}

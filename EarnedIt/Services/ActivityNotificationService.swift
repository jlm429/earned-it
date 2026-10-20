import Foundation
import Observation
import UserNotifications

enum ActivityAlertPermission: Equatable {
    case notDetermined, allowed, denied
}

@MainActor
protocol ActivityAlerting {
    func setEnabled(_ enabled: Bool)
    func permission() async -> ActivityAlertPermission
    func badgePermission() async -> ActivityAlertPermission
    func requestPermission() async throws -> ActivityAlertPermission
    func deliver(identifier: String) async throws
    func setBadgeCount(_ count: Int) async throws
    func clear() async
}

extension ActivityAlerting {
    func setEnabled(_ enabled: Bool) {}
    func setBadgeCount(_ count: Int) async throws {}
}

@MainActor
struct DisabledActivityAlerts: ActivityAlerting {
    func permission() async -> ActivityAlertPermission { .denied }
    func badgePermission() async -> ActivityAlertPermission { .denied }
    func requestPermission() async throws -> ActivityAlertPermission { .denied }
    func deliver(identifier: String) async throws {}
    func clear() async {}
}

#if DEBUG
/// Authorization simulation is restricted to the disposable UI-test launch.
@MainActor
final class UITestActivityAlerts: ActivityAlerting {
    private var current: ActivityAlertPermission

    init(allowed: Bool) { current = allowed ? .allowed : .notDetermined }
    func permission() async -> ActivityAlertPermission { current }
    func badgePermission() async -> ActivityAlertPermission { current }
    func requestPermission() async throws -> ActivityAlertPermission {
        current = .allowed
        return current
    }
    func deliver(identifier: String) async throws {}
    func clear() async {}
}
#endif

@MainActor
@Observable
final class ActivityNavigation {
    static let shared = ActivityNavigation()
    var isPresented = false
}

final class AppleActivityAlerts: NSObject, ActivityAlerting, UNUserNotificationCenterDelegate {
    static let shared = AppleActivityAlerts()
    private let center = UNUserNotificationCenter.current()
    @MainActor private var isEnabled = false
    @MainActor private var badgeCount = 0

    @MainActor
    func setEnabled(_ enabled: Bool) { isEnabled = enabled }

    override init() {
        super.init()
        center.delegate = self
    }

    @MainActor
    func permission() async -> ActivityAlertPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    @MainActor
    func requestPermission() async throws -> ActivityAlertPermission {
        _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        return await permission()
    }

    @MainActor
    func badgePermission() async -> ActivityAlertPermission {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined { return .notDetermined }
        return settings.badgeSetting == .enabled ? .allowed : .denied
    }

    @MainActor
    func deliver(identifier: String) async throws {
        let badgesAllowed = await badgePermission() == .allowed
        guard await permission() == .allowed, isEnabled else { return }
        try await center.add(Self.request(identifier: identifier, badgeCount: badgesAllowed ? badgeCount : nil))
    }

    @MainActor
    func setBadgeCount(_ count: Int) async throws {
        badgeCount = isEnabled ? max(0, count) : 0
        guard await badgePermission() == .allowed else { return }
        try await center.setBadgeCount(badgeCount)
    }

    static func request(identifier: String, badgeCount: Int? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Earned It"
        content.body = "New family activity. Open Earned It to review your chores and requests."
        content.sound = .default
        content.threadIdentifier = "family-activity"
        content.badge = badgeCount.map { NSNumber(value: max(0, $0)) }
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    @MainActor
    func clear() async {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        badgeCount = 0
        if await badgePermission() == .allowed { try? await center.setBadgeCount(0) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            var options: UNNotificationPresentationOptions = [.banner, .list, .sound]
            if await badgePermission() == .allowed { options.insert(.badge) }
            completionHandler(isEnabled ? options : [])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            ActivityNavigation.shared.isPresented = true
            completionHandler()
        }
    }
}

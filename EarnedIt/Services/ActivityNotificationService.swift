import Foundation
import Observation
import UserNotifications

enum ActivityAlertPermission: Equatable {
    case notDetermined, allowed, denied
}

@MainActor
protocol ActivityAlerting {
    func permission() async -> ActivityAlertPermission
    func requestPermission() async throws -> ActivityAlertPermission
    func deliver(identifier: String) async throws
    func clear() async
}

@MainActor
struct DisabledActivityAlerts: ActivityAlerting {
    func permission() async -> ActivityAlertPermission { .denied }
    func requestPermission() async throws -> ActivityAlertPermission { .denied }
    func deliver(identifier: String) async throws {}
    func clear() async {}
}

@MainActor
@Observable
final class ActivityNavigation {
    static let shared = ActivityNavigation()
    var isPresented = false
}

final class AppleActivityAlerts: NSObject, ActivityAlerting, UNUserNotificationCenterDelegate {
    static let shared = AppleActivityAlerts()
    private let center = UNUserNotificationCenter.current()

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
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return await permission()
    }

    @MainActor
    func deliver(identifier: String) async throws {
        guard await permission() == .allowed else { return }
        try await center.add(Self.request(identifier: identifier))
    }

    static func request(identifier: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Earned It"
        content.body = "New family activity. Open Earned It to review your chores and requests."
        content.sound = .default
        content.threadIdentifier = "family-activity"
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    @MainActor
    func clear() async {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            ActivityNavigation.shared.isPresented = true
            completionHandler()
        }
    }
}

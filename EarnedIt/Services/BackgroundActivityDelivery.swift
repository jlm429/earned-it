import CloudKit
import UIKit

@MainActor
final class BackgroundActivityDelivery {
    static let shared = BackgroundActivityDelivery()
    weak var store: HouseholdStore?

    static var isEnabled: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains("--ui-test-store"),
              !arguments.contains("--owner-transition-preflight"),
              !arguments.contains("--child-recovery-preflight") else { return false }
        #endif
        return (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?
            .contains("remote-notification") == true
    }

    func receive(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard Self.isEnabled,
              let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              notification.notificationType == .database,
              let store, store.session.location != nil,
              store.selectedMember != nil, !store.hasPendingAccountDataReset,
              !store.familyAccessLost else { return .noData }
        let before = store.snapshot.orderedFacts.count
        do {
            try await store.synchronize()
            try Task.checkCancellation()
            await store.processActivityAlerts()
            return store.snapshot.orderedFacts.count == before ? .noData : .newData
        } catch { return .failed }
    }
}

@MainActor
final class BackgroundActivityCompletion {
    private var completion: ((UIBackgroundFetchResult) -> Void)?
    init(_ completion: @escaping (UIBackgroundFetchResult) -> Void) { self.completion = completion }
    func finish(_ result: UIBackgroundFetchResult) {
        guard let callback = completion else { return }
        completion = nil
        callback(result)
    }
}

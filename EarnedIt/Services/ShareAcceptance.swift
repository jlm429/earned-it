import CloudKit
import Observation
import UIKit

@MainActor
@Observable
final class ShareAcceptance {
    static let shared = ShareAcceptance()
    var pending: CKShare.Metadata?
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if BackgroundActivityDelivery.isEnabled { application.registerForRemoteNotifications() }
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let completion = BackgroundActivityCompletion(completionHandler)
        let operation = Task { @MainActor in
            completion.finish(await BackgroundActivityDelivery.shared.receive(userInfo))
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(25))
            operation.cancel()
            completion.finish(.failed)
        }
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let metadata = options.cloudKitShareMetadata { ShareAcceptance.shared.pending = metadata }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = CloudShareSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        ShareAcceptance.shared.pending = cloudKitShareMetadata
    }
}

final class CloudShareSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata { ShareAcceptance.shared.pending = metadata }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        ShareAcceptance.shared.pending = cloudKitShareMetadata
    }
}

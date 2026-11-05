import UIKit
import UserNotifications

// Apple requires the notification-center delegate before launch returns; a
// SwiftUI .task runs too late for the banner tap that cold-started the app.
// The remote-registration callbacks land here too: UIKit only ever delivers
// them to the application delegate. Mirrors the Mac's AppDelegate, because
// the shared NotificationManager expects exactly these answers.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    // UIKit's own signature: the name and the optional dictionary are the
    // framework's, and a delegate method that does not match it is simply
    // never called.
    // swiftlint:disable boolean_function_naming discouraged_optional_collection
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationManager.shared
        // A team build rings by VoIP push. The registry is made at every launch,
        // before anything else: the push can be the reason this process exists,
        // and the ring it carries reaches only a registry that is already there.
        if PushState.isBuilt { CallKitCoordinator.shared.startPushKit() }
        return true
    }
    // swiftlint:enable boolean_function_naming discouraged_optional_collection

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationManager.shared.deviceTokenReceived(
            deviceToken.map { String(format: "%02x", $0) }.joined()
        )
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // No push this launch; the socket still delivers while the app runs.
        // The reason goes to the server too: a log line on the silent phone is
        // the one place nobody looking for the problem can read it.
        NSLog("APNs registration failed: %@", error.localizedDescription)
        NotificationManager.shared.registrationFailed(error.localizedDescription)
    }

    /// A push that arrives while the app is backgrounded gets a few seconds
    /// of runtime: enough to pull the message down so the thread is already
    /// current when the banner is tapped.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        // In the background the system is showing this push itself; claim it
        // before the sync below can hand the same message to the local-banner
        // path. In the foreground `willPresent` decides instead.
        await NotificationManager.shared.noteRemoteDelivery(
            userInfo: userInfo, isActive: application.applicationState == .active
        )
        // A read-sync push has had its cursor moved and delivered banners
        // cleared by the line above; the store then reads only the conversation
        // list, where the unread counts and the home-screen badge come from.
        guard let store = CallKitCoordinator.shared.store else { return .noData }
        await store.handleRemotePush(isReadSync: userInfo["read_through_message_id"] != nil)
        return .newData
    }
}

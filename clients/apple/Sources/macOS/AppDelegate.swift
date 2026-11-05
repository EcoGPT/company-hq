import AppKit
import UserNotifications

// Apple requires the notification-center delegate before launch returns; a
// SwiftUI .task runs too late for the banner click that cold-started the app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MenuBarLifecycle.noteLaunch()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read again: the launch Apple event is not always there yet in
        // applicationWillFinishLaunching.
        MenuBarLifecycle.noteLaunch()
        MenuBarLifecycle.start()
        #if DEBUG
        // A launch with HQ_UI_SNAPSHOT writes its window and quits, on a fixture or on a live server.
        FixtureSnapshot.scheduleIfAsked()
        if HQSimulatorFixture.isEnabled { return }
        #endif
        UNUserNotificationCenter.current().delegate = NotificationManager.shared
        // Here, not in the window's task: a launch at login has no window yet.
        // LoginItem.apply skips a build run with HQ_NO_SYSTEM_REGISTRATION, so a
        // worktree build never registers itself as a login item.
        LoginItem.apply()
    }

    // The Dock icon is hidden while no window is open; HQ stays up for the
    // menu bar item and the socket.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // A click on HQ in Finder or Spotlight while only the menu bar item is
    // showing: the Dock icon returns and the system opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MenuBarLifecycle.showDock()
        return true
    }

    // Remote notifications: AppKit delivers these to the application delegate
    // only. A build with no team gets the failure below, never a token.
    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationManager.shared.deviceTokenReceived(
            deviceToken.map { String(format: "%02x", $0) }.joined()
        )
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // No push this launch; the socket still delivers while the app runs.
        // The reason goes to the server too: a log line on the silent Mac is
        // the one place nobody looking for the problem can read it.
        NSLog("APNs registration failed: %@", error.localizedDescription)
        NotificationManager.shared.registrationFailed(error.localizedDescription)
    }

    // A read-sync push (another device read a thread): clear the banners it covers.
    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        guard let conversationId = userInfo["conversation_id"] as? String,
              let messageId = userInfo["read_through_message_id"] as? String
        else { return }
        NotificationManager.shared.clearMessageNotifications(
            readThrough: [conversationId: messageId]
        )
    }
}

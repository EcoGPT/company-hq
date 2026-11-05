import AppKit
import ApplicationServices

/// HQ lives in the menu bar. While a window is open it is a normal app with a
/// Dock icon; when the last window closes the Dock icon goes and HQ keeps
/// running as a menu-bar-only app (the socket stays up, messages still
/// arrive); opening a window again brings the icon back. A launch at login
/// goes straight to the menu bar with no window.
///
/// Every window the person can see is one of two scenes, told apart from the
/// menu bar extra's own panel by identifier.
@MainActor
enum MenuBarLifecycle {
    /// The app was started by the login item (or `--hq-background`), not by
    /// the person opening it.
    private(set) static var isBackgroundLaunch = false
    /// The launch-time hide pass has put a window away (or given up looking).
    /// Until then a window becoming key is SwiftUI's own, not the person's.
    private(set) static var hasHiddenLaunchWindows = false
    /// True only while the hide pass is ordering windows out.
    private static var isHidingLaunchWindows = false
    private static var observers: [NSObjectProtocol] = []

    /// Call from `applicationWillFinishLaunching` and again at the start of
    /// `applicationDidFinishLaunching`: the launch Apple event may not be
    /// readable yet the first time, and a repeat never undoes a yes.
    static func noteLaunch() {
        isBackgroundLaunch = resolveBackgroundLaunch(
            already: isBackgroundLaunch,
            arguments: CommandLine.arguments, event: NSAppleEventManager.shared().currentAppleEvent
        )
        if isBackgroundLaunch { NSApp.setActivationPolicy(.accessory) }
    }

    static func resolveBackgroundLaunch(
        already: Bool, arguments: [String], event: NSAppleEventDescriptor?
    ) -> Bool {
        already || launchedAtLogin(arguments: arguments, event: event)
    }

    /// During a login launch SwiftUI's window becomes key before it is put
    /// away; that must not bring the Dock icon back.
    static func shouldShowDockWhenAWindowBecomesKey(
        isBackgroundLaunch: Bool, hasHiddenLaunchWindows: Bool, isHidingLaunchWindows: Bool = false
    ) -> Bool {
        // The hide pass itself can hand key status to another window; that
        // is never the person.
        if isHidingLaunchWindows { return false }
        return !isBackgroundLaunch || hasHiddenLaunchWindows
    }

    static func launchedAtLogin(arguments: [String], event: NSAppleEventDescriptor?) -> Bool {
        if arguments.contains("--hq-background") { return true }
        guard let event, event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    static func start() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow, isPrimary(window) else { return }
                Task { @MainActor in dropDockIfNoWindowIsOpen(closing: window) }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow, isPrimary(window) else { return }
                // Decided now, on the main queue where the notification
                // arrives: a Task would read the flags after the launch hide
                // pass (queued earlier) had already set hasHiddenLaunchWindows,
                // and a key window that pass is about to put away would then
                // bring the Dock icon back at login.
                MainActor.assumeIsolated {
                    guard shouldShowDockWhenAWindowBecomesKey(
                        isBackgroundLaunch: isBackgroundLaunch,
                        hasHiddenLaunchWindows: hasHiddenLaunchWindows,
                        isHidingLaunchWindows: isHidingLaunchWindows
                    ) else { return }
                    showDock()
                }
            },
        ]
        if isBackgroundLaunch { Task { await keepWindowsClosedAtLaunch() } }
    }

    /// The Dock icon comes back (and the menu bar with it).
    static func showDock() {
        isBackgroundLaunch = false
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    static func isPrimary(_ window: NSWindow) -> Bool {
        guard let id = window.identifier?.rawValue else { return false }
        return id.hasPrefix("hq-main") || id.hasPrefix("hq-meeting")
    }

    static func dropDockIfNoWindowIsOpen(closing: NSWindow?) {
        let isAnyOpen = NSApp.windows.contains {
            $0 !== closing && isPrimary($0) && ($0.isVisible || $0.isMiniaturized)
        }
        if !isAnyOpen, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// SwiftUI opens the main window on every launch; at login it is put away
    /// as soon as it exists, before anyone has seen it. The window stays
    /// alive, so its tasks (the socket, the store) run as usual.
    private static func keepWindowsClosedAtLaunch() async {
        for _ in 0..<30 {
            guard isBackgroundLaunch else { return }
            isHidingLaunchWindows = true
            for window in NSApp.windows where isPrimary(window) && window.isVisible {
                window.orderOut(nil)
                hasHiddenLaunchWindows = true
            }
            isHidingLaunchWindows = false
            try? await Task.sleep(for: .milliseconds(100))
        }
        hasHiddenLaunchWindows = true
    }
}

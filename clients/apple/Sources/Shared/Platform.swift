#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import SwiftUI
import UserNotifications

// The handful of places the shared layer has to ask the host app something
// only AppKit or UIKit can answer: what this device is called, where a copied
// string goes, when the app came forward or is on its way out, and how the
// icon carries an unread count. Everything else in `Sources/Shared` is
// already platform-free — keeping these seven answers in one file is what
// lets AppStore and NotificationManager read as one program instead of two.
/// The one image class, under one name. Both platforms have a bitmap type
/// that LinkPresentation and the attachment views hand back; only the prefix
/// differs.
#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platform image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

@MainActor
enum Platform {
    /// What kind of machine this is, in the words a person would use.
    static var deviceKind: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    /// What this device enrolls as. The name is the person's own ("Ada's
    /// iPhone"), which is what an admin reads on the device list.
    static var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? deviceKind
        #else
        return UIDevice.current.name
        #endif
    }

    /// True only while the app is the one the user is looking at.
    static var isActive: Bool {
        #if os(macOS)
        return NSApplication.shared.isActive
        #else
        return UIApplication.shared.applicationState == .active
        #endif
    }

    static var didBecomeActiveNotification: Notification.Name {
        #if os(macOS)
        return NSApplication.didBecomeActiveNotification
        #else
        return UIApplication.didBecomeActiveNotification
        #endif
    }

    /// The last chance to flush the state cache. iOS is never promised a
    /// termination callback, so the phone also saves on backgrounding —
    /// which is the moment a suspended app can actually be killed.
    static var willTerminateNotification: Notification.Name {
        #if os(macOS)
        return NSApplication.willTerminateNotification
        #else
        return UIApplication.willTerminateNotification
        #endif
    }

    #if !os(macOS)
    static var didEnterBackgroundNotification: Notification.Name {
        UIApplication.didEnterBackgroundNotification
    }
    #endif

    static func copyToClipboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    /// Asks Apple for a push token. The answer arrives on the app delegate:
    /// a token, or a failure (always, in a build with no push entitlement).
    static func registerForRemoteNotifications() {
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #else
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// The unread count on the app icon: the Dock tile on macOS, the home
    /// screen badge on iOS. Zero clears it — a badge with nothing in it is a
    /// red dot that means nothing.
    static func setBadge(_ count: Int) {
        #if os(macOS)
        NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
        #else
        UNUserNotificationCenter.current().setBadgeCount(count)
        #endif
    }
}

import AppKit
import SwiftUI

/// Fronts the meeting stage the way `MainWindow` fronts the app: joining a
/// call must land the caller ON the call, even when HQ is hidden, another
/// app is frontmost, or the stage window is buried behind someone's browser.
@MainActor
enum MeetingWindow {
    static func spotlight(using openWindow: OpenWindowAction) {
        NSApp.unhide(nil)
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix("hq-meeting") == true
        }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            // Front the window even while activation is still pending.
            window.orderFrontRegardless()
        } else {
            // A freshly opened window fronts itself once activation lands.
            openWindow(id: "hq-meeting")
        }
        // Cooperative activation can defer a background request; insist for a
        // beat so joining always lands the stage in the active view.
        Task {
            for _ in 0..<10 {
                NSApp.activate()
                if NSApp.isActive { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

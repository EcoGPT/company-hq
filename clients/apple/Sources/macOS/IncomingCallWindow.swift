import AppKit
import SwiftUI

// The ring's own window. A floating panel rather than a SwiftUI
// `Window` scene: a call has to appear when the main window is closed, hidden,
// or behind a full-screen app, and it has to go away the instant the ring
// resolves. Both are things AppKit does directly and a scene does at arm's
// length.
@MainActor
enum IncomingCallWindow {
    private static var panel: NSPanel?

    static func show(store: AppStore) {
        if panel != nil { return }
        let controller = NSHostingController(rootView: IncomingCallView().environment(store))
        let size = IncomingCallView.bannerSize
        // Borderless with a clear window background: the banner's own
        // rounded material is the whole chrome, the way a notification
        // draws itself.
        let created = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.contentViewController = controller
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = true
        created.isMovableByWindowBackground = true
        created.isFloatingPanel = true
        created.hidesOnDeactivate = false
        created.level = .floating
        // Ringing on the space the user is actually looking at, including
        // over someone else's full-screen window.
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Where every macOS notification lands: the top-right corner of the
        // screen the user is on.
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        created.setFrameOrigin(
            NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 12)
        )
        panel = created
        created.orderFrontRegardless()
    }

    static func hide() {
        panel?.close()
        panel = nil
    }
}

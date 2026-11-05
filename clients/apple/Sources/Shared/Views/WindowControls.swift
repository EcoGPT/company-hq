import AppKit
import SwiftUI

/// AppKit's standard traffic lights live in the pane, not an invisible titlebar.
struct WindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlsView { ControlsView() }
    func updateNSView(_ view: ControlsView, context: Context) { view.updateControls() }

    final class ControlsView: NSView {
        private var controls: [NSButton] = []
        private var shouldMinimizeAfterFullScreenExit = false
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let actions = [#selector(closeWindow(_:)), #selector(minimizeWindow(_:)), #selector(zoomWindow(_:))]
            for (index, kind) in kinds.enumerated() {
                guard let button = NSWindow.standardWindowButton(kind, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
                button.target = self
                button.action = actions[index]
                button.frame = NSRect(x: 18 + CGFloat(index) * 20, y: 0, width: 14, height: 14)
                addSubview(button)
                controls.append(button)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            // Center within the pane below its 8pt top inset.
            for button in controls {
                button.setFrameOrigin(NSPoint(x: button.frame.minX, y: (bounds.height - button.frame.height) / 2 + 4))
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            shouldMinimizeAfterFullScreenExit = false
            if let window {
                for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(fullScreenChanged(_:)), name: name, object: window
                    )
                }
            }
            updateControls()
        }

        @objc private func fullScreenChanged(_ notification: Notification) {
            updateControls()
            if notification.name == NSWindow.didExitFullScreenNotification,
               shouldMinimizeAfterFullScreenExit {
                shouldMinimizeAfterFullScreenExit = false
                window?.performMiniaturize(nil)
            }
        }

        func updateControls() {
            let isFullScreen = window?.styleMask.contains(.fullScreen) == true
            // The pane owns the controls in both modes; HQ has no visible titlebar.
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window?.standardWindowButton(kind)?.isHidden = true
            }
            for (index, button) in controls.enumerated() {
                button.isHidden = window == nil
                button.isEnabled = window != nil
                if index == 2 {
                    button.setAccessibilityLabel(isFullScreen ? "Exit full screen" : "Enter full screen")
                }
                button.needsDisplay = true
            }
        }

        @objc private func closeWindow(_ sender: Any?) { window?.performClose(sender) }
        @objc private func minimizeWindow(_ sender: Any?) {
            guard let window else { return }
            if window.styleMask.contains(.fullScreen) {
                guard !shouldMinimizeAfterFullScreenExit else { return }
                shouldMinimizeAfterFullScreenExit = true
                window.toggleFullScreen(sender)
            } else {
                window.performMiniaturize(sender)
            }
        }
        @objc private func zoomWindow(_ sender: Any?) {
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                window?.performZoom(sender)
            } else {
                window?.toggleFullScreen(sender)
            }
        }
    }
}

import SwiftUI
#if os(macOS)
import AppKit
#endif

// HQ runs all day and ⌘⇧E only hides it — and a hidden window still drives
// its SwiftUI animations at full frame rate (measured: a chat
// left open with the shimmer running held ~25% CPU through NSApp.hide,
// because every animation frame re-asks the eager transcript for its bubble
// sizes). So the transcript's repeat-forever indicators gate
// themselves on whether their window is actually being drawn.

/// Hands its content whether the hosting window is on screen and at least
/// partially unoccluded — false while the app is hidden, the window
/// miniaturized or closed, or another window fully covers it. On iOS the
/// system suspends a backgrounded app's animations itself, so the answer is
/// simply "visible".
struct WindowVisibilityReader<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content

    #if os(macOS)
    @State private var isVisible = true

    var body: some View {
        content(isVisible)
            .background(WindowOcclusionProbe(isVisible: $isVisible))
    }
    #else
    var body: some View {
        content(true)
    }
    #endif
}

#if os(macOS)
// Occlusion is a window-level fact AppKit only tells the window about, so
// the reader plants an empty NSView to find its window and listen.
private struct WindowOcclusionProbe: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { isVisible = $0 }
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = { isVisible = $0 }
    }

    final class ProbeView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observer: (any NSObjectProtocol)?
        private var lastReported: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            // Moving to a window can happen mid view-update; report on the
            // next turn so the binding write never lands inside one.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        private func report() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            guard visible != lastReported else { return }
            lastReported = visible
            onChange(visible)
        }
    }
}
#endif

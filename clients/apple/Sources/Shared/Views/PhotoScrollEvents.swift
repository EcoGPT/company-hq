import AppKit
import SwiftUI

// SwiftUI DragGesture handles a pressed mouse/trackpad, not a two-finger
// scroll. Listen only inside this viewport and leave all other events alone.
struct PhotoScrollEvents: NSViewRepresentable {
    var isEnabled: Bool
    var onScroll: (CGSize) -> Void
    var onMagnify: ((CGFloat, CGPoint) -> Void)? = nil

    func makeNSView(context: Context) -> PhotoScrollEventView {
        PhotoScrollEventView()
    }

    func updateNSView(_ view: PhotoScrollEventView, context: Context) {
        view.isEnabled = isEnabled
        view.onScroll = onScroll
        view.onMagnify = onMagnify
    }

    static func dismantleNSView(_ view: PhotoScrollEventView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class PhotoScrollEventView: NSView {
    var isEnabled = false
    var onScroll: ((CGSize) -> Void)?
    var onMagnify: ((CGFloat, CGPoint) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            if event.type == .magnify {
                return self.handleMagnify(at: event.locationInWindow, in: event.window,
                                          magnification: event.magnification) ? nil : event
            }
            guard self.handleScroll(
                at: event.locationInWindow, in: event.window,
                delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
                isPrecise: event.hasPreciseScrollingDeltas
            ) else { return event }
            return nil
        }
    }

    // Return true only when this preview consumed the event. Header, other
    // windows and fit-mode scrolling must continue through AppKit normally.
    func handleScroll(at point: NSPoint, in eventWindow: NSWindow?,
                      delta: CGSize, isPrecise: Bool) -> Bool {
        guard isEnabled, let window, eventWindow === window,
              !isHiddenOrHasHiddenAncestor,
              bounds.intersection(visibleRect).contains(convert(point, from: nil)) else { return false }
        let multiplier: CGFloat = isPrecise ? 1 : 10
        onScroll?(CGSize(width: delta.width * multiplier, height: delta.height * multiplier))
        return true
    }

    func handleMagnify(at point: NSPoint, in eventWindow: NSWindow?, magnification: CGFloat) -> Bool {
        guard let window, eventWindow === window, let onMagnify,
              !isHiddenOrHasHiddenAncestor else { return false }
        let local = convert(point, from: nil)
        guard bounds.intersection(visibleRect).contains(local) else { return false }
        // AppKit is usually bottom-up; SwiftUI offsets are top-down.
        let pointer = CGPoint(x: local.x - bounds.midX,
                              y: (local.y - bounds.midY) * (isFlipped ? 1 : -1))
        onMagnify(magnification, pointer)
        return true
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

// The same image point must stay under the cursor across a scale change,
// including after panning or when zooming back down to 1x. Fit recenters.
enum PhotoZoomAnchor {
    static func offset(_ offset: CGSize, from oldScale: CGFloat, to newScale: CGFloat,
                       at pointer: CGPoint) -> CGSize {
        let ratio = newScale / oldScale
        return CGSize(width: pointer.x - (pointer.x - offset.width) * ratio,
                      height: pointer.y - (pointer.y - offset.height) * ratio)
    }
}

import AppKit
import SwiftUI

/// The AppKit half of the standard prepending-feed pattern: snapshot the
/// viewport immediately before rows are inserted, then move the clip view by
/// exactly the height inserted above it. SwiftUI owns the eager transcript;
/// AppKit owns the viewport, so the correction lands in the same layout pass
/// instead of appearing as a later scroll animation.
@MainActor
final class TranscriptViewportPreserver {
    struct Snapshot: Equatable {
        let originY: CGFloat
        let contentHeight: CGFloat

        func preservedOrigin(for newContentHeight: CGFloat) -> CGFloat {
            originY + newContentHeight - contentHeight
        }
    }

    private weak var scrollView: NSScrollView?
    private weak var documentView: NSView?
    private var observations: [NSObjectProtocol] = []
    private var snapshot: Snapshot?
    private var isRestoring = false
    private var isEnding = false
    private var finishTask: Task<Void, Never>?

    func attach(to scrollView: NSScrollView) {
        guard self.scrollView !== scrollView || documentView !== scrollView.documentView else {
            return
        }
        removeObservations()
        self.scrollView = scrollView
        documentView = scrollView.documentView

        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        observations.append(
            center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.geometryChanged() }
            }
        )

        if let documentView {
            documentView.postsFrameChangedNotifications = true
            observations.append(
                center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: documentView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.geometryChanged() }
                }
            )
        }
    }

    /// Called after the page request returns and immediately before the store
    /// publishes its prepended rows.
    func beginPrepend() {
        guard let scrollView, let documentView else { return }
        scrollView.layoutSubtreeIfNeeded()
        finishTask?.cancel()
        snapshot = Snapshot(
            originY: scrollView.contentView.bounds.origin.y,
            contentHeight: documentView.frame.height
        )
        isEnding = false
    }

    /// SwiftUI may make several frame changes while its eager VStack settles.
    /// Keep correcting synchronously through that burst, then release the
    /// viewport after a quiet interval so the next gesture is wholly native.
    func endPrependWhenLayoutSettles() {
        guard snapshot != nil else { return }
        isEnding = true
        scheduleFinish(after: .milliseconds(400))
    }

    func reset() {
        finishTask?.cancel()
        finishTask = nil
        snapshot = nil
        isEnding = false
    }

    private func geometryChanged() {
        guard snapshot != nil, !isRestoring else { return }
        restoreViewport()
        if isEnding {
            scheduleFinish(after: .milliseconds(180))
        }
    }

    private func restoreViewport() {
        guard let snapshot, let scrollView, let documentView else { return }
        let clipView = scrollView.contentView
        let desiredY = snapshot.preservedOrigin(for: documentView.frame.height)
        guard abs(clipView.bounds.origin.y - desiredY) > 0.5 else { return }

        isRestoring = true
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: desiredY))
        scrollView.reflectScrolledClipView(clipView)
        isRestoring = false
    }

    private func scheduleFinish(after delay: Duration) {
        finishTask?.cancel()
        finishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.restoreViewport()
            self.snapshot = nil
            self.isEnding = false
            self.finishTask = nil
        }
    }

    private func removeObservations() {
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
        }
        observations.removeAll()
    }

    deinit {
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
        }
    }
}

/// Resolves the `NSScrollView` SwiftUI creates without replacing the
/// transcript's plain eager VStack (which is required for cross-bubble text
/// selection). The zero-size view lives inside that scroll view's hierarchy.
struct TranscriptScrollViewResolver: NSViewRepresentable {
    let resolve: @MainActor (NSScrollView) -> Void

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.resolve = resolve
        return view
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.resolve = resolve
        nsView.resolveEnclosingScrollView()
    }

    @MainActor
    final class ResolverView: NSView {
        var resolve: (@MainActor (NSScrollView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveEnclosingScrollView()
        }

        func resolveEnclosingScrollView() {
            guard let scrollView = enclosingScrollView else {
                Task { @MainActor [weak self] in
                    guard let self, let scrollView = self.enclosingScrollView else { return }
                    self.resolve?(scrollView)
                }
                return
            }
            resolve?(scrollView)
        }
    }
}

import SwiftUI
import UIKit

/// The UIKit half of the standard prepending-feed pattern. Immediately before
/// older rows enter the model, remember the transcript's content height. Each
/// layout increase above the viewport is then added to the live content offset,
/// leaving the message under the reader's finger in the same screen position.
///
/// Applying each height delta to the *current* offset matters on a phone: the
/// person's drag or deceleration can continue while SwiftUI lays out the page.
/// A fixed scroll-to target would cancel that motion or snap back afterwards.
@MainActor
final class TranscriptViewportPreserver {
    struct Snapshot: Equatable {
        let contentHeight: CGFloat

        func preservedOffset(currentOffset: CGFloat, newContentHeight: CGFloat) -> CGFloat {
            currentOffset + newContentHeight - contentHeight
        }
    }

    private weak var scrollView: UIScrollView?
    private var contentSizeObservation: NSKeyValueObservation?
    private var snapshot: Snapshot?
    private var finishTask: Task<Void, Never>?
    private var isRestoring = false
    private var isEnding = false

    func attach(to scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        contentSizeObservation?.invalidate()
        self.scrollView = scrollView
        contentSizeObservation = scrollView.observe(\.contentSize, options: [.new]) {
            [weak self] _, _ in
            MainActor.assumeIsolated { self?.contentSizeChanged() }
        }
    }

    /// Called after the network request returns and immediately before the
    /// store publishes the prepended page, so waiting on the server never
    /// freezes or otherwise changes the user's scroll gesture.
    func beginPrepend() {
        guard let scrollView else { return }
        scrollView.layoutIfNeeded()
        finishTask?.cancel()
        snapshot = Snapshot(contentHeight: scrollView.contentSize.height)
        isEnding = false
    }

    /// A prepend settles over several UIKit layout passes: inserted rows land,
    /// timestamp separators measure, then the loading spinner leaves. Preserve
    /// every delta and release after the geometry has been quiet briefly.
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

    private func contentSizeChanged() {
        guard !isRestoring, let snapshot, let scrollView else { return }
        let newHeight = scrollView.contentSize.height
        let desiredY = snapshot.preservedOffset(
            currentOffset: scrollView.contentOffset.y,
            newContentHeight: newHeight
        )

        // Advance the baseline even when the sub-pixel delta needs no scroll;
        // later layout passes should preserve only their own added height.
        self.snapshot = Snapshot(contentHeight: newHeight)
        guard abs(scrollView.contentOffset.y - desiredY) > 0.5 else { return }

        isRestoring = true
        scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: desiredY)
        isRestoring = false

        if isEnding {
            scheduleFinish(after: .milliseconds(180))
        }
    }

    private func scheduleFinish(after delay: Duration) {
        finishTask?.cancel()
        finishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.contentSizeChanged()
            self.snapshot = nil
            self.isEnding = false
            self.finishTask = nil
        }
    }

    deinit {
        contentSizeObservation?.invalidate()
    }
}

/// Finds the `UIScrollView` created by SwiftUI without replacing the eager
/// transcript stack. The resolver sits inside the scroll content and walks to
/// its nearest UIKit scroll ancestor once SwiftUI attaches it to the hierarchy.
struct TranscriptScrollViewResolver: UIViewRepresentable {
    let resolve: @MainActor (UIScrollView) -> Void

    func makeUIView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.isUserInteractionEnabled = false
        view.resolve = resolve
        return view
    }

    func updateUIView(_ uiView: ResolverView, context: Context) {
        uiView.resolve = resolve
        uiView.resolveEnclosingScrollView()
    }

    @MainActor
    final class ResolverView: UIView {
        var resolve: (@MainActor (UIScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolveEnclosingScrollView()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            resolveEnclosingScrollView()
        }

        func resolveEnclosingScrollView() {
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    resolve?(scrollView)
                    return
                }
                ancestor = view.superview
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                var ancestor = self.superview
                while let view = ancestor {
                    if let scrollView = view as? UIScrollView {
                        self.resolve?(scrollView)
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}

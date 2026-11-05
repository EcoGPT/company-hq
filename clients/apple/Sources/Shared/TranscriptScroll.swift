import SwiftUI

/// The scroll-to target parked at the transcript content's outermost stack —
/// below the last row, the typing dots, and the activity shimmer — so a
/// "scroll to the bottom" means the whole conversation, not just the last
/// message with live lines hanging hidden under it.
enum TranscriptAnchor {
    static let bottom = "transcript-bottom"
}

/// History paging belongs to a person's scroll gesture, not to the resulting
/// geometry. While an older page is being prepended, SwiftUI can report both
/// the old and corrected offsets as fresh geometry. Treating either as a new
/// request walks page after page until the entire conversation is mounted.
/// One gesture asks for at most one page; programmatic correction asks for none.
struct TranscriptHistoryTrigger {
    static let threshold: CGFloat = 300

    private(set) var canLoadDuringCurrentGesture = false

    mutating func phaseChanged(from oldPhase: ScrollPhase, to newPhase: ScrollPhase) {
        let beganUserGesture = oldPhase == .idle
            && (newPhase == .tracking
                || newPhase == .interacting
                || newPhase == .decelerating)
        if beganUserGesture {
            canLoadDuringCurrentGesture = true
        } else if newPhase == .idle {
            canLoadDuringCurrentGesture = false
        }
    }

    mutating func shouldLoad(at offsetY: CGFloat) -> Bool {
        guard canLoadDuringCurrentGesture, offsetY < Self.threshold else { return false }
        canLoadDuringCurrentGesture = false
        return true
    }

    mutating func reset() {
        canLoadDuringCurrentGesture = false
    }
}

/// Phone history prefetches as the reader approaches the top, without waiting
/// for a second drag after the scroll view has already stopped there. Once it
/// fires, hysteresis keeps layout callbacks from requesting another page until
/// the prepended content has moved the viewport well away from the trigger.
/// If viewport preservation ever fails, remaining near zero stays disarmed —
/// it cannot walk the entire conversation by accident.
struct TranscriptProximityHistoryTrigger {
    static let threshold: CGFloat = 600
    static let rearmThreshold: CGFloat = 800

    private(set) var canLoad = true

    mutating func shouldLoad(at offsetY: CGFloat) -> Bool {
        if offsetY > Self.rearmThreshold {
            canLoad = true
            return false
        }
        guard canLoad, offsetY < Self.threshold else { return false }
        canLoad = false
        return true
    }

    mutating func reset() {
        canLoad = true
    }
}

/// One frame of the transcript scroll view's geometry, reduced to the two
/// questions pinning asks: is the viewport at the live edge, and did the
/// layout — rather than the offset — move underneath it.
///
/// The default scroll anchors keep a transcript pinned for most content
/// changes, but not all of them: a link preview swapping its text bubble for
/// a card after launch, the history spinner leaving, the floating composer
/// stack growing its content margin. Each grows or shrinks the layout without
/// re-anchoring, and the chat is left parked a little short of the bottom.
/// Comparing consecutive probes tells those layout shifts apart from the user
/// scrolling, so the view can re-assert the bottom only when it was already
/// there.
struct TranscriptScrollProbe: Equatable {
    var offsetY: CGFloat
    var contentHeight: CGFloat
    var topInset: CGFloat
    var bottomInset: CGFloat
    var viewportHeight: CGFloat

    init(_ geometry: ScrollGeometry) {
        offsetY = geometry.contentOffset.y
        contentHeight = geometry.contentSize.height
        topInset = geometry.contentInsets.top
        bottomInset = geometry.contentInsets.bottom
        viewportHeight = geometry.containerSize.height
    }

    /// Zero resting at the very bottom, growing as the user scrolls up.
    /// Negative when the whole transcript fits the viewport. Measured, not
    /// assumed: the resting bottom offset on this SwiftUI is
    /// content + bottomInset - viewport - topInset (the toolbar's safe-area
    /// top inset shifts every offset down by its height).
    var distanceFromBottom: CGFloat {
        contentHeight + bottomInset - viewportHeight - topInset - offsetY
    }

    /// Close enough to the bottom to count as reading the live edge.
    var isAtBottom: Bool { distanceFromBottom < 48 }

    /// Anything but a plain scroll: content grew or shrank, an inset moved
    /// (toolbar, keyboard, composer), or the window resized.
    func layoutDiffers(from other: Self) -> Bool {
        contentHeight != other.contentHeight
            || topInset != other.topInset
            || bottomInset != other.bottomInset
            || viewportHeight != other.viewportHeight
    }
}

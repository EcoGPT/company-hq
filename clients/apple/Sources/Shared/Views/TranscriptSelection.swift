import AppKit

/// One selection spanning the whole transcript, the way Messages selects: a
/// drag that runs out of one bubble keeps going into the next, and ⌘C copies
/// the whole run. Per-bubble `NSTextView` selection cannot do that — each view
/// owns its own and stops at its own edge — so the selection lives here and
/// the bubbles only draw what it tells them.
///
/// Deliberately NOT `@Observable`: a drag moves this many times a second, and
/// routing it through SwiftUI would re-run the transcript's layout on every
/// tick — the same pass a 13s hang was once traced to. The bubbles are told to
/// redraw directly instead.
@MainActor
final class TranscriptSelection {
    /// One end of the selection: a character offset inside one message.
    struct Caret: Equatable {
        let messageId: String
        let index: Int
    }

    private var anchor: Caret?
    private var head: Caret?
    private var registered: [String: WeakBubble] = [:]
    /// `ordered`, kept until the set of bubbles changes. Scrolling moves every
    /// bubble but reorders none of them, so the sort survives it. Empty means
    /// "not resolved yet" — an empty transcript costs nothing to re-resolve.
    private var orderedCache: [BubbleTextView] = []

    private struct WeakBubble {
        weak var view: BubbleTextView?
    }

    // MARK: - The bubbles on screen

    func register(_ view: BubbleTextView, for messageId: String) {
        // SwiftUI re-adopts every bubble on every update pass; only a bubble
        // that actually changed hands is a new order.
        guard registered[messageId]?.view !== view else { return }
        registered[messageId] = WeakBubble(view: view)
        orderedCache = []
    }

    func unregister(_ messageId: String) {
        guard registered.removeValue(forKey: messageId) != nil else { return }
        orderedCache = []
    }

    /// The live bubbles, top to bottom. Transcript order IS the geometry, so
    /// asking the window where each view sits is always right — and saves the
    /// chat from having to publish an id list on every render.
    ///
    /// Cached, because this is a sort of the WHOLE loaded transcript with two
    /// coordinate conversions per comparison, and `draw` reaches it: recomputed
    /// per bubble per frame it cost 5ms a scroll frame at 200 messages, 11ms at
    /// 600 and 20ms at 1200 — most of a frame's budget, spent on a transcript
    /// nobody had selected anything in.
    private var ordered: [BubbleTextView] {
        if !orderedCache.isEmpty { return orderedCache }
        let result = registered.values
            .compactMap(\.view)
            .filter { $0.window != nil }
            .sorted { left, right in
                left.convert(left.bounds.origin, to: nil).y
                    > right.convert(right.bounds.origin, to: nil).y
            }
        orderedCache = result
        return result
    }

    // MARK: - Moving the selection

    func begin(at caret: Caret) {
        let stale = selectedIds
        anchor = caret
        head = caret
        redraw(stale)
    }

    func extend(to caret: Caret) {
        guard anchor != nil, head != caret else { return }
        let before = selectedIds
        head = caret
        redraw(before.union(selectedIds))
    }

    func clear() {
        guard anchor != nil || head != nil else { return }
        let stale = selectedIds
        anchor = nil
        head = nil
        redraw(stale)
    }

    var isEmpty: Bool { selectedIds.isEmpty }

    /// Where a point in window coordinates falls. A point in the gutter beside
    /// a bubble clamps into it; a point in the gap between two lands at the
    /// start of the one below, which is what makes a drag past a bubble take
    /// the whole of it.
    func caret(at windowPoint: NSPoint) -> Caret? {
        let bubbles = ordered
        guard let last = bubbles.last else { return nil }
        for view in bubbles {
            let local = view.convert(windowPoint, from: nil)
            if local.y < view.bounds.minY {
                return Caret(messageId: view.messageId, index: 0)
            }
            if local.y <= view.bounds.maxY {
                let clamped = NSPoint(
                    x: min(max(local.x, view.bounds.minX), view.bounds.maxX), y: local.y
                )
                return Caret(
                    messageId: view.messageId,
                    index: view.characterIndexForInsertion(at: clamped)
                )
            }
        }
        return Caret(messageId: last.messageId, index: last.textStorage?.length ?? 0)
    }

    // MARK: - What is selected

    /// The portion of one message the selection covers: a slice at each end of
    /// the run, the whole message for everything between.
    ///
    /// Every bubble asks this on every `draw`, so the empty selection — which
    /// is nearly always the case — must answer without touching `ordered`.
    func range(in messageId: String) -> NSRange? {
        guard anchor != nil, head != nil else { return nil }
        let bubbles = ordered
        guard let span = span(among: bubbles),
              let position = bubbles.firstIndex(where: { $0.messageId == messageId })
        else { return nil }
        return range(at: position, in: span, among: bubbles)
    }

    /// Where the run starts and ends in transcript order, and which way it
    /// was dragged.
    private struct Span {
        let anchor: Caret
        let head: Caret
        let isForward: Bool
        let first: Int
        let last: Int
    }

    /// Every caller that asks about more than one message resolves the order
    /// and the two ends ONCE and passes them in — looking the ends up again
    /// per message made a drag tick quadratic over the whole transcript.
    private func span(among bubbles: [BubbleTextView]) -> Span? {
        guard let anchor, let head, anchor != head else { return nil }
        guard let anchorAt = bubbles.firstIndex(where: { $0.messageId == anchor.messageId }),
              let headAt = bubbles.firstIndex(where: { $0.messageId == head.messageId })
        else { return nil }

        let isForward = anchorAt < headAt || (anchorAt == headAt && anchor.index <= head.index)
        return Span(
            anchor: anchor, head: head, isForward: isForward,
            first: isForward ? anchorAt : headAt, last: isForward ? headAt : anchorAt
        )
    }

    private func range(at position: Int, in span: Span, among bubbles: [BubbleTextView]) -> NSRange? {
        guard position >= span.first, position <= span.last else { return nil }
        let length = bubbles[position].textStorage?.length ?? 0
        let from = position == span.first
            ? min(span.isForward ? span.anchor.index : span.head.index, length) : 0
        let to = position == span.last
            ? min(span.isForward ? span.head.index : span.anchor.index, length) : length
        return NSRange(location: from, length: max(0, to - from))
    }

    /// The run, in transcript order, one message per line — what ⌘C puts on
    /// the pasteboard.
    func selectedText() -> String {
        let bubbles = ordered
        guard let span = span(among: bubbles) else { return "" }
        return (span.first...span.last)
            .compactMap { position -> String? in
                guard let range = range(at: position, in: span, among: bubbles), range.length > 0
                else { return nil }
                return (bubbles[position].string as NSString).substring(with: range)
            }
            .joined(separator: "\n")
    }

    private var selectedIds: Set<String> {
        let bubbles = ordered
        guard let span = span(among: bubbles) else { return [] }
        var ids: Set<String> = []
        for position in span.first...span.last
        where (range(at: position, in: span, among: bubbles)?.length ?? 0) > 0 {
            ids.insert(bubbles[position].messageId)
        }
        return ids
    }

    private func redraw(_ ids: Set<String>) {
        for id in ids { registered[id]?.view?.needsDisplay = true }
    }
}

import AppKit
import SwiftUI
import XCTest

@testable import HQ

// The probe change answers SwiftUI's zero and unspecified widths from the one
// layout the real width needs. That must not move a drawn bubble: this lays
// out the bubble kinds a chat has, own and incoming, in a narrow and a wide
// column, the way `MessageRow` stacks them, and holds every text frame and
// row size to the frame main's measure gives in the same run. Derived, not
// recorded: glyph metrics differ between macOS releases (CI runs another
// one), so a pinned float would fail there for no change of ours. On the
// Mac that recorded main 255f792625 the two matched exactly.
@MainActor
final class BubbleFrameTests: XCTestCase {
    private static let kinds: [(name: String, text: String, names: [String])] = [
        ("short", "Sounds good", []),
        ("long", String(repeating: "The conversion for this cohort was flat while paywall "
            + "impressions went up, so the test needs a longer window. ", count: 6), []),
        ("code", "Here is the fix:\n```\nlet width = min(proposedWidth ?? contentCap, contentCap) "
            + "// the cap, never more\nreturn measure(text, width)\n```", []),
        ("mention", "@Cy Moss can you check the paywall numbers before the sync?",
         ["Cy Moss"]),
        ("link", "https://example.com/blog/how-we-measure-conversion-across-cohorts-in-2026", []),
    ]

    /// Held to main's frames. A column narrower than a row's minimum width
    /// (140 is below an incoming row's) is laid out and printed but not held:
    /// there the zero-width answer decides the frame, and it moved on purpose.
    private static let heldColumns: Set<CGFloat> = [300, 700]

    /// The incoming row's avatar and the stack's spacing after it.
    private static let avatarLane: CGFloat = 28 + 6

    /// Where main put the text, from main's `sizeThatFits` for a real width
    /// (the proposal capped at `Tokens.Bubble.maxWidth`, measured fresh) and
    /// the row's layout: the bubble capped at the max width and kept off the
    /// far gutter, the text padded inside it, own rows on the trailing edge.
    /// Same shape as `layout`: text x, y, w, h (top-left origin), row w, h.
    private func mainFrame(
        _ text: String, names: [String], isOwn: Bool, column: CGFloat
    ) -> [CGFloat] {
        let lane = isOwn ? 0 : Self.avatarLane
        let padH = Tokens.Bubble.paddingHorizontal
        let padV = Tokens.Bubble.paddingVertical
        let bubble = min(Tokens.Bubble.maxWidth, column - lane - Tokens.Bubble.farGutter)
        let width = min(bubble - 2 * padH, Tokens.Bubble.maxWidth)
        let size = SelectableBubbleText.Measurer().size(of: text, fitting: width) {
            SelectableBubbleText.attributedString(for: text, isOwn: isOwn, names: names)
        }
        let x = isOwn ? column - padH - size.width : lane + padH
        return [x, padV, size.width, size.height, column, max(size.height + 2 * padV, 28)]
    }

    /// `MessageRow`'s stack for one bubble: the avatar lane for an incoming
    /// group row, the bubble capped at `Tokens.Bubble.maxWidth`, the far gutter.
    private struct Row: View {
        let text: String
        let names: [String]
        let isOwn: Bool
        let selection: TranscriptSelection

        var body: some View {
            HStack(alignment: .bottom, spacing: 6) {
                if !isOwn {
                    Circle().frame(width: 28, height: 28)
                }
                VStack(alignment: isOwn ? .trailing : .leading, spacing: 2) {
                    ChatBubble(isOwn: isOwn) {
                        SelectableBubbleText(
                            messageId: "frame", text: text, isOwn: isOwn,
                            names: names, selection: selection
                        )
                    }
                    .frame(maxWidth: Tokens.Bubble.maxWidth, alignment: isOwn ? .trailing : .leading)
                    .padding(isOwn ? .leading : .trailing, Tokens.Bubble.farGutter)
                }
                .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
            }
        }
    }

    private func bubbleView(in view: NSView) -> NSView? {
        if view is BubbleTextView { return view }
        for child in view.subviews {
            if let found = bubbleView(in: child) { return found }
        }
        return nil
    }

    /// Lays one row out in a column `width` wide; answers the text's frame in
    /// the row (top-left origin), the row's size, and the row's answer to a
    /// zero-width proposal (its minimum width).
    private func layout(
        _ text: String, names: [String], isOwn: Bool, width: CGFloat
    ) -> (text: CGRect, row: CGSize, zero: CGSize)? {
        let selection = TranscriptSelection()
        let row = Row(text: text, names: names, isOwn: isOwn, selection: selection)
        let sizing = NSHostingController(rootView: row)
        let tall = CGFloat.greatestFiniteMagnitude
        let fitted = sizing.sizeThatFits(in: CGSize(width: width, height: tall))
        let zero = sizing.sizeThatFits(in: CGSize(width: 0, height: tall))

        let host = NSHostingView(rootView: row)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: fitted.height),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: fitted.height)
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        guard let bubble = bubbleView(in: host) else { return nil }
        var frame = bubble.convert(bubble.bounds, to: host)
        if !host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
        return (frame, fitted, zero)
    }

    private func format(_ values: [CGFloat]) -> String {
        values.map { String(format: "%.1f", Double($0)) }.joined(separator: ",")
    }

    func testBubbleFramesMatchMain() {
        var lines: [String] = []
        for kind in Self.kinds {
            for isOwn in [true, false] {
                for column in [140, 300, 700] as [CGFloat] {
                    let key = "\(kind.name)/\(isOwn ? "own" : "in")/\(Int(column))"
                    guard let laid = layout(kind.text, names: kind.names, isOwn: isOwn, width: column)
                    else {
                        XCTFail("\(key): no bubble text view in the hosted row")
                        continue
                    }
                    let values = [
                        laid.text.minX, laid.text.minY, laid.text.width, laid.text.height,
                        laid.row.width, laid.row.height,
                    ]
                    lines.append(
                        "\(key) text=\(format(Array(values[0..<4]))) row=\(format(Array(values[4...])))"
                            + " zeroProbe=\(format([laid.zero.width, laid.zero.height]))"
                    )
                    if Self.heldColumns.contains(column) {
                        let main = mainFrame(kind.text, names: kind.names, isOwn: isOwn, column: column)
                        lines[lines.count - 1] += " main=\(format(main))"
                        for (got, want) in zip(values, main) {
                            XCTAssertEqual(got, want, accuracy: 1, "\(key) moved from main's frame")
                        }
                    }
                }
            }
        }
        print("BUBBLE-FRAMES-BEGIN\n" + lines.joined(separator: "\n") + "\nBUBBLE-FRAMES-END")
        XCTAssertEqual(lines.count, Self.kinds.count * 6)
    }
}

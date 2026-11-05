import AppKit
import XCTest

@testable import HQ

// A drag across the transcript asks the selection which bubbles it covers on
// every tick. That used to look up the selection's two ends again for every
// bubble — quadratic in the loaded history, 11 ms a tick at 800 bubbles.
// These pin what is selected, and that a tick stays cheap on a long history.
@MainActor
final class TranscriptSelectionSpanTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    /// Bubbles stacked top to bottom in one window, registered in order.
    private func makeBubbles(_ texts: [String]) -> (TranscriptSelection, [BubbleTextView]) {
        let rowHeight: CGFloat = 20
        let height = rowHeight * CGFloat(texts.count)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: height),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        self.window = window
        let selection = TranscriptSelection()
        var bubbles: [BubbleTextView] = []
        for (index, text) in texts.enumerated() {
            let storage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            storage.addLayoutManager(layoutManager)
            let container = NSTextContainer(
                size: CGSize(width: 260, height: CGFloat.greatestFiniteMagnitude)
            )
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            let bubble = BubbleTextView(
                frame: NSRect(
                    x: 0, y: height - rowHeight * CGFloat(index + 1), width: 260, height: rowHeight
                ),
                textContainer: container
            )
            bubble.isEditable = false
            bubble.isSelectable = true
            storage.setAttributedString(
                NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15)])
            )
            bubble.messageId = "m\(index)"
            bubble.selection = selection
            window.contentView?.addSubview(bubble)
            selection.register(bubble, for: bubble.messageId)
            bubbles.append(bubble)
        }
        return (selection, bubbles)
    }

    private let texts = ["alpha one", "bravo two", "charlie three"]

    func testAForwardDragAcrossThreeBubbles() {
        let (selection, _) = makeBubbles(texts)
        selection.begin(at: .init(messageId: "m0", index: 2))
        selection.extend(to: .init(messageId: "m2", index: 3))
        XCTAssertEqual(selection.selectedText(), "pha one\nbravo two\ncha")
        XCTAssertEqual(selection.range(in: "m0"), NSRange(location: 2, length: 7))
        XCTAssertEqual(selection.range(in: "m1"), NSRange(location: 0, length: 9))
        XCTAssertEqual(selection.range(in: "m2"), NSRange(location: 0, length: 3))
        XCTAssertFalse(selection.isEmpty)
    }

    func testAReverseDragSelectsTheSameRun() {
        let (selection, _) = makeBubbles(texts)
        selection.begin(at: .init(messageId: "m2", index: 3))
        selection.extend(to: .init(messageId: "m0", index: 2))
        XCTAssertEqual(selection.selectedText(), "pha one\nbravo two\ncha")
        XCTAssertEqual(selection.range(in: "m0"), NSRange(location: 2, length: 7))
        XCTAssertEqual(selection.range(in: "m1"), NSRange(location: 0, length: 9))
        XCTAssertEqual(selection.range(in: "m2"), NSRange(location: 0, length: 3))
    }

    func testASelectionInsideOneBubble() {
        let (selection, _) = makeBubbles(texts)
        selection.begin(at: .init(messageId: "m1", index: 4))
        selection.extend(to: .init(messageId: "m1", index: 1))
        XCTAssertEqual(selection.selectedText(), "rav")
        XCTAssertEqual(selection.range(in: "m1"), NSRange(location: 1, length: 3))
        XCTAssertNil(selection.range(in: "m0"))
        XCTAssertNil(selection.range(in: "m2"))
    }

    func testNothingIsSelectedOnceTheAnchorBubbleIsGone() {
        let (selection, _) = makeBubbles(texts)
        selection.begin(at: .init(messageId: "m0", index: 2))
        selection.extend(to: .init(messageId: "m2", index: 3))
        selection.unregister("m0")
        XCTAssertNil(selection.range(in: "m1"))
        XCTAssertNil(selection.range(in: "m2"))
        XCTAssertEqual(selection.selectedText(), "")
        XCTAssertTrue(selection.isEmpty)
    }

    func testNoSelectionAnswersNil() {
        let (selection, _) = makeBubbles(texts)
        XCTAssertNil(selection.range(in: "m1"))
        XCTAssertEqual(selection.selectedText(), "")
        XCTAssertTrue(selection.isEmpty)
    }

    // The failing-first timing: a drag down a long history.
    func testADragTickStaysCheapOnALongHistory() {
        let count = 800
        let (selection, _) = makeBubbles((0..<count).map { "message number \($0)" })
        selection.begin(at: .init(messageId: "m0", index: 0))
        let ticks = 50
        let start = CFAbsoluteTimeGetCurrent()
        for tick in 1...ticks {
            selection.extend(to: .init(messageId: "m\(tick * (count - 1) / ticks)", index: 3))
        }
        let mean = (CFAbsoluteTimeGetCurrent() - start) * 1_000 / Double(ticks)
        print("TranscriptSelectionSpanTests timing: \(String(format: "%.3f", mean)) ms per extend at \(count) bubbles")
        XCTAssertLessThan(mean, 3)
    }
}

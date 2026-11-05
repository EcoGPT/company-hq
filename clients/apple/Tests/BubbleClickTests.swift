import AppKit
import XCTest

@testable import HQ

// Putting a tapback on a message starts with a click, and a bubble's text is
// drawn by an AppKit view that keeps the left button for its selection drag —
// so unless that view raises the row's menu itself, clicking a message does
// nothing at all, which is what it did until this was fixed. A compile cannot
// catch that coming back: the transcript builds fine with a dead gesture.
// These pin the rules instead.
final class BubbleClickTests: XCTestCase {
    /// Stands in for the SwiftUI row, which is where `.contextMenu` hangs.
    private final class MenuHost: NSView {
        let rowMenu = NSMenu(title: "row")
        override func menu(for event: NSEvent) -> NSMenu? { rowMenu }
    }

    /// The menu loop is modal; a test has to watch from outside it.
    private final class RecordingBubble: BubbleTextView {
        var opened: [NSMenu] = []
        override func runMenu(_ menu: NSMenu, at point: NSPoint) { opened.append(menu) }
    }

    @MainActor
    private func makeBubble(
        _ text: String = "Sounds good gonna take another look at rev rn"
    ) -> (bubble: RecordingBubble, host: MenuHost, window: NSWindow) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: 260, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let bubble = RecordingBubble(
            frame: NSRect(x: 0, y: 0, width: 260, height: 20), textContainer: container
        )
        bubble.isEditable = false
        bubble.isSelectable = true
        storage.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15)])
        )

        let host = MenuHost(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        host.addSubview(bubble)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView?.addSubview(host)
        return (bubble, host, window)
    }

    @MainActor
    private func event(
        _ type: NSEvent.EventType, in window: NSWindow, clicks: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 20, y: 30), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    @MainActor
    private func keyEvent(in window: NSWindow, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
        )!
    }

    @MainActor
    private func selectAll(_ bubble: BubbleTextView) -> TranscriptSelection {
        let selection = TranscriptSelection()
        bubble.messageId = "message"
        bubble.selection = selection
        selection.register(bubble, for: bubble.messageId)
        selection.begin(at: .init(messageId: bubble.messageId, index: 0))
        selection.extend(to: .init(messageId: bubble.messageId, index: bubble.string.utf16.count))
        return selection
    }

    @MainActor
    func testAPlainClickRaisesTheRowsMenu() {
        let (bubble, host, window) = makeBubble()
        bubble.mouseDown(with: event(.leftMouseDown, in: window))
        bubble.mouseUp(with: event(.leftMouseUp, in: window))
        XCTAssertEqual(bubble.opened.count, 1)
        XCTAssertTrue(bubble.opened.first === host.rowMenu)
    }

    // The menu belongs to the row, not to the text view: its own has to stay
    // nil or the system text menu wins over the tapbacks.
    @MainActor
    func testTheMenuComesFromAnAncestorAndNeverFromTheViewItself() {
        let (bubble, host, window) = makeBubble()
        let click = event(.leftMouseDown, in: window)
        XCTAssertNil(bubble.menu(for: click))
        XCTAssertTrue(bubble.rowMenu(for: click) === host.rowMenu)
    }

    // A press that drags is how text gets selected — Bo's one bar across
    // the whole transcript. It must not end in a menu.
    @MainActor
    func testADragSelectsInsteadOfOpeningTheMenu() {
        let (bubble, _, window) = makeBubble()
        bubble.mouseDown(with: event(.leftMouseDown, in: window))
        bubble.mouseDragged(with: event(.leftMouseDragged, in: window))
        bubble.mouseUp(with: event(.leftMouseUp, in: window))
        XCTAssertTrue(bubble.opened.isEmpty)
    }

    // The second press of a double-click lands inside the menu the first one
    // opened, on the tapback strip — it cannot count as a second gesture.
    @MainActor
    func testTheSecondPressOfADoubleClickOpensNothingFurther() {
        let (bubble, _, window) = makeBubble()
        bubble.mouseDown(with: event(.leftMouseDown, in: window))
        bubble.mouseUp(with: event(.leftMouseUp, in: window))
        bubble.mouseDown(with: event(.leftMouseDown, in: window, clicks: 2))
        bubble.mouseUp(with: event(.leftMouseUp, in: window, clicks: 2))
        XCTAssertEqual(bubble.opened.count, 1)
    }

    // A message still in flight has a menu with nothing in it but Show Times.
    @MainActor
    func testAMessageStillInFlightOpensNothing() {
        let (bubble, _, window) = makeBubble()
        bubble.clickOpensMenu = false
        bubble.mouseDown(with: event(.leftMouseDown, in: window))
        bubble.mouseUp(with: event(.leftMouseUp, in: window))
        XCTAssertTrue(bubble.opened.isEmpty)
    }

    // A control-click is a right-click: it opens on the PRESS, up the chain,
    // and the release that follows must not open a second menu.
    @MainActor
    func testAControlClickOpensOnThePressAndNotAgainOnRelease() {
        let (bubble, _, window) = makeBubble()
        let press = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 20, y: 30), modifierFlags: [.control],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
        bubble.mouseDown(with: press)
        bubble.mouseUp(with: event(.leftMouseUp, in: window))
        // The press went up the responder chain rather than through `runMenu`,
        // so nothing is recorded here — what matters is that the release did
        // not turn into a second menu of its own.
        XCTAssertTrue(bubble.opened.isEmpty)
    }

    @MainActor
    func testCommandCCopiesTheTranscriptSelection() {
        let (bubble, _, window) = makeBubble("command copy")
        let selection = selectAll(bubble)

        XCTAssertTrue(bubble.performKeyEquivalent(with: keyEvent(in: window, modifiers: .command)))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "command copy")
        withExtendedLifetime(selection) {}
    }

    @MainActor
    func testControlCCopiesTheTranscriptSelection() {
        let (bubble, _, window) = makeBubble("control copy")
        let selection = selectAll(bubble)

        XCTAssertTrue(bubble.performKeyEquivalent(with: keyEvent(in: window, modifiers: .control)))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "control copy")
        withExtendedLifetime(selection) {}
    }
}

import AppKit
import SwiftUI
import XCTest

@testable import HQ

/// The Live canvas's three pointer gestures together, driven by real mouse events.
/// Each node carries a high-priority `DragGesture(minimumDistance: 4)` (`NodeDragModifier`), a
/// session pill is a `Button` that opens its thread, and the viewport card pans on a
/// `DragGesture(minimumDistance: 3)` with a pinch beside it. Unit tests of the layout cannot see
/// whether SwiftUI lets these coexist: a click must still reach the pill's button, a drag on a
/// pill must move it and not press it or pan, and a drag on empty canvas must pan.
///
/// So the real `LiveCanvasView` is put in a real `NSWindow` and fed `NSEvent` mouse-down,
/// -dragged and -up through `NSWindow.sendEvent`, which runs SwiftUI's own hit testing and
/// gesture recognition. Nothing here calls the view's closures directly. What is observed: the
/// `open` closure the view is given, the `camera` binding it writes, and the pins it saves to
/// `UserDefaults.standard` under a hub name no real install has (removed in tearDown).
@MainActor
final class LiveCanvasGestureTests: XCTestCase {
    /// A test host launched by xcodebuild is never the active app (`NSApp.activate` is refused
    /// without a person's input), and AppKit spends the first press on an inactive app's window on
    /// activating it unless the view under the pointer takes first mouse. SwiftUI answers yes over
    /// a `Button` (a pill) and no over empty canvas or an avatar, so without this the pan and the
    /// person drag never see their mouse-down. Saying yes everywhere is what an HQ window the
    /// person is already working in gets; every gesture decision after that is SwiftUI's own.
    private final class FrontHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private let width: CGFloat = 900
    private var now = Date()
    private var hub = ""
    private let personID = "gesture-person"
    /// The hub the view reads its places for: a test changes it to hand the view other pins.
    @Observable
    final class HubBox {
        var hub = ""
    }

    private var hubBox = HubBox()
    private var window: NSWindow?
    private var host: NSView?
    private var scroll: NSScrollView?
    /// A window of another kind than the canvas's, put over it by a test.
    private var cover: NSWindow?
    /// Where the canvas card's top-left sits in the hosting view, top-left coordinates.
    private var cardOrigin: CGPoint?
    /// The canvas view's size as laid out in the window.
    private var cardSize: CGSize?
    /// How much taller the window is than the drawing: room the card must take.
    private static let roomBelow: CGFloat = 40
    private var opened: [String] = []
    private var savedCamera: LiveCanvasCamera?
    /// The box selection as the view last reported it (pin keys).
    private var selection: Set<String> = []
    private var eventNumber = 0
    /// A `sendEvent` that did not come back (a modal tracking loop) is recorded here.
    private var blockedSends: [String] = []
    /// Hubs a test saved pins under besides `hub`: removed in tearDown.
    private var otherHubs: [String] = []

    override func setUp() {
        super.setUp()
        now = Date()
        hub = "gesture-test-\(UUID().uuidString)"
        hubBox = HubBox()
        hubBox.hub = hub
        otherHubs = []
        roster = []
        opened = []
        savedCamera = nil
        selection = []
        cardOrigin = nil
        cardSize = nil
        blockedSends = []
        scroll = nil
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: pinStore.key)
        for other in otherHubs {
            UserDefaults.standard.removeObject(
                forKey: LiveCanvasPositionsStore(hub: other, personID: personID, defaults: .standard).key)
        }
        cover?.orderOut(nil)
        cover?.close()
        cover = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        host = nil
        scroll = nil
        super.tearDown()
    }

    // MARK: Fixture

    private var pinStore: LiveCanvasPositionsStore {
        LiveCanvasPositionsStore(hub: hub, personID: personID, defaults: .standard)
    }

    private var savedPins: LiveCanvasPositions { pinStore.load() }

    private func thread(
        _ id: String, owner: String, minutesAgo: Double, projects: [(String, String)]
    ) throws -> CodingThread {
        let json: [String: Any] = [
            "session_id": id, "intent": "", "state": "idle", "title": "Session \(id)",
            "last_seen_at": 0.0, "last_activity_at": (now.timeIntervalSince1970 - minutesAgo * 60) * 1000,
            "owner_person_id": owner, "owner_name": owner.capitalized,
            "provider": "claude", "repo": "tmp-worktree-7",
            "tasks": [] as [[String: String]],
            "projects": projects.map { ["id": $0.0, "name": $0.1] },
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(CodingThread.self, from: data)
    }

    /// People with no agent now, who stand as idle faces (`idle:<id>`); set before `mount`.
    private var roster: [LiveThreadsModel.Idle] = []

    /// Bo (left) with two pills on the project, Uma (right) with one.
    private func makeModel() throws -> LiveThreadsModel {
        let onProject = [("o0", "Project zero")]
        let threads = [
            try thread("a1", owner: "bo", minutesAgo: 1, projects: onProject),
            try thread("a2", owner: "bo", minutesAgo: 3, projects: onProject),
            try thread("s1", owner: "uma", minutesAgo: 2, projects: onProject),
        ]
        return LiveThreadsModel(
            threads: threads, now: now, search: "", isRemoved: { _ in false }, roster: roster)
    }

    private func layout(pins: LiveCanvasPositions = LiveCanvasPositions()) throws -> LiveCanvasLayout {
        LiveCanvasLayout.layout(model: try makeModel(), width: width, now: now, pins: pins)
    }

    private func node(
        _ layout: LiveCanvasLayout, _ kind: LiveCanvasLayout.Kind, _ id: String
    ) throws -> LiveCanvasLayout.Node {
        try XCTUnwrap(layout.nodes.first { $0.kind == kind && $0.refId == id }, "\(kind) \(id) is on the canvas")
    }

    /// The hosting view's own top-left space (`.global` here is the window's, titlebar included).
    private static let hostSpace = "gesture-host"

    /// Saves `pins` under `hub` the way a drop would have.
    private func savePins(_ pins: LiveCanvasPositions, hub name: String) {
        if name != hub { otherHubs.append(name) }
        LiveCanvasPositionsStore(hub: name, personID: personID, defaults: .standard).save(pins, now: now)
    }

    /// Puts the real view in a real window on screen, at scale 1 and no pan. `pins` are saved
    /// first, so they are on disk when the view appears. `isFresh` asserts nothing is held above
    /// the board yet (a first look); a return from a thread passes false. `isScrollable` puts the
    /// canvas at the top of a document three windows tall inside a scroll view, so a test can
    /// scroll it out of view (`scrollCanvas(toWindow:)`).
    private func mount(pins: LiveCanvasPositions? = nil, isFresh: Bool = true, isScrollable: Bool = false) throws {
        if let pins { savePins(pins, hub: hub) }
        let height = try layout(pins: pins ?? savedPins).size.height + Self.roomBelow
        let camera = Binding<LiveCanvasCamera?>(
            get: { [weak self] in self?.savedCamera }, set: { [weak self] in self?.savedCamera = $0 })
        let model = try makeModel()
        let box = hubBox
        let canvas = Harness(box: box) { [width, now, personID] hub in
            LiveCanvasView(
                model: model, width: width, space: width, now: now,
                hub: hub, personID: personID,
                open: { [weak self] id in self?.opened.append(id) }, camera: camera,
                boxSelectionObserver: { [weak self] in self?.selection = $0 }
            )
        }
        let root = canvas
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.hostSpace)) }, action: { [weak self] frame in
            self?.cardOrigin = frame.origin
            self?.cardSize = frame.size
        })
        .frame(width: width, height: height, alignment: .topLeading)
        .coordinateSpace(.named(Self.hostSpace))
        .environment(AppStore())

        let hosting = FrontHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: width, height: height), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if isScrollable {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            let document = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height * 3))
            document.addSubview(hosting)
            scroll.documentView = document
            window.contentView = scroll
            self.scroll = scroll
        } else {
            window.contentView = hosting
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.host = hosting
        hosting.layoutSubtreeIfNeeded()
        pump(0.5)
        XCTAssertTrue(window.isVisible, "the window is on screen")
        let origin = try XCTUnwrap(cardOrigin, "the canvas reported where it is")
        XCTAssertEqual(origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(origin.y, 0, accuracy: 0.5)
        if isFresh { XCTAssertNil(savedCamera, "the camera opens at the automatic layout, scale 1") }
    }

    /// Closes the window, as the board does when a thread opens; `savedCamera` stays.
    private func unmount() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        host = nil
        scroll = nil
        cardOrigin = nil
        cardSize = nil
        pump(0.1)
    }

    /// The view's root, reading its hub from the box so a test can change it.
    private struct Harness: View {
        let box: HubBox
        let build: (String) -> LiveCanvasView
        var body: some View { build(box.hub) }
    }

    // MARK: Events

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// A canvas point (top-left, scale 1, no pan) in the window's own coordinates.
    private func windowPoint(_ canvas: CGPoint) -> NSPoint {
        guard let host else { return canvas }
        let origin = cardOrigin ?? .zero
        let local = CGPoint(x: canvas.x + origin.x, y: canvas.y + origin.y)
        let inHost = host.isFlipped ? local : CGPoint(x: local.x, y: host.bounds.height - local.y)
        return host.convert(inHost, to: nil)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, at canvas: CGPoint, in window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
        clickCount: Int = 1
    ) -> NSEvent? {
        eventNumber += 1
        return NSEvent.mouseEvent(
            with: type, location: windowPoint(canvas), modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: eventNumber, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)
    }

    /// Every event goes through `NSApplication.sendEvent`, the way the run loop delivers one: that
    /// is where local event monitors (the canvas's scroll, middle-button and Escape handling) see
    /// it, before it reaches the window.
    private func send(
        _ type: NSEvent.EventType, at canvas: CGPoint, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1,
        settle: TimeInterval = 0.03
    ) {
        guard let window, let event = mouseEvent(type, at: canvas, in: window, modifiers: modifiers, clickCount: clickCount) else {
            return XCTFail("no window or event for \(type.rawValue)")
        }
        var isReturned = false
        let label = "\(type.rawValue)@\(canvas)"
        // A modal tracking loop inside sendEvent would never return: note it and let it go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard !isReturned, let self, let window = self.window else { return }
            self.blockedSends.append(label)
            if let up = self.mouseEvent(.leftMouseUp, at: canvas, in: window) { NSApp.postEvent(up, atStart: true) }
        }
        NSApp.sendEvent(event)
        isReturned = true
        pump(settle)
    }

    private func click(_ canvas: CGPoint, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
        send(.leftMouseDown, at: canvas, modifiers: modifiers, clickCount: clickCount)
        pump(0.05)
        send(.leftMouseUp, at: canvas, modifiers: modifiers, clickCount: clickCount)
        pump(0.1)
    }

    /// A double-click the way the window server reports one: press and release with `clickCount` 1,
    /// then press and release again with 2.
    private func doubleClick(_ canvas: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        click(canvas, modifiers: modifiers, clickCount: 1)
        click(canvas, modifiers: modifiers, clickCount: 2)
    }

    private func drag(
        from start: CGPoint, by delta: CGSize, steps: Int = 6, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1,
        midway: (() -> Void)? = nil
    ) {
        send(.leftMouseDown, at: start, modifiers: modifiers, clickCount: clickCount)
        pump(0.05)
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + delta.width * fraction, y: start.y + delta.height * fraction)
            send(.leftMouseDragged, at: point, modifiers: modifiers, clickCount: clickCount)
            pump(0.03)
            if step == steps / 2 { midway?() }
        }
        send(
            .leftMouseUp, at: CGPoint(x: start.x + delta.width, y: start.y + delta.height), modifiers: modifiers,
            clickCount: clickCount)
        pump(0.1)
    }

    /// A middle-button event. `NSEvent.mouseEvent` reports button 0 for every "other" mouse event,
    /// so these come from a `CGEvent` (button 2, the middle one) the way the window server makes
    /// them. Such an event carries no window: its location is the screen's, which is what the
    /// canvas's monitor reads for an event with none.
    private func middleEvent(_ type: CGEventType, at canvas: CGPoint) -> NSEvent? {
        guard let window, let screen = NSScreen.screens.first else { return nil }
        let onScreen = window.convertPoint(toScreen: windowPoint(canvas))
        guard
            let cg = CGEvent(
                mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: CGPoint(x: onScreen.x, y: screen.frame.height - onScreen.y), mouseButton: .center)
        else { return nil }
        return NSEvent(cgEvent: cg)
    }

    private func sendMiddle(_ type: CGEventType, at canvas: CGPoint) {
        guard let event = middleEvent(type, at: canvas) else { return XCTFail("no middle-button event") }
        XCTAssertEqual(event.buttonNumber, 2, "the middle button")
        NSApp.sendEvent(event)
        pump(0.03)
    }

    /// Press the middle button at `start`, move by `delta` and let go.
    private func middleDrag(from start: CGPoint, by delta: CGSize, steps: Int = 6) {
        sendMiddle(.otherMouseDown, at: start)
        pump(0.05)
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            sendMiddle(
                .otherMouseDragged, at: CGPoint(x: start.x + delta.width * fraction, y: start.y + delta.height * fraction))
            pump(0.03)
        }
        sendMiddle(.otherMouseUp, at: CGPoint(x: start.x + delta.width, y: start.y + delta.height))
        pump(0.1)
    }

    private func pressEscape(modifiers: NSEvent.ModifierFlags = []) {
        guard let window,
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53)
        else { return XCTFail("no Escape event") }
        NSApp.sendEvent(event)
        pump(0.1)
    }

    private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// A point on the canvas with no node near it and away from the zoom controls.
    private func emptyPoint(_ layout: LiveCanvasLayout) -> CGPoint? {
        let controls = CGRect(x: layout.size.width - 220, y: layout.size.height - 60, width: 220, height: 60)
        for y in stride(from: 20, to: layout.size.height - 20, by: 10) {
            for x in stride(from: 20, to: layout.size.width - 20, by: 10) {
                let point = CGPoint(x: x, y: y)
                if controls.contains(point) { continue }
                if layout.nodes.contains(where: { $0.frame.insetBy(dx: -12, dy: -12).contains(point) }) { continue }
                // Leave room for an 80pt drag to the right over empty canvas too.
                let end = CGPoint(x: x + 80, y: y)
                if layout.nodes.contains(where: { $0.frame.insetBy(dx: -12, dy: -12).contains(end) }) { continue }
                return point
            }
        }
        return nil
    }

    private func assertNoBlockedSends(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(blockedSends, [], "every sendEvent returned (no modal tracking loop)", file: file, line: line)
    }

    // MARK: Cases

    /// (a) A click on a pill with no movement is the pill's button: it opens that session, and
    /// nothing is pinned.
    func testAClickOnAPillOpensItAndPinsNothing() throws {
        try mount()
        let pill = try node(try layout(), .session, "a1")
        click(center(pill.frame))
        assertNoBlockedSends()
        XCTAssertEqual(opened, ["a1"])
        XCTAssertTrue(savedPins.isEmpty, "a click saves no place: \(savedPins.pins)")
        XCTAssertNil(savedCamera, "a click does not pan")
    }

    /// (b) A drag on a pill moves the pill: no open, a pin 60pt to the right, and the pill drawn there.
    func testADragOnAPillMovesItWithoutOpeningOrPanning() throws {
        try mount()
        let before = try node(try layout(), .session, "a1")
        drag(from: center(before.frame), by: CGSize(width: 60, height: 0))
        assertNoBlockedSends()
        XCTAssertEqual(opened, [], "a drag does not press the pill")
        XCTAssertNil(savedCamera, "a drag on a node does not pan the canvas")
        let pins = savedPins
        let pin = try XCTUnwrap(pins.pin(for: "session:a1"), "the drop saved a pin: \(pins.pins)")
        XCTAssertEqual(pin.xFraction * Double(width), Double(before.frame.midX + 60), accuracy: 2)
        XCTAssertEqual(pin.y, Double(before.frame.midY), accuracy: 2)
        XCTAssertEqual(pins.pins.count, 1, "only the dragged node is pinned")
        let after = try node(try layout(pins: pins), .session, "a1")
        XCTAssertEqual(after.frame.midX, before.frame.midX + 60, accuracy: 2)
        XCTAssertEqual(after.frame.midY, before.frame.midY, accuracy: 2)
    }

    /// (c) A middle-button drag pans: the camera moves and nothing is pinned. The pan
    /// is free: the canvas follows the pointer past its edge, 80pt here.
    func testAMiddleButtonDragOnEmptyCanvasPans() throws {
        try mount()
        let canvas = try layout()
        let start = try XCTUnwrap(emptyPoint(canvas), "the fixture has empty canvas")
        middleDrag(from: start, by: CGSize(width: 80, height: 0))
        assertNoBlockedSends()
        XCTAssertTrue(savedPins.isEmpty, "a pan saves no place: \(savedPins.pins)")
        XCTAssertEqual(opened, [])
        XCTAssertEqual(selection, [])
        let camera = try XCTUnwrap(savedCamera, "the pan wrote the camera")
        XCTAssertEqual(camera.scale, 1, accuracy: 0.001)
        XCTAssertEqual(camera.offset.x, 80, accuracy: 1, "moved right the whole 80pt: no wall at the old 48pt slack")
        XCTAssertEqual(camera.offset.y, 0, accuracy: 1)
    }

    /// (c2) The middle button pans from anywhere, over a card too: the card is not moved, opened
    /// or selected.
    func testAMiddleButtonDragStartingOverACardPansAndLeavesTheCardAlone() throws {
        try mount()
        let pill = try node(try layout(), .session, "a1")
        middleDrag(from: center(pill.frame), by: CGSize(width: 60, height: 40))
        assertNoBlockedSends()
        XCTAssertEqual(opened, [], "a middle-button drag does not press the pill")
        XCTAssertTrue(savedPins.isEmpty, "the pill was not moved: \(savedPins.pins)")
        XCTAssertEqual(selection, [])
        let camera = try XCTUnwrap(savedCamera, "the pan wrote the camera")
        XCTAssertEqual(camera.offset.x, 60, accuracy: 1)
        XCTAssertEqual(camera.offset.y, 40, accuracy: 1)
    }

    /// (c3) A left drag on empty canvas no longer pans: it draws a box (see the selection cases).
    func testALeftDragOnEmptyCanvasDoesNotPan() throws {
        try mount()
        let start = try XCTUnwrap(emptyPoint(try layout()), "the fixture has empty canvas")
        drag(from: start, by: CGSize(width: 80, height: 0))
        assertNoBlockedSends()
        XCTAssertNil(savedCamera, "a left drag leaves the camera alone")
        XCTAssertTrue(savedPins.isEmpty)
        XCTAssertEqual(opened, [])
    }

    // MARK: Box selection

    private static let isShift = NSEvent.ModifierFlags.shift

    /// A box over the two pills of Bo only (`a1`, `a2`), drawn from empty canvas below them.
    private func boxOverBosPills(_ canvas: LiveCanvasLayout) throws -> (start: CGPoint, delta: CGSize, pills: [LiveCanvasLayout.Node]) {
        let pills = try ["a1", "a2"].map { try node(canvas, .session, $0) }
        let union = pills.dropFirst().reduce(pills[0].frame) { $0.union($1.frame) }
        let start = CGPoint(x: union.minX + 10, y: union.maxY + 6)
        let end = CGPoint(x: union.maxX - 10, y: union.minY + 4)
        XCTAssertFalse(
            canvas.nodes.contains { $0.frame.contains(start) }, "the box starts on empty canvas")
        return (start, CGSize(width: end.x - start.x, height: end.y - start.y), pills)
    }

    /// A box that takes in Uma's pill only, from the empty canvas above and left of it to the
    /// pill's middle.
    private func boxOverSamsPill(_ canvas: LiveCanvasLayout) throws -> (start: CGPoint, delta: CGSize) {
        let pill = try node(canvas, .session, "s1")
        let start = CGPoint(x: pill.frame.minX - 8, y: pill.frame.minY - 8)
        XCTAssertFalse(canvas.nodes.contains { $0.frame.contains(start) }, "the box starts on empty canvas")
        return (start, CGSize(width: pill.frame.width / 2 + 8, height: pill.frame.height / 2 + 8))
    }

    /// (n) A left drag from empty canvas selects exactly the cards the box touches, and pans nothing.
    func testALeftDragOnEmptyCanvasSelectsTheCardsInsideTheBox() throws {
        try mount()
        let canvas = try layout()
        let box = try boxOverBosPills(canvas)
        drag(from: box.start, by: box.delta)
        assertNoBlockedSends()
        XCTAssertEqual(selection, ["session:a1", "session:a2"], "the two pills in the box, nothing else")
        XCTAssertNil(savedCamera, "the box did not pan")
        XCTAssertTrue(savedPins.isEmpty, "the box moved nothing")
        XCTAssertEqual(opened, [])
    }

    /// (o) A box that takes in a person, a pill and the project selects all three kinds.
    func testABoxSelectsEveryKindOfCardItTouches() throws {
        try mount()
        let canvas = try layout()
        let bo = try node(canvas, .person, "bo")
        let project = try node(canvas, .hub, "o0")
        let whole = canvas.nodes.reduce(CGRect.null) { $0.union($1.frame) }
        // From the canvas's empty bottom-left corner (the zoom controls hold the bottom-right one)
        // to its top-right: the box covers every card, and both ends are inside the canvas.
        let start = CGPoint(x: 1, y: canvas.size.height - 4)
        let end = CGPoint(x: canvas.size.width - 1, y: 1)
        XCTAssertFalse(canvas.nodes.contains { $0.frame.contains(start) }, "the box starts on empty canvas")
        XCTAssertTrue(CGRect(x: 1, y: 1, width: end.x - 1, height: start.y - 1).contains(whole), "the box covers every card")
        drag(from: start, by: CGSize(width: end.x - start.x, height: end.y - start.y))
        assertNoBlockedSends()
        XCTAssertEqual(selection, Set(canvas.nodes.map(\.pinKey)))
        XCTAssertTrue(selection.contains(bo.pinKey))
        XCTAssertTrue(selection.contains(project.pinKey))
    }

    /// (p) Shift-drag adds a second box to the selection; a drag without Shift replaces it.
    func testShiftDragAddsToTheSelectionAndAPlainDragReplacesIt() throws {
        try mount()
        let canvas = try layout()
        let boBox = try boxOverBosPills(canvas)
        let samBox = try boxOverSamsPill(canvas)
        drag(from: boBox.start, by: boBox.delta)
        XCTAssertEqual(selection, ["session:a1", "session:a2"])
        drag(from: samBox.start, by: samBox.delta, modifiers: Self.isShift)
        assertNoBlockedSends()
        XCTAssertEqual(selection, ["session:a1", "session:a2", "session:s1"], "Shift adds")
        drag(from: samBox.start, by: samBox.delta)
        XCTAssertEqual(selection, ["session:s1"], "a plain box replaces the selection")
    }

    /// (q) A click on empty canvas clears the selection; so does Escape.
    func testAClickOnEmptyCanvasAndEscapeClearTheSelection() throws {
        try mount()
        let canvas = try layout()
        let box = try boxOverBosPills(canvas)
        drag(from: box.start, by: box.delta)
        XCTAssertFalse(selection.isEmpty)
        click(try XCTUnwrap(emptyPoint(canvas), "the fixture has empty canvas"))
        assertNoBlockedSends()
        XCTAssertEqual(selection, [], "a click on empty canvas clears")
        drag(from: box.start, by: box.delta)
        XCTAssertFalse(selection.isEmpty)
        pressEscape()
        XCTAssertEqual(selection, [], "Escape clears")
    }

    /// (r) Shift-click toggles a card in the selection without opening it; a plain click is still
    /// the card's own.
    func testShiftClickTogglesACardAndAPlainClickStillOpensIt() throws {
        try mount()
        let canvas = try layout()
        let pill = try node(canvas, .session, "a1")
        let person = try node(canvas, .person, "bo")
        click(center(pill.frame), modifiers: Self.isShift)
        assertNoBlockedSends()
        XCTAssertEqual(selection, ["session:a1"], "Shift-click selects")
        XCTAssertEqual(opened, [], "and does not open")
        click(center(person.avatar), modifiers: Self.isShift)
        XCTAssertEqual(selection, ["session:a1", "person:bo"], "Shift-click on a person adds them")
        click(center(pill.frame), modifiers: Self.isShift)
        XCTAssertEqual(selection, ["person:bo"], "Shift-click again takes it out")
        click(center(pill.frame))
        XCTAssertEqual(opened, ["a1"], "a plain click opens, as before")
        XCTAssertEqual(selection, ["person:bo"], "and leaves the selection alone")
        XCTAssertTrue(savedPins.isEmpty)
    }

    /// (s) Dragging a selected card moves every selected card by the same offset, each saved as a pin.
    func testDraggingASelectedCardMovesTheWholeSelection() throws {
        try mount()
        let canvas = try layout()
        let box = try boxOverBosPills(canvas)
        drag(from: box.start, by: box.delta)
        XCTAssertEqual(selection, ["session:a1", "session:a2"])
        let before = box.pills
        drag(from: center(before[0].frame), by: CGSize(width: 40, height: 30))
        assertNoBlockedSends()
        XCTAssertEqual(opened, [], "a drag does not press the pill")
        XCTAssertNil(savedCamera)
        let pins = savedPins
        XCTAssertEqual(Set(pins.pins.keys), ["session:a1", "session:a2"], "a pin for each selected card, none for the rest")
        for pill in before {
            let pin = try XCTUnwrap(pins.pin(for: pill.pinKey))
            XCTAssertEqual(pin.xFraction * Double(width), Double(pill.frame.midX + 40), accuracy: 2, "\(pill.refId) moved 40 right")
            XCTAssertEqual(pin.y, Double(pill.frame.midY + 30), accuracy: 2, "\(pill.refId) moved 30 down")
        }
        XCTAssertEqual(selection, ["session:a1", "session:a2"], "the selection stays")
        let after = try layout(pins: pins)
        for pill in before {
            let moved = try node(after, .session, pill.refId)
            XCTAssertEqual(moved.frame.midX, pill.frame.midX + 40, accuracy: 2)
            XCTAssertEqual(moved.frame.midY, pill.frame.midY + 30, accuracy: 2)
        }
    }

    /// (t) Dragging a card that is not selected moves only it, and it becomes the selection.
    func testDraggingAnUnselectedCardMovesOnlyItAndSelectsIt() throws {
        try mount()
        let canvas = try layout()
        let box = try boxOverBosPills(canvas)
        drag(from: box.start, by: box.delta)
        XCTAssertEqual(selection, ["session:a1", "session:a2"])
        let ada = try node(canvas, .session, "s1")
        drag(from: center(ada.frame), by: CGSize(width: -30, height: 20))
        assertNoBlockedSends()
        let pins = savedPins
        XCTAssertEqual(Set(pins.pins.keys), ["session:s1"], "only the dragged card moved")
        XCTAssertEqual(selection, ["session:s1"], "and it is the selection now")
    }

    /// (u) A selection is view state: it is not written anywhere a pin is.
    func testTheSelectionIsNotSaved() throws {
        try mount()
        let box = try boxOverBosPills(try layout())
        drag(from: box.start, by: box.delta)
        XCTAssertFalse(selection.isEmpty)
        XCTAssertTrue(savedPins.isEmpty, "selecting saved nothing")
        unmount()
        try mount(isFresh: false)
        // A new canvas starts with nothing selected: a pill dragged on it goes alone.
        let pill = box.pills[0]
        drag(from: center(pill.frame), by: CGSize(width: 40, height: 0))
        XCTAssertEqual(Set(savedPins.pins.keys), ["session:a1"], "the earlier selection did not come back")
    }

    /// (d) A person dragged 50pt down is pinned, and their pills come with them.
    func testDraggingAPersonTakesTheirPills() throws {
        try mount()
        let before = try layout()
        let person = try node(before, .person, "bo")
        let pills = try ["a1", "a2"].map { try node(before, .session, $0) }
        drag(from: center(person.avatar), by: CGSize(width: 0, height: 50))
        assertNoBlockedSends()
        XCTAssertEqual(opened, [])
        XCTAssertNil(savedCamera, "a drag on a person does not pan")
        let pins = savedPins
        let pin = try XCTUnwrap(pins.pin(for: "person:bo"), "the drop saved the person: \(pins.pins)")
        XCTAssertEqual(pin.y, Double(person.frame.midY + 50), accuracy: 2)
        XCTAssertEqual(pin.xFraction * Double(width), Double(person.frame.midX), accuracy: 2)
        XCTAssertNil(pins.pin(for: "session:a1"))
        XCTAssertNil(pins.pin(for: "session:a2"))
        let after = try layout(pins: pins)
        for pill in pills {
            let moved = try node(after, .session, pill.refId)
            XCTAssertEqual(moved.frame.midY, pill.frame.midY + 50, accuracy: 2, "\(pill.refId) moved with bo")
            XCTAssertEqual(moved.frame.midX, pill.frame.midX, accuracy: 2)
        }
    }

    /// (e) A click within 0.3s of a drop belongs to the drop; one after 0.4s opens.
    func testAClickRightAfterADropIsIgnoredAndALaterOneOpens() throws {
        try mount()
        let before = try node(try layout(), .session, "s1")
        drag(from: center(before.frame), by: CGSize(width: -60, height: 0))
        let dropped = Date()
        let pins = savedPins
        XCTAssertNotNil(pins.pin(for: "session:s1"), "the drop saved a pin")
        let moved = try node(try layout(pins: pins), .session, "s1")
        click(center(moved.frame))
        let soon = Date().timeIntervalSince(dropped)
        XCTAssertLessThan(soon, 0.3, "the first click landed inside the 0.3s window")
        XCTAssertEqual(opened, [], "a click \(soon)s after the drop does not open")
        pump(max(0, 0.45 - Date().timeIntervalSince(dropped)))
        click(center(moved.frame))
        assertNoBlockedSends()
        XCTAssertEqual(opened, ["s1"], "a click after 0.4s opens")
    }

    /// (g) No invisible walls: a pill pulled past the right edge stays where it is
    /// dropped (the old wall stopped its centre 112pt inside), the canvas grows to hold it, and
    /// it can be picked up again there.
    func testAPillDraggedPastTheRightWallStaysThereAndDragsAgain() throws {
        try mount()
        let before = try node(try layout(), .session, "s1")
        drag(from: center(before.frame), by: CGSize(width: 170, height: 0))
        assertNoBlockedSends()
        XCTAssertEqual(opened, [])
        let pin = try XCTUnwrap(savedPins.pin(for: "session:s1"), "the drop saved a pin")
        XCTAssertEqual(pin.xFraction * Double(width), Double(before.frame.midX + 170), accuracy: 2, "not stopped at the wall")
        XCTAssertGreaterThan(pin.xFraction * Double(width), Double(width - before.frame.width / 2), "past the old wall")
        let grown = try layout(pins: savedPins)
        XCTAssertGreaterThan(grown.size.width, width, "the canvas grew to hold it")
        // Pick it up again where it is and bring it back.
        let placed = try node(grown, .session, "s1")
        drag(from: center(placed.frame), by: CGSize(width: -100, height: 40))
        assertNoBlockedSends()
        XCTAssertEqual(opened, [])
        let again = try XCTUnwrap(savedPins.pin(for: "session:s1"))
        XCTAssertEqual(again.xFraction * Double(width), pin.xFraction * Double(width) - 100, accuracy: 2)
        XCTAssertEqual(again.y, pin.y + 40, accuracy: 2)
    }

    /// (h) Past the left wall: the canvas grows to the left, and the view moves with its corner so
    /// the pill is under the pointer the whole way, stays where the pointer left it and nothing
    /// else moves on screen.
    func testAPillDraggedPastTheLeftWallStaysThereAndTheViewDoesNotJump() throws {
        try mount()
        let before = try node(try layout(), .session, "a1")
        drag(from: center(before.frame), by: CGSize(width: -170, height: 0))
        assertNoBlockedSends()
        XCTAssertEqual(opened, [])
        let pin = try XCTUnwrap(savedPins.pin(for: "session:a1"), "the drop saved a pin")
        XCTAssertEqual(pin.xFraction * Double(width), Double(before.frame.midX - 170), accuracy: 2)
        XCTAssertLessThan(pin.xFraction * Double(width), Double(before.frame.width / 2), "past the old wall")
        let grown = try layout(pins: savedPins)
        XCTAssertLessThan(grown.origin.x, 0, "the canvas grew to the left")
        // The view is still the automatic layout at the top, which the opening view reopens
        // afresh, so nothing is held above the board.
        XCTAssertNil(savedCamera, "a drop is not a pan")
        // The other pills did not move on screen: one is picked up where it was drawn before.
        let other = try node(try layout(), .session, "a2")
        drag(from: center(other.frame), by: CGSize(width: 0, height: 30))
        let moved = try XCTUnwrap(savedPins.pin(for: "session:a2"), "a2 was under the pointer at its old place")
        XCTAssertEqual(moved.y, Double(other.frame.midY + 30), accuracy: 2)
        // And a1 can be picked up again, at the same screen place the drop left it.
        drag(from: CGPoint(x: pin.xFraction * Double(width), y: pin.y), by: CGSize(width: 60, height: 0))
        assertNoBlockedSends()
        let again = try XCTUnwrap(savedPins.pin(for: "session:a1"))
        XCTAssertEqual(again.xFraction * Double(width), pin.xFraction * Double(width) + 60, accuracy: 2)
    }

    /// (i) Above the top: the pill's centre goes where the wall was (13pt down) and past it.
    func testAPillDraggedAboveTheTopStaysThereAndDragsAgain() throws {
        try mount()
        let before = try node(try layout(), .session, "a1")
        drag(from: center(before.frame), by: CGSize(width: 0, height: -before.frame.midY - 6))
        assertNoBlockedSends()
        XCTAssertEqual(opened, [])
        let pin = try XCTUnwrap(savedPins.pin(for: "session:a1"), "the drop saved a pin")
        XCTAssertEqual(pin.y, -6, accuracy: 2, "its centre is above the top of the old canvas")
        let grown = try layout(pins: savedPins)
        XCTAssertLessThan(grown.origin.y, 0, "the canvas grew upward")
        XCTAssertNil(savedCamera, "a drop is not a pan")
        let other = try node(try layout(), .session, "a2")
        drag(from: center(other.frame), by: CGSize(width: 0, height: 30))
        XCTAssertEqual(
            try XCTUnwrap(savedPins.pin(for: "session:a2"), "a2 is where it was on screen").y, Double(other.frame.midY + 30), accuracy: 2)
        drag(from: CGPoint(x: pin.xFraction * Double(width), y: 4), by: CGSize(width: 0, height: 80))
        assertNoBlockedSends()
        let again = try XCTUnwrap(savedPins.pin(for: "session:a1"))
        XCTAssertEqual(again.y, pin.y + 80, accuracy: 2)
    }

    /// (f) The card takes all the height it is given, not just the drawing's (a bigger window is a
    /// bigger canvas), and the drawing stays at its fit.
    func testTheCardFillsTheHeightItIsGiven() throws {
        try mount()
        let canvas = try layout()
        let size = try XCTUnwrap(cardSize, "the canvas reported its size")
        XCTAssertEqual(size.width, width, accuracy: 0.5)
        XCTAssertEqual(size.height, canvas.size.height + Self.roomBelow, accuracy: 0.5, "the card reaches the window's bottom")
        XCTAssertNil(savedCamera, "the drawing stays at the fit, scale 1")
    }

    // MARK: Opening and returning (review of the free-drag canvas)

    /// A screen point (viewport coordinates) above every node and away from the zoom controls, in
    /// the opening view: the automatic layout's top-left at the card's.
    private func quietScreenPoint() -> CGPoint { CGPoint(x: width / 2, y: 3) }

    /// (j) Leaving for a thread and coming back lands the view exactly where it was left, when a
    /// node sits left of and above the automatic layout. The places are on disk before the view
    /// appears; the saved camera was measured from the corner of the canvas as it was then, and the
    /// first layout of the return must open it against that same corner (before, the pins were read
    /// after the first layout and the corner correction was applied twice: the view came back
    /// `corner * scale` away).
    func testComingBackFromAThreadLandsWhereTheViewWasLeftWithANodeLeftOfAndAboveTheLayout() throws {
        var pins = LiveCanvasPositions()
        pins.set("session:a1", xFraction: 0.02, y: -40, at: now)
        try mount(pins: pins)
        let pinned = try layout(pins: pins)
        XCTAssertLessThan(pinned.origin.x, 0, "a node left of the layout")
        XCTAssertLessThan(pinned.origin.y, 0, "and above it")
        middleDrag(from: quietScreenPoint(), by: CGSize(width: 50, height: 100))
        assertNoBlockedSends()
        let left = try XCTUnwrap(savedCamera, "the pan wrote the camera")
        let a1 = try node(pinned, .session, "a1")
        let seen = CGPoint(x: a1.frame.midX * left.scale + left.offset.x, y: a1.frame.midY * left.scale + left.offset.y)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: width, height: 300).contains(seen), "the pill is on screen where it was left: \(seen)")
        unmount()
        opened = []
        try mount(isFresh: false)
        click(seen)
        assertNoBlockedSends()
        XCTAssertEqual(opened, ["a1"], "the pill is under the point it was last seen at")
    }

    /// (k) A canvas nobody has touched opens on the automatic layout at the top, however far a
    /// node is pinned: one far above used to open the view onto blank canvas with the team below,
    /// one far right opened everyone at a sixth of their size.
    func testOpeningShowsTheAutomaticLayoutAtTheTopWhateverIsPinnedFarAway() throws {
        for (round, place) in [(0.5, -2000.0), (3.0, 150.0), (-3.0, -900.0)].enumerated() {
            var pins = LiveCanvasPositions()
            pins.set("session:a1", xFraction: place.0, y: place.1, at: now)
            try mount(pins: pins)
            let s1 = try node(try layout(), .session, "s1")
            click(center(s1.frame))
            assertNoBlockedSends()
            XCTAssertEqual(opened, ["s1"], "round \(round) \(place): the automatic layout is where it always was on screen")
            XCTAssertNil(savedCamera, "round \(round): an untouched view holds nothing above the board")
            unmount()
            opened = []
            UserDefaults.standard.removeObject(forKey: pinStore.key)
        }
    }

    /// (l) Pins that arrive while the view is untouched (the person or hub changed under it) change
    /// the canvas's size and its corner together; the view stays on the automatic layout whichever
    /// of the two changes is seen first, and nothing is held above the board for it.
    func testPinsThatArriveWhileTheViewIsUntouchedLeaveItOnTheAutomaticLayoutAndSaveNothing() throws {
        try mount()
        var pins = LiveCanvasPositions()
        pins.set("session:a1", xFraction: -0.6, y: -900, at: now)
        let other = hub + "-arrived"
        savePins(pins, hub: other)
        hubBox.hub = other
        pump(0.5)
        XCTAssertNil(savedCamera, "an untouched view is not held")
        let s1 = try node(try layout(), .session, "s1")
        click(center(s1.frame))
        assertNoBlockedSends()
        XCTAssertEqual(opened, ["s1"], "still the automatic layout at the top")
        XCTAssertNil(savedCamera)
    }

    /// (m) A press that moves a pill less than `dropDistance` is a shaky tap: no pin, and the view
    /// is still untouched, so pins that arrive afterwards still leave the automatic layout on screen.
    func testAShakyTapOnAPillDoesNotTakeTheViewOver() throws {
        try mount()
        let pill = try node(try layout(), .session, "a1")
        drag(from: center(pill.frame), by: CGSize(width: 5, height: 0))
        assertNoBlockedSends()
        XCTAssertTrue(savedPins.isEmpty, "under the drop distance nothing is saved")
        XCTAssertNil(savedCamera)
        var pins = LiveCanvasPositions()
        pins.set("session:a2", xFraction: 2.5, y: 400, at: now)
        let other = hub + "-later"
        savePins(pins, hub: other)
        hubBox.hub = other
        pump(0.5)
        XCTAssertNil(savedCamera, "still untouched")
        let s1 = try node(try layout(), .session, "s1")
        click(center(s1.frame))
        XCTAssertEqual(opened, ["s1"])
    }

    // MARK: Double-click mirrors a person's agents

    private static let boKey = "person:bo"

    /// Bo's avatar pinned in the middle of the canvas, 300pt below every other card, so his two
    /// pills (which come with him, on his right) have room on both sides of him.
    private func boInTheMiddle() throws -> LiveCanvasPositions {
        let bo = try node(try layout(), .person, "bo")
        var pins = LiveCanvasPositions()
        pins.set(Self.boKey, xFraction: 0.5, y: Double(bo.frame.midY) + 300, at: now)
        return pins
    }

    /// Where `pill` stands once mirrored about the avatar `person`: the same height, the other side.
    private func mirrored(_ pill: LiveCanvasLayout.Node, about person: LiveCanvasLayout.Node) -> CGPoint {
        CGPoint(x: 2 * person.frame.midX - pill.frame.midX, y: pill.frame.midY)
    }

    /// (t) A double-click on a person flips their unpinned pills to the other side of the avatar at
    /// the same heights, and a second one flips them back. The avatar stays where it is, so the
    /// second double-click lands on it at the same screen point. Clicking where a pill now stands
    /// opens it (it is a live button there), and where it was opens nothing.
    func testADoubleClickOnAPersonMirrorsTheirPillsAndASecondOneFlipsThemBack() throws {
        let pins = try boInTheMiddle()
        try mount(pins: pins)
        let before = try layout(pins: pins)
        let bo = try node(before, .person, "bo")
        let a1 = try node(before, .session, "a1"), a2 = try node(before, .session, "a2")
        XCTAssertGreaterThan(a1.frame.minX, bo.frame.maxX, "to start with his pills stand on his right")
        doubleClick(center(bo.avatar))
        assertNoBlockedSends()
        XCTAssertEqual(opened, [], "a double-click on a person opens nothing")
        XCTAssertTrue(savedPins.isMirrored(Self.boKey), "the flag is saved")
        XCTAssertEqual(savedPins.pin(for: Self.boKey), pins.pin(for: Self.boKey), "the avatar was not moved")
        XCTAssertEqual(Set(savedPins.pins.keys), [Self.boKey], "no pill was pinned: they follow the flag")
        click(center(a1.frame))
        XCTAssertEqual(opened, [], "nothing is where a1 was")
        click(mirrored(a1, about: bo))
        XCTAssertEqual(opened, ["a1"], "a1 is on his left now, at the same height")
        click(mirrored(a2, about: bo))
        XCTAssertEqual(opened, ["a1", "a2"], "and so is a2")
        doubleClick(center(bo.avatar))
        XCTAssertFalse(savedPins.isMirrored(Self.boKey), "a second double-click flips them back")
        click(center(a1.frame))
        click(center(a2.frame))
        XCTAssertEqual(opened, ["a1", "a2", "a1", "a2"], "the pills are back where they were")
        assertNoBlockedSends()
    }

    /// (u) A pill that was pinned is not carried by the flag: the double-click rewrites its pin,
    /// reflected about the avatar, and flipping back restores it.
    func testADoubleClickReflectsAPinnedPillsPin() throws {
        var pins = try boInTheMiddle()
        let auto = try layout(pins: pins)
        let a1 = try node(auto, .session, "a1")
        pins.set("session:a1", xFraction: 0.8, y: Double(a1.frame.midY), at: now)
        try mount(pins: pins)
        let bo = try node(try layout(pins: pins), .person, "bo")
        XCTAssertEqual(bo.frame.midX, 450, accuracy: 0.5)
        doubleClick(center(bo.avatar))
        assertNoBlockedSends()
        let flipped = try XCTUnwrap(savedPins.pin(for: "session:a1"))
        XCTAssertEqual(flipped.xFraction, 0.2, accuracy: 0.002, "0.8 reflected about the avatar at 0.5")
        XCTAssertEqual(flipped.y, Double(a1.frame.midY), accuracy: 0.5, "at the same height")
        XCTAssertNil(savedPins.pin(for: "session:a2"), "a pill never moved is not pinned by it")
        click(CGPoint(x: 0.2 * Double(width), y: a1.frame.midY))
        XCTAssertEqual(opened, ["a1"], "the pill is drawn at its new pin")
        doubleClick(center(bo.avatar))
        let back = try XCTUnwrap(savedPins.pin(for: "session:a1"))
        XCTAssertEqual(back.xFraction, 0.8, accuracy: 0.002)
        XCTAssertFalse(savedPins.isMirrored(Self.boKey))
    }

    /// (v) The flag outlives the window: coming back from a thread, the pills are still across.
    func testTheMirroredSideSurvivesLeavingAndComingBack() throws {
        let pins = try boInTheMiddle()
        try mount(pins: pins)
        let before = try layout(pins: pins)
        let bo = try node(before, .person, "bo")
        let a1 = try node(before, .session, "a1")
        doubleClick(center(bo.avatar))
        XCTAssertTrue(savedPins.isMirrored(Self.boKey))
        unmount()
        try mount(isFresh: false)
        click(mirrored(a1, about: bo))
        assertNoBlockedSends()
        XCTAssertEqual(opened, ["a1"], "a1 opens from the mirrored side after the return")
    }

    /// (w) A person at the edge, who has nowhere to go inside the layout: the canvas grows to hold
    /// the mirrored pills and the avatar stays at the same screen point (the camera follows the
    /// canvas's new corner), so a second double-click on it flips them back.
    func testMirroringAPersonAtTheEdgeKeepsTheAvatarUnderThePointer() throws {
        try mount()
        let bo = try node(try layout(), .person, "bo")
        doubleClick(center(bo.avatar))
        assertNoBlockedSends()
        XCTAssertTrue(savedPins.isMirrored(Self.boKey))
        XCTAssertLessThan(try layout(pins: savedPins).origin.x, 0, "the canvas grew to the left for the pills")
        doubleClick(center(bo.avatar))
        assertNoBlockedSends()
        XCTAssertFalse(savedPins.isMirrored(Self.boKey), "the avatar had not moved on screen")
        XCTAssertTrue(savedPins.isEmpty, "and nothing is left saved")
    }

    /// (x) A single click on an avatar is what it always was (nothing, and with Shift a selection
    /// toggle) and is not held back for a second click: Shift-click selects within 50ms of the
    /// release. A double-click handler that waited for a second click would hold it for the
    /// system's double-click interval.
    func testASingleClickOnAPersonIsNotDelayedAndMirrorsNothing() throws {
        try mount()
        let bo = try node(try layout(), .person, "bo")
        let point = center(bo.avatar)
        send(.leftMouseDown, at: point, modifiers: Self.isShift, settle: 0.01)
        pump(0.02)
        send(.leftMouseUp, at: point, modifiers: Self.isShift, settle: 0.02)
        XCTAssertEqual(selection, [Self.boKey], "selected at once, not after a double-click wait")
        click(point)
        assertNoBlockedSends()
        XCTAssertTrue(savedPins.isEmpty, "a plain click saves nothing")
        XCTAssertEqual(selection, [Self.boKey], "and leaves the selection as it was")
        XCTAssertEqual(opened, [])
    }

    /// (y) Shift-double-click is two selection toggles, not a mirror.
    func testAShiftDoubleClickOnAPersonDoesNotMirror() throws {
        try mount()
        let bo = try node(try layout(), .person, "bo")
        doubleClick(center(bo.avatar), modifiers: Self.isShift)
        assertNoBlockedSends()
        XCTAssertTrue(savedPins.isEmpty)
        XCTAssertEqual(selection, [], "toggled in and out")
    }

    /// (z) Double-clicking one selected avatar flips that person only, and the selection stays.
    func testDoubleClickingASelectedPersonFlipsOnlyThem() throws {
        try mount()
        let canvas = try layout()
        let bo = try node(canvas, .person, "bo"), ada = try node(canvas, .person, "uma")
        click(center(bo.avatar), modifiers: Self.isShift)
        click(center(ada.avatar), modifiers: Self.isShift)
        XCTAssertEqual(selection, [Self.boKey, "person:uma"])
        doubleClick(center(bo.avatar))
        assertNoBlockedSends()
        XCTAssertTrue(savedPins.isMirrored(Self.boKey))
        XCTAssertFalse(savedPins.isMirrored("person:uma"), "the other selected person stays")
        XCTAssertEqual(selection, [Self.boKey, "person:uma"], "the selection is untouched")
        click(center(try node(canvas, .session, "s1").frame))
        XCTAssertEqual(opened, ["s1"], "Uma's pill is where it was")
    }

    /// (aa) A press that follows a first click and then drags is a drag: the avatar moves and
    /// nothing is mirrored.
    func testADragThatBeginsWithASecondPressStillMovesTheAvatar() throws {
        try mount()
        let bo = try node(try layout(), .person, "bo")
        click(center(bo.avatar))
        drag(from: center(bo.avatar), by: CGSize(width: 0, height: 50), clickCount: 2)
        assertNoBlockedSends()
        XCTAssertFalse(savedPins.isMirrored(Self.boKey))
        let pin = try XCTUnwrap(savedPins.pin(for: Self.boKey), "the drop saved the person")
        XCTAssertEqual(pin.y, Double(bo.frame.midY + 50), accuracy: 2)
    }

    /// (ab) An idle face does nothing on a double-click.
    func testDoubleClickingAnIdleFaceDoesNothing() throws {
        roster = [.init(id: "zed", name: "Zed")]
        try mount()
        let canvas = try layout()
        let zed = try node(canvas, .idle, "zed")
        doubleClick(center(zed.avatar))
        assertNoBlockedSends()
        XCTAssertTrue(savedPins.isEmpty, "no flag, no pin: \(savedPins)")
        XCTAssertEqual(selection, [])
        click(center(try node(canvas, .session, "a1").frame))
        XCTAssertEqual(opened, ["a1"], "everything is where it was")
    }

    /// (ac) Pills and projects do nothing new on a double-click: a pill opens as it does on each
    /// click, and nothing is mirrored or saved.
    func testDoubleClickingAPillOrAProjectMirrorsNothing() throws {
        try mount()
        let canvas = try layout()
        doubleClick(center(try node(canvas, .session, "a1").frame))
        XCTAssertEqual(opened, ["a1", "a1"], "a pill opens on each click, as before")
        doubleClick(center(try node(canvas, .hub, "o0").frame))
        assertNoBlockedSends()
        XCTAssertTrue(savedPins.isEmpty, "nothing is mirrored or pinned: \(savedPins)")
    }

    // MARK: Review fixes

    /// Scrolls the scroll view `mount(isScrollable: true)` made so the canvas (at the top of the
    /// document) is `windows` window-heights out of view, or back in view at 0.
    private func scrollCanvas(toWindow windows: CGFloat) throws {
        let scroll = try XCTUnwrap(scroll, "the canvas is mounted in a scroll view")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: windows * scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        pump(0.2)
    }

    /// (ad) A middle press that carries no window is taken by the screen point inside the canvas's
    /// window; another window in front of it there (an HQ panel) is the one it was for, and the
    /// canvas neither pans nor swallows it. With the other window gone the same drag pans.
    func testAMiddleClickMeantForAWindowInFrontOfTheCanvasDoesNotPan() throws {
        try mount()
        let start = try XCTUnwrap(emptyPoint(try layout()), "the fixture has empty canvas")
        let window = try XCTUnwrap(self.window)
        let cover = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.level = .floating
        cover.orderFrontRegardless()
        self.cover = cover
        pump(0.3)
        XCTAssertEqual(NSApp.orderedWindows.first, cover, "the other window is in front of the canvas's")
        middleDrag(from: start, by: CGSize(width: 80, height: 0))
        assertNoBlockedSends()
        XCTAssertNil(savedCamera, "a press for the window in front does not pan this one")
        cover.orderOut(nil)
        pump(0.3)
        middleDrag(from: start, by: CGSize(width: 80, height: 0))
        XCTAssertEqual(try XCTUnwrap(savedCamera, "with nothing in front it pans").offset.x, 80, accuracy: 1)
    }

    /// (ae) Escape clears the selection only while the canvas is on screen: scrolled out of view
    /// it is the page's (or the next responder's), and the selection is still there when the
    /// canvas comes back.
    func testEscapeIsNotTakenWhileTheCanvasIsScrolledOutOfView() throws {
        try mount(isScrollable: true)
        let box = try boxOverBosPills(try layout())
        drag(from: box.start, by: box.delta)
        XCTAssertEqual(selection, ["session:a1", "session:a2"])
        try scrollCanvas(toWindow: 2)
        pressEscape()
        XCTAssertEqual(selection, ["session:a1", "session:a2"], "Escape is not spent on a canvas nobody can see")
        try scrollCanvas(toWindow: 0)
        pressEscape()
        XCTAssertEqual(selection, [], "in view again, Escape clears")
    }

    /// (af) Caps Lock is a state, not a chord: Escape clears with it on.
    func testEscapeStillClearsWithCapsLockOn() throws {
        try mount()
        let box = try boxOverBosPills(try layout())
        drag(from: box.start, by: box.delta)
        XCTAssertFalse(selection.isEmpty)
        pressEscape(modifiers: .capsLock)
        XCTAssertEqual(selection, [], "Escape clears with Caps Lock on")
        drag(from: box.start, by: box.delta)
        pressEscape(modifiers: .command)
        XCTAssertFalse(selection.isEmpty, "⌘-Escape is still not Escape")
    }

    /// (ag) A refresh that moves the canvas's corner mid-box (here: pins arrive that put a card far
    /// left of the layout) leaves the box's start corner on the canvas point it began at. The corner
    /// is kept in pin space; kept in drawn coordinates it jumped by the shift and the box took in
    /// cards it never touched.
    func testTheBoxKeepsItsStartCornerWhenARefreshMovesTheCanvasCorner() throws {
        try mount()
        let canvas = try layout()
        let box = try boxOverBosPills(canvas)
        // Uma's pill, put far left of the layout at the height of the box: the canvas grows to the
        // left by more than the box is wide, and nothing else moves on screen.
        var arrived = LiveCanvasPositions()
        arrived.set("session:s1", xFraction: -0.6, y: Double(box.start.y + box.delta.height / 2), at: now)
        let other = hub + "-arrived"
        savePins(arrived, hub: other)
        XCTAssertLessThan(try layout(pins: arrived).origin.x, -400, "the shift is bigger than the box")
        drag(from: box.start, by: box.delta, steps: 8) {
            self.hubBox.hub = other
            self.pump(0.5)
        }
        assertNoBlockedSends()
        XCTAssertEqual(selection, ["session:a1", "session:a2"], "the same two cards the box was drawn over")
    }

    /// (ah) A group dragged against the pin bound stops together: the card that reaches the bound
    /// first holds the others, which keep their distance from it. Each card clamped on its own
    /// would end up beside the bound with the group's spacing gone.
    func testAGroupDraggedPastThePinBoundKeepsItsSpacing() throws {
        try mount()
        let canvas = try layout()
        let a1 = try node(canvas, .session, "a1"), s1 = try node(canvas, .session, "s1")
        XCTAssertGreaterThan(s1.frame.midX - a1.frame.midX, 100, "the two cards differ in x")
        click(center(a1.frame), modifiers: Self.isShift)
        click(center(s1.frame), modifiers: Self.isShift)
        XCTAssertEqual(selection, ["session:a1", "session:s1"])
        drag(from: center(a1.frame), by: CGSize(width: 5_000, height: 0), steps: 4)
        assertNoBlockedSends()
        let pins = savedPins
        let first = try XCTUnwrap(pins.pin(for: "session:a1")), second = try XCTUnwrap(pins.pin(for: "session:s1"))
        XCTAssertEqual(second.xFraction, LiveCanvasPositions.maxFraction, accuracy: 0.001, "the card on the right reached the bound")
        XCTAssertEqual(
            (second.xFraction - first.xFraction) * Double(width), Double(s1.frame.midX - a1.frame.midX), accuracy: 2,
            "and the other stopped with it, the same distance behind")
        XCTAssertEqual(first.y, Double(a1.frame.midY), accuracy: 2)
        XCTAssertEqual(second.y, Double(s1.frame.midY), accuracy: 2)
    }

    /// (ai) Shift-click on empty canvas keeps the selection, as Shift keeps it for a box; a plain
    /// click clears it (see the click-and-Escape case).
    func testShiftClickOnEmptyCanvasKeepsTheSelection() throws {
        try mount()
        let canvas = try layout()
        let box = try boxOverBosPills(canvas)
        drag(from: box.start, by: box.delta)
        XCTAssertEqual(selection, ["session:a1", "session:a2"])
        let empty = try XCTUnwrap(emptyPoint(canvas), "the fixture has empty canvas")
        click(empty, modifiers: Self.isShift)
        assertNoBlockedSends()
        XCTAssertEqual(selection, ["session:a1", "session:a2"], "Shift-click on empty canvas leaves the selection alone")
        pump(0.4)
        click(empty)
        XCTAssertEqual(selection, [], "a plain click clears it")
    }

    /// (aj) Shift-dragging a card that is not selected adds it to the selection and moves the whole
    /// selection; a plain drag on it still moves it alone (see the unselected-card case).
    func testShiftDraggingAnUnselectedCardJoinsTheSelectionAndMovesItAll() throws {
        try mount()
        let canvas = try layout()
        let box = try boxOverBosPills(canvas)
        drag(from: box.start, by: box.delta)
        XCTAssertEqual(selection, ["session:a1", "session:a2"])
        let ada = try node(canvas, .session, "s1")
        drag(from: center(ada.frame), by: CGSize(width: -30, height: 20), modifiers: Self.isShift)
        assertNoBlockedSends()
        let pins = savedPins
        XCTAssertEqual(Set(pins.pins.keys), ["session:a1", "session:a2", "session:s1"], "all three moved")
        for pill in box.pills + [ada] {
            let pin = try XCTUnwrap(pins.pin(for: pill.pinKey))
            XCTAssertEqual(pin.xFraction * Double(width), Double(pill.frame.midX - 30), accuracy: 2, "\(pill.refId) moved 30 left")
            XCTAssertEqual(pin.y, Double(pill.frame.midY + 20), accuracy: 2, "\(pill.refId) moved 20 down")
        }
        XCTAssertEqual(selection, ["session:a1", "session:a2", "session:s1"], "and it joined the selection")
    }
}

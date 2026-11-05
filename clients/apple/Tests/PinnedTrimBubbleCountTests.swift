import AppKit
import SwiftUI
import XCTest
@testable import HQ

/// What the pinned trim saves, counted on the real transcript:
/// every loaded row is a `BubbleTextView` with its own text stack, so three
/// scroll-backs left 150 more of them alive for as long as the chat stayed
/// open. Hosted, on the chat fixture, in an offscreen window.
@MainActor
final class PinnedTrimBubbleCountTests: XCTestCase {
    private var previousScenario: String?

    override func setUp() async throws {
        previousScenario = ProcessInfo.processInfo.environment["HQ_UI_SCENARIO"]
        setenv("HQ_UI_SCENARIO", "chat", 1)
        HQFixtureProtocol.contentMode = "ready"
    }

    override func tearDown() async throws {
        HQFixtureProtocol.contentMode = "ready"
        if let previousScenario {
            setenv("HQ_UI_SCENARIO", previousScenario, 1)
        } else {
            unsetenv("HQ_UI_SCENARIO")
        }
    }

    private func message(_ id: String) -> Message {
        Message(
            id: id, conversationId: "studio", senderPersonId: "bo", senderName: "bo",
            content: "row \(id)", createdAt: "2026-10-29T12:00:00Z"
        )
    }

    private func bubbleViews(in view: NSView) -> Int {
        (view is BubbleTextView ? 1 : 0) + view.subviews.reduce(0) { $0 + bubbleViews(in: $1) }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<10 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testThreeScrollBacksThenANewMessageLeaveTheWindowAlive() async throws {
        precondition(HQSimulatorFixture.isEnabled)
        let store = AppStore()
        store.start()
        store.openConversation("studio")
        await store.loadMessages("studio")
        HQFixtureProtocol.contentMode = "error"
        for index in 0..<80 { store.handle(.message(message(String(format: "zz-%04d", index)))) }

        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: 0, width: 700, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ChatView(conversationId: "studio").environment(store))
        window.orderFrontRegardless()
        defer { window.close() }
        try await settle(window)
        let opened = bubbleViews(in: window.contentView!)

        // Three pages of history, as three scroll-backs load them: older
        // rows, so the newest message does not change.
        for page in 0..<3 {
            for index in 0..<50 { store.handle(.message(message(String(format: "zm-%d-%04d", page, index)))) }
            try await settle(window)
        }
        let scrolledBack = bubbleViews(in: window.contentView!)

        store.handle(.message(message("zz-9999")))
        try await settle(window)
        let afterNewMessage = bubbleViews(in: window.contentView!)

        print("BubbleTextView count: opened \(opened), after three pages \(scrolledBack), after a new message \(afterNewMessage); rows \(store.messages(in: "studio").count)")
        XCTAssertGreaterThan(scrolledBack, opened + 100)
        XCTAssertLessThanOrEqual(afterNewMessage, StateCache.messagesKept + 1)
    }
}

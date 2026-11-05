import XCTest
@testable import HQ

/// The unread count a live message adds matches the hub's: the hub counts plain rows only (`kind IS NULL`), so an agent's work
/// row, which is not `isSystem`, must not add one either.
final class UnreadParityTests: XCTestCase {
    private func message(_ id: String, kind: String? = nil) -> Message {
        Message(
            id: id, conversationId: "a", senderPersonId: "scout", senderName: "Scout",
            content: "working", createdAt: "2026-10-14T12:00:00Z", kind: kind
        )
    }

    func testAgentWorkRowsAddNothing() {
        let unread = AppStore.unreadAfter(
            existing: 1, messages: [message("m1", kind: "work"), message("m2", kind: "agent_job")],
            meId: "me", isBeingRead: false, arrival: .live
        )
        XCTAssertEqual(unread, 1)
    }

    func testAPlainRowStillAddsOne() {
        let unread = AppStore.unreadAfter(
            existing: 1, messages: [message("m1", kind: "work"), message("m2")],
            meId: "me", isBeingRead: false, arrival: .live
        )
        XCTAssertEqual(unread, 2)
    }
}

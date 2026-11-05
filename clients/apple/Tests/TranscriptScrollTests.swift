import XCTest

@testable import HQ

final class TranscriptScrollTests: XCTestCase {
    func testRemovedMessagesAreHiddenAndTheRestKeepTheirOrder() {
        let removed = Message(
            id: "old", conversationId: "studio", senderPersonId: "scout", senderName: "Scout",
            content: "", createdAt: "2026-10-05T12:00:00Z", deletedAt: "2026-10-05T13:00:00Z", isHidden: true
        )
        let ordinary = Message(id: "human", conversationId: "studio", senderPersonId: "bo", senderName: "Bo",
                               content: "", createdAt: "2026-10-05T12:30:00Z", deletedAt: "2026-10-05T13:00:00Z")
        let later = Message(id: "later", conversationId: "studio", senderPersonId: "ada", senderName: "Ada",
                            content: "Hello", createdAt: "2026-10-05T13:00:00Z")
        XCTAssertEqual(TranscriptLayout.orderedMessages([removed, ordinary, later]), [ordinary, later])
    }

    func testHistoryDoesNotLoadFromGeometryWithoutAUserGesture() {
        var trigger = TranscriptHistoryTrigger()

        XCTAssertFalse(trigger.shouldLoad(at: 0))
    }

    func testHistoryLoadsOnceDuringOneUserGesture() {
        var trigger = TranscriptHistoryTrigger()

        trigger.phaseChanged(from: .idle, to: .interacting)
        XCTAssertTrue(trigger.shouldLoad(at: 299))
        XCTAssertFalse(trigger.shouldLoad(at: 120))
        XCTAssertFalse(trigger.shouldLoad(at: 0))
    }

    func testASecondUserGestureCanLoadTheNextPage() {
        var trigger = TranscriptHistoryTrigger()

        trigger.phaseChanged(from: .idle, to: .tracking)
        XCTAssertTrue(trigger.shouldLoad(at: 0))
        trigger.phaseChanged(from: .interacting, to: .idle)
        trigger.phaseChanged(from: .idle, to: .tracking)
        XCTAssertTrue(trigger.shouldLoad(at: 0))
    }

    func testProgrammaticScrollAnimationDoesNotArmHistoryPaging() {
        var trigger = TranscriptHistoryTrigger()

        trigger.phaseChanged(from: .idle, to: .animating)
        XCTAssertFalse(trigger.shouldLoad(at: 0))
    }

    func testPhoneHistoryPrefetchesAsSoonAsItIsNearTheTop() {
        var trigger = TranscriptProximityHistoryTrigger()

        XCTAssertTrue(trigger.shouldLoad(at: 599))
        XCTAssertFalse(trigger.shouldLoad(at: 200))
        XCTAssertFalse(trigger.shouldLoad(at: 0))
    }

    func testPhoneHistoryPrefetchRearmsOnlyAfterLeavingTheNearTopZone() {
        var trigger = TranscriptProximityHistoryTrigger()

        XCTAssertTrue(trigger.shouldLoad(at: 300))
        XCTAssertFalse(trigger.shouldLoad(at: 700))
        XCTAssertFalse(trigger.shouldLoad(at: 801))
        XCTAssertTrue(trigger.shouldLoad(at: 599))
    }

    func testPrependMovesViewportByInsertedContentHeight() {
        let snapshot = TranscriptViewportPreserver.Snapshot(
            originY: -84,
            contentHeight: 19_268
        )

        XCTAssertEqual(snapshot.preservedOrigin(for: 22_581), 3_229)
    }
}

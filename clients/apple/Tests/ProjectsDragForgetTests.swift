import XCTest

@testable import HQ

/// A board drag (or Move To) writes outside the queue, so it drops the card's
/// held answer: a status queued after it starts from the drag, not from the
/// answer an earlier write in the burst got back.
@MainActor
final class ProjectsDragForgetTests: XCTestCase {
    func testAStatusQueuedAfterADragOfTheSameCardSeesTheDrag() async {
        let queue = ProjectsWriteQueue()
        let shown = ProjectsFakeHub.card()
        let hub = ProjectsFakeHub(shown)
        var stored = [shown]
        func move(_ status: String) {
            queue.enqueue({
                try await ProjectsTaskWrite.status(
                    of: shown, to: status, latest: { queue.latest($0, in: stored) },
                    send: { try await hub.status($0) },
                    apply: { queue.hold($0); stored = [$0] })
            }, onFailure: { XCTFail("\($0)") }, refresh: {})
        }
        move("done")
        // The card is dragged back to Open mid-burst, outside the queue.
        queue.enqueue({
            queue.forget(TeamTask.self, id: "t")
            stored = [try await hub.status("open")]
        }, onFailure: { XCTFail("\($0)") }, refresh: {})
        move("done")
        await queue.idle()
        XCTAssertEqual(hub.sent, ["done", "open", "done"])
        XCTAssertEqual(hub.task.status, "done")
    }

    func testForgetDropsOnlyThatRow() async {
        let queue = ProjectsWriteQueue()
        let other = TeamTask(
            id: "u", title: "Other", status: "open", ownerPersonId: "me", ownerName: "Me", createdByPersonId: "me",
            createdAt: "2026-10-01T12:00:00Z", projectId: "p", projectIds: [])
        queue.enqueue({
            queue.hold(ProjectsFakeHub.card(status: "done"))
            queue.hold(other)
            queue.forget(TeamTask.self, id: "t")
            XCTAssertNil(queue.held(TeamTask.self, id: "t"))
            XCTAssertEqual(queue.held(TeamTask.self, id: "u"), other)
        }, onFailure: { _ in }, refresh: {})
        await queue.idle()
    }
}

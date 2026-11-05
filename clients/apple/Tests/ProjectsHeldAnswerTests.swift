import XCTest

@testable import HQ

/// While a burst runs, a queued write starts from the answer the write before
/// it got back, even when the store's copy is put back to an older one (a
/// refresh read before that write landed, a failed drag's snapshot, a late
/// `tasks` frame). The answers go when the queue goes idle.
@MainActor
final class ProjectsHeldAnswerTests: XCTestCase {
    func testAStaleStoreCopyMidBurstDoesNotUndoTheWriteBefore() async {
        let queue = ProjectsWriteQueue()
        let shown = ProjectsFakeHub.card(projectIds: ["x", "y"])
        let hub = ProjectsFakeHub(shown)
        var stored = [shown]
        func unlink(_ id: String) {
            queue.enqueue({
                try await ProjectsTaskWrite.links(
                    of: shown, { $0.filter { $0 != id } }, latest: { queue.latest($0, in: stored) },
                    send: { try await hub.links($0) },
                    apply: { queue.hold($0); stored = [$0] })
            }, onFailure: { XCTFail("\($0)") }, refresh: {})
        }
        unlink("x")
        // A refresh read on the hub before the unlink landed puts the card back.
        queue.enqueue({ stored = [shown] }, onFailure: { _ in }, refresh: {})
        unlink("y")
        await queue.idle()
        XCTAssertEqual(hub.sent, ["p,y", "p"])
        XCTAssertEqual(hub.task.associatedProjectIds, ["p"])
    }

    func testAStatusQueuedAfterAStaleCopyStillStartsFromDone() async {
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
        queue.enqueue({ stored = [shown] }, onFailure: { _ in }, refresh: {})
        move("in_progress")
        await queue.idle()
        XCTAssertEqual(hub.sent, ["done", "open", "in_progress"])
        XCTAssertEqual(hub.task.status, "in_progress")
    }

    func testTheHeldAnswersGoOnceTheQueueIsIdleAndHasRefreshed() async {
        let queue = ProjectsWriteQueue()
        let answer = ProjectsFakeHub.card(projectIds: ["x"])
        var heldDuringRefresh: TeamTask?
        queue.enqueue({ queue.hold(answer) }, onFailure: { _ in }, refresh: {
            heldDuringRefresh = queue.held(TeamTask.self, id: "t")
        })
        await queue.idle()
        XCTAssertEqual(heldDuringRefresh, answer, "kept until the refresh has read the hub")
        XCTAssertNil(queue.held(TeamTask.self, id: "t"))
        let stored = ProjectsFakeHub.card()
        XCTAssertEqual(queue.latest("t", in: [stored]), stored, "the store's copy is current again")
    }

    func testAnswersAreKeptPerKind() async {
        let queue = ProjectsWriteQueue()
        let board = Project(
            id: "t", name: "Board", body: nil, ownerPersonId: "me", ownerName: "Me", status: "active",
            openTasks: 0, createdAt: "2026-10-01T12:00:00Z", closedAt: nil, tags: ["Eng"])
        queue.enqueue({
            queue.hold(board)
            queue.hold(ProjectsFakeHub.card())
            XCTAssertEqual(queue.held(Project.self, id: "t"), board)
            XCTAssertEqual(queue.held(TeamTask.self, id: "t"), ProjectsFakeHub.card())
        }, onFailure: { _ in }, refresh: {})
        await queue.idle()
    }
}

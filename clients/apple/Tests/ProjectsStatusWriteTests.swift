import XCTest

@testable import HQ

/// A status change works out its writes when it runs, from the card as the
/// store holds it then: one queued behind a Done still lands.
@MainActor
final class ProjectsStatusWriteTests: XCTestCase {
    private func burst(from shown: TeamTask, _ statuses: [String]) async -> (ProjectsFakeHub, TeamTask) {
        let queue = ProjectsWriteQueue()
        let hub = ProjectsFakeHub(shown)
        var held = shown
        for status in statuses {
            queue.enqueue({
                try await ProjectsTaskWrite.status(
                    of: shown, to: status, latest: { _ in held }, send: { try await hub.status($0) }, apply: { held = $0 })
            }, onFailure: { XCTFail("\($0)") }, refresh: {})
        }
        await queue.idle()
        return (hub, held)
    }

    func testInProgressQueuedBehindDoneReopensFirst() async {
        let (hub, held) = await burst(from: ProjectsFakeHub.card(), ["done", "in_progress"])
        XCTAssertEqual(hub.sent, ["done", "open", "in_progress"])
        XCTAssertEqual(hub.task.status, "in_progress")
        XCTAssertEqual(held.status, "in_progress")
    }

    func testOneStatusChangeSendsTheSameWritesAsBefore() async {
        let (open, _) = await burst(from: ProjectsFakeHub.card(), ["blocked"])
        XCTAssertEqual(open.sent, ["blocked"])
        let (done, _) = await burst(from: ProjectsFakeHub.card(status: "done"), ["in_progress"])
        XCTAssertEqual(done.sent, ["open", "in_progress"])
        let (same, _) = await burst(from: ProjectsFakeHub.card(status: "blocked"), ["blocked"])
        XCTAssertEqual(same.sent, [])
    }
}

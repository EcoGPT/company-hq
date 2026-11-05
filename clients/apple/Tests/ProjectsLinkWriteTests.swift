import XCTest

@testable import HQ

/// A card's board links are worked out when the write runs, from the card
/// as the store holds it then, so a burst of clicks builds on itself.
@MainActor
final class ProjectsLinkWriteTests: XCTestCase {
    private func burst(from shown: TeamTask, _ changes: [([String]) -> [String]]) async -> (ProjectsFakeHub, TeamTask) {
        let queue = ProjectsWriteQueue()
        let hub = ProjectsFakeHub(shown)
        var held = shown
        for change in changes {
            queue.enqueue({
                try await ProjectsTaskWrite.links(
                    of: shown, change, latest: { _ in held }, send: { try await hub.links($0) }, apply: { held = $0 })
            }, onFailure: { XCTFail("\($0)") }, refresh: {})
        }
        await queue.idle()
        return (hub, held)
    }

    func testTwoLinksClickedInABurstAreBothKept() async {
        let (hub, held) = await burst(from: ProjectsFakeHub.card(), [{ $0 + ["x"] }, { $0 + ["y"] }])
        XCTAssertEqual(Set(hub.task.associatedProjectIds), ["p", "x", "y"])
        XCTAssertEqual(Set(held.associatedProjectIds), ["p", "x", "y"])
    }

    func testTwoUnlinksClickedInABurstAreBothKept() async {
        let shown = ProjectsFakeHub.card(projectIds: ["x", "y"])
        let (hub, held) = await burst(from: shown, [{ $0.filter { $0 != "x" } }, { $0.filter { $0 != "y" } }])
        XCTAssertEqual(hub.task.associatedProjectIds, ["p"])
        XCTAssertEqual(held.associatedProjectIds, ["p"])
    }
}

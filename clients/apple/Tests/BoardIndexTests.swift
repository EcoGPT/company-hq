import XCTest

@testable import HQ

final class BoardIndexTests: XCTestCase {
    private func task(_ id: String, status: String = "open", touched: String? = nil) -> TeamTask {
        TeamTask(
            id: id, title: id, status: status, ownerPersonId: "me", ownerName: "Me", createdByPersonId: "me",
            createdAt: "2026-10-01T12:00:00Z", resolvedAt: status == "done" ? "2026-10-01T12:00:00Z" : nil,
            projectId: "p", touchedAt: touched)
    }

    func testPositionsOfAFiveCardList() {
        let cards = ["a", "b", "c", "d", "e"].map { task($0) }
        XCTAssertEqual(ProjectBoard.positions(of: cards), ["a": 0, "b": 1, "c": 2, "d": 3, "e": 4])
    }

    /// Matches the `firstIndex` it replaces: a repeated id keeps its first place.
    func testARepeatedIdKeepsItsFirstPlace() {
        let cards = [task("a"), task("b"), task("a")]
        XCTAssertEqual(ProjectBoard.positions(of: cards)["a"], 0)
        XCTAssertEqual(ProjectBoard.positions(of: cards)["b"], 1)
    }

    func testDoneIsNewestFirstAndWorkingListsKeepTheHubsOrder() {
        let held = [
            task("old", status: "done", touched: "2026-10-02T00:00:00Z"),
            task("x", status: "open"),
            task("new", status: "done", touched: "2026-10-09T00:00:00Z"),
            task("y", status: "in_progress"),
            task("mid", status: "done", touched: "2026-10-05T00:00:00Z"),
            task("z", status: "open"),
        ]
        XCTAssertEqual(ProjectBoard.cards(in: "done", from: held).map(\.id), ["new", "mid", "old"])
        XCTAssertEqual(ProjectBoard.cards(in: "open", from: held).map(\.id), ["x", "z"])
        XCTAssertEqual(ProjectBoard.cards(in: "in_progress", from: held).map(\.id), ["y"])
        XCTAssertEqual(ProjectBoard.cards(in: "blocked", from: held).map(\.id), [])
    }
}

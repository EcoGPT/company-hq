import XCTest

@testable import HQ

/// A board's category toggles are worked out when the write runs, from the
/// board as the store holds it then, so a burst of toggles builds on itself.
@MainActor
final class ProjectsCategoryWriteTests: XCTestCase {
    private static func board(tags: [String]?) -> Project {
        Project(
            id: "b", name: "Board", body: nil, ownerPersonId: "me", ownerName: "Me", status: "active",
            openTasks: 0, createdAt: "2026-10-01T12:00:00Z", closedAt: nil, tags: tags)
    }

    /// Each change queued behind the one before; the hub takes a beat and
    /// answers with the board as it now stands.
    private func burst(
        from shown: Project, _ changes: [(Project) -> [String]]
    ) async -> (Project, Project, [[String]]) {
        let queue = ProjectsWriteQueue()
        var hub = shown
        var held = shown
        var sent: [[String]] = []
        for change in changes {
            queue.enqueue({
                try await ProjectsProjectWrite.tags(
                    of: shown, change, latest: { _ in held },
                    send: { tags in
                        try await Task.sleep(for: .milliseconds(40))
                        sent.append(tags)
                        hub.tags = tags
                        return hub
                    },
                    apply: { held = $0 })
            }, onFailure: { XCTFail("\($0)") }, refresh: {})
        }
        await queue.idle()
        return (hub, held, sent)
    }

    func testTwoCategoriesTurnedOnInABurstAreBothKept() async {
        let (hub, held, _) = await burst(from: Self.board(tags: ["roadmap"]), [
            { ProjectCategory.tags($0, turning: .eng, on: true) },
            { ProjectCategory.tags($0, turning: .growth, on: true) },
        ])
        XCTAssertEqual(hub.tags, ["Eng", "Growth", "roadmap"])
        XCTAssertEqual(held.tags, ["Eng", "Growth", "roadmap"])
    }

    func testTwoCategoriesTurnedOffInABurstAreBothRemoved() async {
        let (hub, _, _) = await burst(from: Self.board(tags: ["Eng", "Ops", "roadmap"]), [
            { ProjectCategory.tags($0, turning: .eng, on: false) },
            { ProjectCategory.tags($0, turning: .ops, on: false) },
        ])
        XCTAssertEqual(hub.tags, ["roadmap"])
    }

    func testOneToggleSendsTheSameTagsAsBefore() async {
        let shown = Self.board(tags: ["Product", "x"])
        let (_, _, sent) = await burst(from: shown, [{ ProjectCategory.tags($0, turning: .ops, on: true) }])
        XCTAssertEqual(sent, [ProjectCategory.tags(shown, setting: [.eng, .ops])])
        XCTAssertEqual(sent, [["Eng", "Ops", "x"]])
    }
}

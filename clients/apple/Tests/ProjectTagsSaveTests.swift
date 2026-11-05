import XCTest

@testable import HQ

/// Edit Tags closes at Save; only the tag write waits its turn.
@MainActor
final class ProjectTagsSaveTests: XCTestCase {
    private static let board = Project(
        id: "b", name: "Board", body: nil, ownerPersonId: "me", ownerName: "Me", status: "active",
        openTasks: 0, createdAt: "2026-10-01T12:00:00Z", closedAt: nil, tags: ["old"])

    func testSaveBehindASlowWriteClosesTheSheetAtTheClick() async {
        let queue = ProjectsWriteQueue()
        var isOpen = true
        var sent: [[String]] = []
        var applied: Project?
        let run: ((@escaping (Void) async throws -> Void) -> Void) = { operation in
            queue.enqueue({ try await operation(()) }, onFailure: { XCTFail("\($0)") }, refresh: {})
        }
        run { _ in try await Task.sleep(for: .milliseconds(80)) }
        ProjectsProjectWrite.save(
            ["Eng", "roadmap"], close: { isOpen = false }, run: run,
            send: { _, tags in
                sent.append(tags)
                var answer = Self.board
                answer.tags = tags
                return answer
            },
            apply: { applied = $0 })
        XCTAssertFalse(isOpen, "the sheet closes at the click")
        XCTAssertEqual(sent, [], "the write still waits its turn")
        await queue.idle()
        XCTAssertEqual(sent, [["Eng", "roadmap"]])
        XCTAssertEqual(applied?.tags, ["Eng", "roadmap"])
    }

    func testARefusedSaveStillReportsAFailure() async {
        let queue = ProjectsWriteQueue()
        var failures = 0
        let run: ((@escaping (Void) async throws -> Void) -> Void) = { operation in
            queue.enqueue({ try await operation(()) }, onFailure: { _ in failures += 1 }, refresh: {})
        }
        ProjectsProjectWrite.save(
            ["x"], close: {}, run: run,
            send: { _, _ in throw APIError(status: 403, code: "forbidden") },
            apply: { _ in XCTFail("nothing to apply") })
        await queue.idle()
        XCTAssertEqual(failures, 1)
    }
}

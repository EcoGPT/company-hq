import XCTest

@testable import HQ

/// Delete Card closes its panel at the click; only the delete waits its turn,
/// and a card already gone counts as deleted.
@MainActor
final class ProjectsCardDeleteTests: XCTestCase {
    func testADeleteBehindASlowWriteDoesNotCloseTheNextPanel() async {
        let queue = ProjectsWriteQueue()
        var open: String? = "A"
        var deleted: [String] = []
        let run: ((@escaping (Void) async throws -> Void) -> Void) = { operation in
            queue.enqueue({ try await operation(()) }, onFailure: { XCTFail("\($0)") }, refresh: {})
        }
        run { _ in try await Task.sleep(for: .milliseconds(80)) }
        ProjectsTaskWrite.delete(close: { open = nil }, run: run, send: { _ in deleted.append("A") })
        XCTAssertNil(open, "the panel closes at the click")
        open = "B"
        await queue.idle()
        XCTAssertEqual(deleted, ["A"])
        XCTAssertEqual(open, "B")
    }

    func testDeletingACardAlreadyGoneIsNotAnError() async {
        let queue = ProjectsWriteQueue()
        var failures: [Error] = []
        let run: ((@escaping (Void) async throws -> Void) -> Void) = { operation in
            queue.enqueue({ try await operation(()) }, onFailure: { failures.append($0) }, refresh: {})
        }
        ProjectsTaskWrite.delete(close: {}, run: run, send: { _ in throw APIError(status: 404, code: "not_found") })
        await queue.idle()
        XCTAssertTrue(failures.isEmpty)
    }

    func testAnyOtherRefusedDeleteStillFails() async {
        let queue = ProjectsWriteQueue()
        var failures: [Error] = []
        let run: ((@escaping (Void) async throws -> Void) -> Void) = { operation in
            queue.enqueue({ try await operation(()) }, onFailure: { failures.append($0) }, refresh: {})
        }
        ProjectsTaskWrite.delete(close: {}, run: run, send: { _ in throw APIError(status: 403, code: "forbidden") })
        await queue.idle()
        XCTAssertEqual(failures.count, 1)
    }
}

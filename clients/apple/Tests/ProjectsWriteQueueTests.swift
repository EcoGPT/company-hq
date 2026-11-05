import XCTest

@testable import HQ

@MainActor
final class ProjectsWriteQueueTests: XCTestCase {
    private struct Refused: Error {}

    func testASecondWriteWhileTheFirstIsInFlightStillRuns() async {
        let queue = ProjectsWriteQueue()
        var ran: [String] = []
        queue.enqueue({
            try await Task.sleep(for: .milliseconds(100))
            ran.append("A")
        }, onFailure: { _ in }, refresh: {})
        queue.enqueue({ ran.append("B") }, onFailure: { _ in }, refresh: {})
        await queue.idle()
        XCTAssertEqual(ran, ["A", "B"])
    }

    func testWritesRunInOrderOneAtATime() async {
        let queue = ProjectsWriteQueue()
        var events: [String] = []
        for (name, delay) in [("A", 60), ("B", 10), ("C", 30)] {
            queue.enqueue({
                events.append("start \(name)")
                try await Task.sleep(for: .milliseconds(delay))
                events.append("end \(name)")
            }, onFailure: { _ in }, refresh: {})
        }
        await queue.idle()
        XCTAssertEqual(events, ["start A", "end A", "start B", "end B", "start C", "end C"])
    }

    func testOneRefreshAfterABurst() async {
        let queue = ProjectsWriteQueue()
        var writes = 0
        var refreshes = 0
        for _ in 0..<3 {
            queue.enqueue({
                try await Task.sleep(for: .milliseconds(20))
                writes += 1
            }, onFailure: { _ in }, refresh: { refreshes += 1 })
        }
        await queue.idle()
        XCTAssertEqual(writes, 3)
        XCTAssertEqual(refreshes, 1)
    }

    func testAFailedWriteReportsAndLaterWritesStillRun() async {
        let queue = ProjectsWriteQueue()
        var failures = 0
        var refreshes = 0
        var ran: [String] = []
        queue.enqueue({
            try await Task.sleep(for: .milliseconds(20))
            throw Refused()
        }, onFailure: { _ in failures += 1 }, refresh: { refreshes += 1 })
        queue.enqueue({ ran.append("B") }, onFailure: { _ in failures += 1 }, refresh: { refreshes += 1 })
        await queue.idle()
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(ran, ["B"])
        XCTAssertEqual(refreshes, 1)
    }

    func testALoneFailureDoesNotRefresh() async {
        let queue = ProjectsWriteQueue()
        var failures = 0
        var refreshes = 0
        queue.enqueue({ throw Refused() }, onFailure: { _ in failures += 1 }, refresh: { refreshes += 1 })
        await queue.idle()
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(refreshes, 0)
    }
}

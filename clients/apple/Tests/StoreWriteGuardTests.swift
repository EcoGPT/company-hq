import Observation
import XCTest
@testable import HQ

/// A store write that changes nothing wakes nobody:
/// `@Observable` notifies on every subscript or in-place write, equal or not,
/// so a re-read that answers what is already held must not write it that
/// way. Each guard has a positive twin: a real change still lands. Hosted, on
/// the chat fixture like `StoreObservationTests`.
@MainActor
final class StoreWriteGuardTests: XCTestCase {
    private var previousScenario: String?

    override func setUp() async throws {
        previousScenario = ProcessInfo.processInfo.environment["HQ_UI_SCENARIO"]
        setenv("HQ_UI_SCENARIO", "chat", 1)
        HQFixtureProtocol.contentMode = "ready"
    }

    override func tearDown() async throws {
        if let previousScenario {
            setenv("HQ_UI_SCENARIO", previousScenario, 1)
        } else {
            unsetenv("HQ_UI_SCENARIO")
        }
    }

    private func fixtureStore() -> AppStore {
        precondition(HQSimulatorFixture.isEnabled)
        let store = AppStore()
        store.start()
        return store
    }

    private final class Flag: @unchecked Sendable {
        var fired = 0
    }

    /// Counts the notifications a reader of `read` gets from `change`.
    private func notifications(of read: () -> Void, during change: () async -> Void) async -> Int {
        let flag = Flag()
        withObservationTracking { read() } onChange: { flag.fired += 1 }
        await change()
        return flag.fired
    }

    // MARK: - Meetings

    func testAnUnchangedMeetingsFrameWakesNoReader() async throws {
        let store = fixtureStore()
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data("""
            {"id": "m-guard", "title": "Review", "created_by_person_id": "bo",
             "created_at": "2026-10-14T12:00:00Z"}
            """.utf8))
        let first = await notifications(of: { _ = store.meetings }, during: {
            store.handle(.meetings([meeting]))
        })
        XCTAssertEqual(first, 1)
        let second = await notifications(of: { _ = store.meetings }, during: {
            store.handle(.meetings(store.meetings))
        })
        XCTAssertEqual(second, 0)
    }

    // MARK: - Ticking a task

    func testTickingATaskShowsAtOnceAndARefusalPutsItBack() async throws {
        let store = fixtureStore()
        guard let task = store.tasks.first(where: { $0.status != "done" }) else {
            throw XCTSkip("the fixture holds no open task")
        }
        store.setTaskStatus(task.id, status: "done")
        XCTAssertEqual(store.tasks.first { $0.id == task.id }?.status, "done")
        // The chat fixture serves no board, so the write is refused: the tick
        // reverts and says so.
        let deadline = Date().addingTimeInterval(2)
        while store.taskMutationError == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(store.taskMutationError)
        XCTAssertEqual(store.tasks.first { $0.id == task.id }, task)
    }

    func testAQuickTickThenUntickEndsInTheLastStateChosen() throws {
        // Two PATCHes from separate tasks with nothing ordering their
        // replies: the tick's reply landing after the untick must not put the
        // task back to done.
        let store = fixtureStore()
        guard let task = store.tasks.first(where: { $0.status == "open" }) else {
            throw XCTSkip("the fixture holds no open task")
        }
        store.setTaskStatus(task.id, status: "done")
        let tickedRow = try XCTUnwrap(store.tasks.first { $0.id == task.id })
        store.setTaskStatus(task.id, status: "open")
        let untickedRow = try XCTUnwrap(store.tasks.first { $0.id == task.id })
        XCTAssertEqual(untickedRow.status, "open")
        // The tick's reply, late: the hub's done row.
        store.applyTaskStatusReply(tickedRow, madeFor: tickedRow)
        XCTAssertEqual(store.tasks.first { $0.id == task.id }?.status, "open")
        // The untick's reply, for the row it was made for, still lands.
        let hubOpen = task.moved(to: "open")
        store.applyTaskStatusReply(hubOpen, madeFor: untickedRow)
        XCTAssertEqual(store.tasks.first { $0.id == task.id }, hubOpen)
    }
}

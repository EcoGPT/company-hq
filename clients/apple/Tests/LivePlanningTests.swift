import XCTest

@testable import HQ

/// The Tasks and Projects screens' real networking against a real HQ Community
/// server: `HQClient` and `EventSocket`, no fixtures and no mocks. It creates,
/// lists, edits, moves, reorders and comments on tasks and projects, and
/// checks that a second person's socket hears the board change.
///
/// Skipped unless all three are set, as `LiveServerTests` is (pass them through
/// `TEST_RUNNER_`, which `xcodebuild` strips before handing them to the test host):
///
///     HQ_LIVE_SERVER   the server's address, e.g. http://127.0.0.1:18790
///     HQ_LIVE_KEY_A    an invite key for an admin named Ada
///     HQ_LIVE_KEY_B    an invite key for a member named Bo
///
/// Run against a throwaway database: every run adds tasks, projects and comments
/// with names no earlier run used. Nothing is ever deleted from the server (a
/// deleted task is only hidden).
@MainActor
final class LivePlanningTests: XCTestCase {
    private struct Who {
        let response: HQClient.EnrollResponse
        var client: HQClient { HQClient(bearer: response.bearer) }
        var id: String { response.person.id }
    }

    private struct Timeout: Error {}

    private var server: String!
    private var keyA: String!
    private var keyB: String!
    private var previousServer: String?
    private var sockets: [EventSocket] = []

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        func value(_ name: String) -> String? {
            let text = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        guard let server = value("HQ_LIVE_SERVER"), let keyA = value("HQ_LIVE_KEY_A"),
              let keyB = value("HQ_LIVE_KEY_B")
        else { throw XCTSkip("HQ_LIVE_SERVER, HQ_LIVE_KEY_A and HQ_LIVE_KEY_B are not all set") }
        XCTAssertFalse(HQSimulatorFixture.isEnabled, "a live run must not be a fixture run")
        guard case .success(let normalized) = HQConfig.normalizedServer(server) else {
            throw XCTSkip("HQ_LIVE_SERVER is not a usable server address")
        }
        self.server = normalized
        self.keyA = keyA
        self.keyB = keyB
        previousServer = HQConfig.savedServer
        HQConfig.savedServer = normalized
    }

    override func tearDown() async throws {
        for socket in sockets { socket.stop() }
        sockets = []
        if server != nil { HQConfig.savedServer = previousServer }
    }

    // MARK: - Helpers

    private func signIn() async throws -> (ada: Who, bo: Who) {
        let ada = Who(response: try await HQClient.enroll(key: keyA, personName: nil, deviceName: "LivePlanningTests Ada"))
        let bo = Who(response: try await HQClient.enroll(key: keyB, personName: nil, deviceName: "LivePlanningTests Bo"))
        return (ada, bo)
    }

    /// A short word no earlier run used, so this run's rows are the only ones it finds.
    private func tag() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
    }

    private func expectStatus(
        _ status: Int, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected HTTP \(status), but the call succeeded", file: file, line: line)
        } catch let error as APIError {
            XCTAssertEqual(error.status, status, file: file, line: line)
        } catch {
            XCTFail("expected an APIError with HTTP \(status), got \(error)", file: file, line: line)
        }
    }

    @MainActor
    private final class FrameLog {
        private(set) var frames: [ServerFrame] = []
        func record(_ frame: ServerFrame) { frames.append(frame) }

        var boards: [[TeamTask]] {
            var found: [[TeamTask]] = []
            for frame in frames {
                if case .tasks(let list) = frame { found.append(list) }
            }
            return found
        }

        /// Waits until the newest `tasks` frame is a board that matches.
        func waitForBoard(
            _ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
            _ match: ([TeamTask]) -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if let latest = boards.last, match(latest) { return }
                if Date() > deadline { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTFail("no latest tasks frame with \(what) within \(Int(timeout))s; \(boards.count) frames seen", file: file, line: line)
            throw Timeout()
        }
    }

    private func openSocket(_ who: Who) async throws -> FrameLog {
        let log = FrameLog()
        let socket = EventSocket(bearer: who.response.bearer, onConnect: {}, onFrame: { log.record($0) })
        sockets.append(socket)
        socket.connect()
        let deadline = Date().addingTimeInterval(10)
        while !log.frames.contains(where: { if case .hello = $0 { true } else { false } }) {
            if Date() > deadline { throw Timeout() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return log
    }

    // MARK: - Tests

    func testTheServerSaysItDoesPlanning() async throws {
        let (ada, _) = try await signIn()
        try await ada.client.requirePlanning()
        let read = try await ada.client.projects()
        XCTAssertTrue(read.openTranscripts, "any member may open a synced coding session on this server")
        // Both capability probes the app makes before a write pass.
        _ = try await ada.client.createPlanningProject(
            name: "Capabilities \(tag())", body: nil, owner: ada.id, category: "Product", state: "Next", tags: [])
    }

    func testCreateListEditChangeStatusReorderCommentAndLinkAProject() async throws {
        let (ada, bo) = try await signIn()
        let word = tag()
        let boLog = try await openSocket(bo)

        // A project, made the way the new-project sheet makes it, and one with tags.
        let launch = try await ada.client.createPlanningProject(
            name: "Launch \(word)", body: "Ship it", owner: ada.id, category: "Product", state: "Now")
        XCTAssertEqual(launch.name, "Launch \(word)")
        XCTAssertEqual(launch.body, "Ship it")
        XCTAssertEqual(launch.ownerPersonId, ada.id)
        XCTAssertEqual(launch.planningState, "Now")
        XCTAssertEqual(launch.status, "active")
        XCTAssertEqual(launch.openTasks, 0)
        let docs = try await ada.client.createPlanningProject(
            name: "Docs \(word)", body: nil, owner: bo.id, category: "", state: "Next", tags: ["Eng", "docs-\(word)"])
        XCTAssertEqual(docs.effectiveTags, ["Eng", "docs-\(word)"])
        XCTAssertEqual(docs.ownerName, bo.response.person.name)

        // A task, created on a project, shows for the other person with a number.
        let first = try await ada.client.createTask(
            title: "First \(word)", body: "Write it down", ownerPersonId: ada.id, projectId: launch.id,
            dueAt: Date(timeIntervalSinceNow: 86_400 * 3))
        XCTAssertEqual(first.status, "open")
        XCTAssertEqual(first.body, "Write it down")
        XCTAssertEqual(first.projectId, launch.id)
        XCTAssertEqual(first.projectIds, [launch.id])
        XCTAssertNotNil(first.dueAt)
        XCTAssertNotNil(first.number)
        XCTAssertEqual(first.ref, first.number.map { "HQ-\($0)" })
        XCTAssertEqual(first.commentCount, 0)
        let second = try await ada.client.createTask(
            title: "Second \(word)", ownerPersonId: ada.id, projectId: launch.id)
        let third = try await ada.client.createTask(title: "Third \(word)", ownerPersonId: bo.id, projectId: nil)
        XCTAssertGreaterThan(second.number ?? 0, first.number ?? 0)
        XCTAssertGreaterThan(third.number ?? 0, second.number ?? 0)
        try await boLog.waitForBoard("the three new tasks") { board in
            [first, second, third].allSatisfy { new in board.contains { $0.id == new.id } }
        }

        let board = try await bo.client.tasks()
        XCTAssertTrue(board.contains { $0.id == first.id && $0.title == "First \(word)" })
        XCTAssertEqual(board.filter { $0.title.hasSuffix(word) }.map(\.title), ["First \(word)", "Second \(word)", "Third \(word)"])

        // Edits: words, a due date, the owner, the board it sits on.
        let edited = try await bo.client.editPlanningTask(
            id: first.id, fields: ["title": "First \(word) (edited)", "body": "Rewritten"])
        XCTAssertEqual(edited.title, "First \(word) (edited)")
        XCTAssertEqual(edited.body, "Rewritten")
        let dated = try await bo.client.editPlanningTask(id: first.id, fields: ["due_at": "2030-01-15T09:00:00Z"])
        XCTAssertEqual(ISO8601.parse(try XCTUnwrap(dated.dueAt)), ISO8601.parse("2030-01-15T09:00:00Z"))
        let undated = try await bo.client.editPlanningTask(id: first.id, fields: ["due_at": nil])
        XCTAssertNil(undated.dueAt)
        let handed = try await ada.client.assignTask(id: first.id, ownerPersonId: bo.id)
        XCTAssertEqual(handed.ownerPersonId, bo.id)
        XCTAssertEqual(handed.ownerName, bo.response.person.name)

        // Status: every list on the board, then done, then back.
        for status in ["in_progress", "blocked", "done", "open"] {
            let moved = try await ada.client.updateTaskStatus(id: second.id, status: status)
            XCTAssertEqual(moved.status, status)
            XCTAssertEqual(moved.isOpen, status != "done")
            XCTAssertEqual(moved.resolvedAt != nil, status == "done", "resolved only while done (\(status))")
        }
        _ = try await ada.client.updateTaskStatus(id: second.id, status: "done")
        let finished = try await ada.client.tasks().first { $0.id == second.id }
        XCTAssertEqual(finished?.resolvedByPersonId, ada.id)

        // Reorder: the answer is the whole board in its new order, and it sticks.
        let ordered = try await bo.client.reorderTask(id: third.id, anchorId: first.id, isAfter: false)
        XCTAssertEqual(ordered.filter { $0.title.contains(word) }.map(\.id), [third.id, first.id, second.id])
        let after = try await ada.client.reorderTask(id: third.id, anchorId: second.id, isAfter: true)
        XCTAssertEqual(after.filter { $0.title.contains(word) }.map(\.id), [first.id, second.id, third.id])
        let reread = try await bo.client.tasks()
        XCTAssertEqual(reread.filter { $0.title.contains(word) }.map(\.id), [first.id, second.id, third.id])

        // Comments, on a task and on a project, oldest first, counted on the card.
        try await ada.client.addComment(kind: "tasks", id: first.id, body: "Started")
        try await bo.client.addComment(kind: "tasks", id: first.id, body: "Looks good")
        let comments = try await ada.client.taskComments(id: first.id)
        XCTAssertEqual(comments.map(\.body), ["Started", "Looks good"])
        XCTAssertEqual(comments.map(\.authorName), [ada.response.person.name, bo.response.person.name])
        XCTAssertEqual(comments.map(\.authorPersonId), [ada.id, bo.id])
        XCTAssertTrue(comments.allSatisfy { !$0.isViaAgent })
        let counted = try await bo.client.tasks().first { $0.id == first.id }
        XCTAssertEqual(counted?.commentCount, 2)
        try await ada.client.addComment(kind: "projects", id: launch.id, body: "Kickoff")
        let projectThread = try await bo.client.projectComments(id: launch.id)
        XCTAssertEqual(projectThread.map(\.body), ["Kickoff"])
        await expectStatus(400) { try await ada.client.addComment(kind: "tasks", id: first.id, body: "   ") }
        await expectStatus(404) { try await ada.client.addComment(kind: "tasks", id: "no-such-task", body: "hi") }

        // Projects: several boards on a task, tags, a rename, archive and restore, close.
        let both = try await ada.client.setTaskProjects(id: first.id, projectIds: [docs.id, launch.id])
        XCTAssertEqual(both.projectIds, [docs.id, launch.id])
        XCTAssertEqual(both.projectId, docs.id)
        let single = try await ada.client.moveTaskToProject(id: first.id, projectId: launch.id)
        XCTAssertEqual(single.projectIds, [launch.id])
        let off = try await ada.client.moveTaskToProject(id: first.id, projectId: nil)
        XCTAssertEqual(off.projectIds, [])
        XCTAssertNil(off.projectId)
        let tagged = try await ada.client.setProjectTags(id: launch.id, tags: ["Growth", "q1-\(word)"])
        XCTAssertEqual(tagged.effectiveTags, ["Growth", "q1-\(word)"])
        let renamed = try await bo.client.patchPlanningProject(id: launch.id, fields: ["name": "Launch \(word) v2", "body": "Longer"])
        XCTAssertEqual(renamed.name, "Launch \(word) v2")
        XCTAssertEqual(renamed.body, "Longer")
        let paused = try await bo.client.patchPlanningProject(
            id: launch.id, fields: ["status": "active", "planning_state": "Backlog"])
        XCTAssertEqual(paused.activityTitle, "Paused")
        let handedOn = try await bo.client.patchPlanningProject(id: launch.id, fields: ["owner_person_id": bo.id])
        XCTAssertEqual(handedOn.ownerPersonId, bo.id)
        try await ada.client.archivePlanningProject(id: docs.id, archived: true)
        var projects = try await ada.client.projects().projects
        XCTAssertNotNil(projects.first { $0.id == docs.id }?.archivedAt)
        try await ada.client.archivePlanningProject(id: docs.id, archived: false)
        projects = try await ada.client.projects().projects
        XCTAssertNil(projects.first { $0.id == docs.id }?.archivedAt)
        // The project counts follow the tasks on it; a board with open work cannot be closed.
        _ = try await ada.client.moveTaskToProject(id: first.id, projectId: launch.id)
        let counted2 = try await ada.client.projects().projects.first { $0.id == launch.id }
        // First is open and Second is done; Third is on no project.
        XCTAssertEqual(counted2?.openTasks, 1)
        XCTAssertEqual(counted2?.totalTasks, 2)
        XCTAssertEqual(counted2?.commentCount, 1)
        await expectStatus(409) { _ = try await ada.client.closeProject(id: launch.id) }
        for id in [first.id, second.id] { _ = try await ada.client.updateTaskStatus(id: id, status: "done") }
        let closed = try await ada.client.closeProject(id: launch.id)
        XCTAssertEqual(closed.status, "done")
        XCTAssertFalse(closed.isActive)
        XCTAssertNotNil(closed.closedAt)

        // Delete hides: gone from the board for everyone, and no longer reachable.
        try await bo.client.deleteTask(id: third.id)
        let end = try await ada.client.tasks()
        XCTAssertFalse(end.contains { $0.id == third.id })
        XCTAssertTrue(end.contains { $0.id == first.id })
        await expectStatus(404) { _ = try await ada.client.updateTaskStatus(id: third.id, status: "done") }
        try await boLog.waitForBoard("the deleted task gone") { board in
            board.contains { $0.id == first.id } && !board.contains { $0.id == third.id }
        }

        XCTAssertTrue(boLog.frames.allSatisfy { if case .unknown = $0 { false } else { true } }, "a frame the app could not read")
    }

    func testTheBoardDoesNotRepeatOrRefuseWhatItDoesNotSupport() async throws {
        let (ada, _) = try await signIn()
        // The server says it has no repeating tasks, so the app refuses before it writes one.
        let recurrence = TaskRecurrence(freq: "daily", timezone: "UTC")
        do {
            _ = try await ada.client.createTask(
                title: "Repeats \(tag())", ownerPersonId: ada.id, recurrence: recurrence)
            XCTFail("a repeating task must not be created on a server without them")
        } catch TaskScheduleError.serverUpdateRequired {
        }
    }
}

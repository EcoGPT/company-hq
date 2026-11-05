import XCTest

@testable import HQ

/// The Projects board's arithmetic: what each box, page and badge counts.
final class ProjectsModelTests: XCTestCase {
    func testThreadContactLinksAndBoardNavigation() {
        let id = "01a0d407-770b-77eb-8980-10e14f4395aa"
        XCTAssertEqual(CodingThreadLink.id(from: URL(string: CodingThreadLink.url(id))!), id)
        for link in ["https://example.com/thread/abc", "hq://thread/abc?token=x", "hq://thread/abc/extra", "hq://evil/abc", "hq://thread/abc#foo"] {
            XCTAssertNil(CodingThreadLink.id(from: URL(string: link)!))
        }
        HQConfig.savedServer = "https://hq.example.com"
        defer { HQConfig.savedServer = nil }
        XCTAssertEqual(TaskLink.number(from: URL(string: TaskLink.url(42))!), 42)
        XCTAssertEqual(TaskLink.number(from: URL(string: "https://hq.example.com/hq-\(7)")!), 7)
        for link in [
            "http://hq.example.com/HQ-\(1)", "https://evil.example.org/HQ-\(1)", "https://hq.example.com/HQ-\(1)/x",
            "https://hq.example.com/HQ-\(1)?x=1", "https://hq.example.com/HQ-", "hq://task/HQ-\(1)",
        ] {
            XCTAssertNil(TaskLink.number(from: URL(string: link)!), link)
        }
        let path: [ProjectsRoute] = [.thread(id)]
        XCTAssertEqual(ProjectsRouting.opening(.task("a"), on: path), [.thread(id), .task("a")])
        XCTAssertEqual(ProjectsRouting.closingPanel([.thread(id), .task("a")], under: .thread(id)), path)
    }

    func testProjectCategoriesReadOldNamesAndRewriteToNewOnes() {
        var legacy = project("a", category: "Product")
        XCTAssertEqual(ProjectCategory.of(legacy), [.eng])
        XCTAssertEqual(ProjectCategory.of(project("b", category: nil)), [])

        legacy.tags = ["Product", "Harness", "support"]
        XCTAssertEqual(ProjectCategory.of(legacy), [.eng, .support])
        XCTAssertEqual(ProjectCategory.tags(legacy, setting: [.support, .growth]), ["Growth", "Support", "Harness"])
        XCTAssertEqual(ProjectCategory.tags(legacy, setting: []), ["Harness"])
    }

    private let date = "2026-09-22T12:00:00Z"

    private func project(
        _ id: String, category: String? = "Product", state: String = "Next", kind: String? = nil,
        open: Int = 1
    ) -> Project {
        var project = Project(
            id: id, name: id, body: nil, ownerPersonId: "lead", ownerName: "Lead", status: "active",
            openTasks: open, createdAt: date, closedAt: nil)
        project.planningCategory = category
        project.planningState = state
        project.kind = kind
        return project
    }

    private func task(
        _ id: String, project: String?, owner: String = "me", status: String = "open"
    ) -> TeamTask {
        TeamTask(
            id: id, title: id, status: status, ownerPersonId: owner, ownerName: owner, createdByPersonId: owner,
            createdAt: date, resolvedAt: status == "done" ? date : nil, projectId: project)
    }

    func testSharedTaskAppearsInBothProjectsAndSurvivesOptimisticMoves() {
        let shared = TeamTask(id: "shared", title: "Shared", status: "open", ownerPersonId: "me", ownerName: "Me", createdByPersonId: "me", createdAt: date, projectId: "a", projectIds: ["a", "b"])
        XCTAssertEqual(ProjectsModel.tasks(of: project("a"), in: [shared]).count, 1)
        XCTAssertEqual(ProjectsModel.tasks(of: project("b"), in: [shared]).count, 1)
        XCTAssertEqual(shared.moved(to: "in_progress").projectIds, ["a", "b"])
        var archived = project("a")
        archived.archivedAt = date
        XCTAssertEqual(ProjectsModel.mine([shared], projects: [archived, project("b")], owner: "me").count, 1)
    }

    func testTagsFallBackToLegacyCategoryUntilExplicitlyEdited() {
        var component = project("memory")
        XCTAssertEqual(component.effectiveTags, ["Product"])
        component.tags = ["Harness", "Engineering"]
        XCTAssertEqual(component.effectiveTags, ["Harness", "Engineering"])
        component.tags = []
        XCTAssertEqual(component.effectiveTags, [])
        XCTAssertEqual(component.activityTitle, "Maintained")
    }

    /// The old My tasks took Now alone and hid most of a person's tasks; the new one
    /// hides nothing by planning state — only archived projects drop out.
    func testMyTasksIsEveryOpenTaskIOwnWhateverTheProjectsStage() {
        var archived = project("gone")
        archived.archivedAt = date
        let projects = [project("now", state: "Now"), project("next"), project("idea", state: "Backlog"), archived]
        let tasks = [
            task("a", project: "now"), task("b", project: "next"), task("c", project: "idea"),
            task("d", project: nil), task("e", project: "gone"), task("f", project: "next", owner: "you"),
            task("g", project: "next", status: "done"),
        ]
        XCTAssertEqual(ProjectsModel.mine(tasks, projects: projects, owner: "me").map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(ProjectsModel.myOpenCount(tasks: tasks, projects: projects, owner: "me"), 4)
    }

    /// The lists run To do, In progress, Blocked, Done; a status no list
    /// names reads as To do.
    func testListsRunInOrderAndAnUnknownStatusReadsAsToDo() {
        XCTAssertEqual(ProjectsModel.statusOrder, ["open", "in_progress", "blocked", "done"])
        XCTAssertEqual(ProjectsModel.list(of: task("t", project: "p", status: "someday")), "open")
        XCTAssertEqual(ProjectsModel.list(of: task("t", project: "p", status: "blocked")), "blocked")
    }

    func testCompletedItemsDisappearAtLocalMidnightWithoutChangingTheRecord() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let formatter = ISO8601DateFormatter()
        let completed = try XCTUnwrap(formatter.date(from: "2026-09-18T03:59:55Z"))
        let done = TeamTask(
            id: "completed", title: "Finished", status: "done", ownerPersonId: "ada", ownerName: "Ada",
            createdByPersonId: "ada", createdAt: formatter.string(from: completed), resolvedByPersonId: "ada",
            resolvedAt: formatter.string(from: completed), projectId: "project-0")
        XCTAssertTrue(PlanningModel.isCompletedToday(done, now: completed, calendar: calendar))
        XCTAssertFalse(PlanningModel.isCompletedToday(done, now: completed.addingTimeInterval(10), calendar: calendar))
    }

    // MARK: - On the cards

    /// Every card shows its task number; an older server's has none.
    func testCardsShowTheirNumberAndNothingWithoutOne() {
        let numbered = TeamTask(
            id: "t", number: 486, title: "t", status: "open", ownerPersonId: "me", ownerName: "me",
            createdByPersonId: "me", createdAt: date)
        XCTAssertEqual(ProjectsModel.cardRef(numbered), "HQ-\(486)")
        XCTAssertNil(ProjectsModel.cardRef(task("old", project: nil)))
        XCTAssertNil(ProjectsModel.cardRef(nil))
    }

    /// A feed reads oldest first, whatever order arrives; two at the same
    /// instant keep the server's order.
    func testCommentsReadOldestFirst() {
        func comment(_ id: String, _ at: String) -> HQComment {
            HQComment(id: id, authorName: "Ada", authorPersonId: "ada", body: id, createdAt: at)
        }
        let feed = ProjectsModel.feed([
            comment("latest", "2026-09-22T12:05:00Z"),
            comment("first", "2026-09-22T11:00:00Z"),
            comment("tie-a", "2026-09-22T12:00:00Z"),
            comment("tie-b", "2026-09-22T12:00:00Z"),
        ])
        XCTAssertEqual(feed.map(\.id), ["first", "tie-a", "tie-b", "latest"])
        XCTAssertEqual(ProjectsModel.feed([]), [])
    }

    /// Repeat on the card writes what the old task page wrote, in the
    /// series' own timezone, and reads back through the wire unchanged.
    func testRepeatRoundTripsThroughTheModelAndTheWire() throws {
        let zoned = TeamTask(
            recurrence: TaskRecurrence(freq: "daily", timezone: "Europe/London"), id: "r", title: "r",
            status: "open", ownerPersonId: "me", ownerName: "me", createdByPersonId: "me", createdAt: date)
        let plain = task("p", project: "site")
        for option in TaskRepeat.allCases {
            let rule = ProjectsModel.recurrence(option, for: zoned, deviceTimeZone: "America/Denver")
            XCTAssertEqual(rule?.freq, option == .never ? nil : option.rawValue)
            XCTAssertEqual(rule?.timezone, option == .never ? nil : "Europe/London")
            XCTAssertEqual(
                ProjectsModel.recurrence(option, for: plain, deviceTimeZone: "America/Denver")?.timezone,
                option == .never ? nil : "America/Denver")

            let written = TeamTask(
                recurrence: rule, id: "w", number: 482, title: "w", status: "open", ownerPersonId: "me",
                ownerName: "me", createdByPersonId: "me", createdAt: date)
            let read = try JSONDecoder().decode(TeamTask.self, from: JSONEncoder().encode(written))
            XCTAssertEqual(ProjectsModel.repeatOption(read), option)
            XCTAssertEqual(read.recurrence, rule)
        }
        XCTAssertEqual(ProjectsModel.repeatText(.weekly), "Repeats weekly")
        XCTAssertNil(ProjectsModel.repeatText(.never))
        XCTAssertEqual(ProjectsModel.repeatOption(plain), .never)
    }

    /// Only the open head of a series takes a new schedule.
    func testOnlyTheOpenHeadOfASeriesChangesItsRepeat() {
        let weekly = TaskRecurrence(freq: "weekly", timezone: "UTC")
        func occurrence(status: String, next: String?) -> TeamTask {
            TeamTask(
                recurrence: weekly, nextTaskId: next, id: "o", title: "o", status: status, ownerPersonId: "me",
                ownerName: "me", createdByPersonId: "me", createdAt: date)
        }
        XCTAssertTrue(ProjectsModel.canChangeRepeat(occurrence(status: "open", next: nil)))
        XCTAssertTrue(ProjectsModel.canChangeRepeat(occurrence(status: "blocked", next: nil)))
        XCTAssertFalse(ProjectsModel.canChangeRepeat(occurrence(status: "done", next: nil)))
        XCTAssertFalse(ProjectsModel.canChangeRepeat(occurrence(status: "open", next: "o2")))
    }

    /// A board's comments open beside it: closing them leaves the board.
    func testTheCommentsPanelIsNeitherABoardNorACard() {
        let panel = ProjectsRoute.projectComments("site")
        XCTAssertTrue(panel.isPanel)
        XCTAssertFalse(panel.isCard)
        XCTAssertFalse(panel.isBoard)
        XCTAssertTrue(ProjectsRoute.project("site").isBoard)
        XCTAssertFalse(ProjectsRoute.task("t").isBoard)
    }
    // MARK: - Drops

    private func cards(_ ids: [String], status: String) -> [TeamTask] {
        ids.map { task($0, project: "p", status: status) }
    }

    /// A card dropped in another list changes status, then lands against
    /// the card now below it — the PATCH, then `POST /v1/tasks/:id/order`.
    func testATaskDroppedInAnotherListChangesStatusThenTakesItsSlot() {
        let moving = task("m", project: "p", status: "open")
        let inProgress = cards(["a", "b", "c"], status: "in_progress")
        XCTAssertEqual(
            ProjectsModel.taskDrop(moving, into: "in_progress", at: 1, cards: inProgress),
            TaskDrop(status: "in_progress", anchor: TaskAnchor(id: "b", isAfter: false)))
        // The foot of a list lands after its last card.
        XCTAssertEqual(
            ProjectsModel.taskDrop(moving, into: "in_progress", at: 3, cards: inProgress),
            TaskDrop(status: "in_progress", anchor: TaskAnchor(id: "c", isAfter: true)))
        // An empty list has no neighbour: the status alone.
        XCTAssertEqual(
            ProjectsModel.taskDrop(moving, into: "blocked", at: 0, cards: []), TaskDrop(status: "blocked", anchor: nil))
        // Done reads newest first, so a drop there is only the status.
        XCTAssertEqual(
            ProjectsModel.taskDrop(moving, into: "done", at: 0, cards: cards(["d"], status: "done")),
            TaskDrop(status: "done", anchor: nil))
    }

    /// Within a list, a drop is a reorder: the before-id is the card now
    /// under it; dropping it back where it was writes nothing.
    func testATaskDroppedInItsOwnListReordersBeforeItsNewNeighbour() {
        let list = cards(["a", "b", "c", "d"], status: "open")
        let moving = list[3]
        XCTAssertEqual(
            ProjectsModel.taskDrop(moving, into: "open", at: 1, cards: list),
            TaskDrop(status: nil, anchor: TaskAnchor(id: "b", isAfter: false)))
        XCTAssertEqual(
            ProjectsModel.taskDrop(list[0], into: "open", at: 3, cards: list),
            TaskDrop(status: nil, anchor: TaskAnchor(id: "d", isAfter: true)))
        XCTAssertNil(ProjectsModel.taskDrop(moving, into: "open", at: 3, cards: list))
        XCTAssertNil(ProjectsModel.taskDrop(list[1], into: "open", at: 1, cards: list))
        // Done keeps no hand order.
        let done = cards(["x", "y"], status: "done")
        XCTAssertNil(ProjectsModel.taskDrop(done[1], into: "done", at: 0, cards: done))
        // The menu's Move To lands at the foot.
        XCTAssertEqual(
            ProjectsModel.taskMove(task("m", project: "p"), to: "blocked", cards: cards(["z"], status: "blocked")),
            TaskDrop(status: "blocked", anchor: TaskAnchor(id: "z", isAfter: true)))
    }

    /// "No category" and a status list that does not exist take nothing.
    func testOnlyRealListsTakeADrop() {
        XCTAssertFalse(ProjectsModel.canDrop(into: "none", kind: .project))
        XCTAssertFalse(ProjectsModel.canDrop(into: "held", kind: .task))
        XCTAssertFalse(ProjectsModel.canDrop(into: "Product", kind: .task))
        XCTAssertTrue(ProjectsModel.canDrop(into: "in_progress", kind: .task))
        XCTAssertTrue(ProjectsModel.canDrop(into: "Marketing", kind: .project))
        XCTAssertNil(ProjectsModel.taskDrop(task("m", project: "p"), into: "nowhere", at: 0, cards: []))
    }

    /// The optimistic move draws what the server will answer: the new status,
    /// the row beside its anchor.
    func testATaskMoveAppliesLocallyTheWayTheHubWillAnswer() {
        let tasks = [
            task("a", project: "p"), task("b", project: "p"), task("c", project: "p", status: "in_progress"),
        ]
        let moved = ProjectsModel.applying(
            TaskDrop(status: "in_progress", anchor: TaskAnchor(id: "c", isAfter: false)), to: "a", in: tasks)
        XCTAssertEqual(moved.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(moved[1].status, "in_progress")
        let done = ProjectsModel.applying(TaskDrop(status: "done", anchor: nil), to: "b", in: tasks)
        XCTAssertEqual(done.map(\.id), ["a", "b", "c"])
        XCTAssertNotNil(done[1].resolvedAt)
    }

    /// The pointer's slot is how many of the list's other cards sit above
    /// it; between lists it belongs to the nearer; a list that takes no
    /// drop gives no spot at all.
    func testTheDropSpotComesFromThePointerAndTheFrames() {
        let lists = [
            BoardListFrame(id: "open", frame: CGRect(x: 0, y: 0, width: 260, height: 600), isAccepting: true),
            BoardListFrame(id: "in_progress", frame: CGRect(x: 272, y: 0, width: 260, height: 600), isAccepting: true),
            BoardListFrame(id: "closed", frame: CGRect(x: 544, y: 0, width: 260, height: 600), isAccepting: false),
        ]
        let cards = [
            BoardCardFrame(id: "a", list: "open", frame: CGRect(x: 8, y: 40, width: 244, height: 60)),
            BoardCardFrame(id: "b", list: "open", frame: CGRect(x: 8, y: 108, width: 244, height: 60)),
            BoardCardFrame(id: "m", list: "open", frame: CGRect(x: 8, y: 176, width: 244, height: 60)),
        ]
        func spot(_ x: CGFloat, _ y: CGFloat) -> BoardDropSpot? {
            BoardDropMath.spot(at: CGPoint(x: x, y: y), lists: lists, cards: cards, dragging: "m", gutter: 12)
        }
        XCTAssertEqual(spot(100, 20), BoardDropSpot(list: "open", index: 0))
        XCTAssertEqual(spot(100, 150), BoardDropSpot(list: "open", index: 2))
        // The dragged card itself never counts.
        XCTAssertEqual(spot(100, 500), BoardDropSpot(list: "open", index: 2))
        XCTAssertEqual(spot(265, 50), BoardDropSpot(list: "open", index: 0))
        XCTAssertEqual(spot(268, 50), BoardDropSpot(list: "in_progress", index: 0))
        XCTAssertNil(spot(600, 50))
        XCTAssertEqual(BoardDropMath.edge(at: CGPoint(x: 10, y: 0), width: 800), .leading)
        XCTAssertEqual(BoardDropMath.edge(at: CGPoint(x: 790, y: 0), width: 800), .trailing)
        XCTAssertNil(BoardDropMath.edge(at: CGPoint(x: 400, y: 0), width: 800))
    }

    // MARK: - Panel routing

    /// One right-hand slot: a card or the comments fills it, the next one
    /// swaps it, a board closes it, and closing lands on the board under it.
    func testThePanelIsOneSlotBesideTheBoard() {
        let board: [ProjectsRoute] = [.project("site")]
        let card = ProjectsRouting.opening(.task("a"), on: board)
        XCTAssertEqual(card, [.project("site"), .task("a")])
        XCTAssertEqual(ProjectsRouting.panel(card), .task("a"))
        XCTAssertEqual(ProjectsRouting.openCardID(card), "a")
        // Another card swaps the panel rather than stacking on it.
        let other = ProjectsRouting.opening(.task("b"), on: card)
        XCTAssertEqual(other, [.project("site"), .task("b")])
        // The comments and a card share the slot.
        let comments = ProjectsRouting.opening(.projectComments("site"), on: other)
        XCTAssertEqual(comments, [.project("site"), .projectComments("site")])
        XCTAssertNil(ProjectsRouting.openCardID(comments))
        // Opening a board closes the panel on the way.
        XCTAssertEqual(ProjectsRouting.opening(.mine, on: other), [.project("site"), .mine])
        // ✕ or Esc lands on the board it was opened from…
        XCTAssertEqual(ProjectsRouting.closingPanel(other, under: .project("site")), board)
        // …or, from the room or a fixture route, on the card's own board.
        XCTAssertEqual(ProjectsRouting.closingPanel([.task("a")], under: .mine), [.mine])
        XCTAssertNil(ProjectsRouting.panel(board))
        XCTAssertTrue(ProjectsRoute.task("a").isInPanel)
        XCTAssertTrue(ProjectsRoute.projectComments("site").isInPanel)
        XCTAssertFalse(ProjectsRoute.mine.isInPanel)
    }
}

/// A drag on a board, start to finish, as the Mac's own drag drives it.
@MainActor
final class BoardDragTests: XCTestCase {
    private let card = CGSize(width: 240, height: 60)

    /// Two lists side by side, To do holding `a` and `b`, In progress `c`.
    private func board(_ perform: @escaping (BoardDragItem, BoardDropSpot) -> Void) -> BoardDrag {
        let drag = BoardDrag()
        drag.viewportWidth = 1_000
        drag.listFrames = [
            "open": CGRect(x: 20, y: 0, width: 260, height: 400),
            "in_progress": CGRect(x: 290, y: 0, width: 260, height: 400),
        ]
        drag.accepting = ["open": .task, "in_progress": .task]
        drag.cardFrames = [
            "a": BoardCardFrame(id: "a", list: "open", frame: CGRect(x: 30, y: 40, width: 240, height: 60)),
            "b": BoardCardFrame(id: "b", list: "open", frame: CGRect(x: 30, y: 110, width: 240, height: 60)),
            "c": BoardCardFrame(id: "c", list: "in_progress", frame: CGRect(x: 300, y: 40, width: 240, height: 60)),
        ]
        drag.perform = perform
        return drag
    }

    /// The reported bug: a card that landed could not be dragged back.
    func testACardThatLandedDragsStraightBack() {
        var drops: [BoardDropSpot] = []
        let drag = board { _, spot in drops.append(spot) }

        drag.begin(BoardDragItem(kind: .task, id: "a", list: "open", index: 0, size: card))
        drag.move(to: CGPoint(x: 400, y: 150))
        drag.drop(at: CGPoint(x: 400, y: 150))
        XCTAssertEqual(drops.last, BoardDropSpot(list: "in_progress", index: 1))
        XCTAssertNil(drag.item)

        // The board redraws it in In progress; picked straight up, it lifts.
        drag.cardFrames["a"] = BoardCardFrame(
            id: "a", list: "in_progress", frame: CGRect(x: 300, y: 110, width: 240, height: 60))
        drag.begin(BoardDragItem(kind: .task, id: "a", list: "in_progress", index: 1, size: card))
        XCTAssertEqual(drag.item?.id, "a")
        drag.move(to: CGPoint(x: 100, y: 20))
        drag.drop(at: CGPoint(x: 100, y: 20))
        XCTAssertEqual(drops.last, BoardDropSpot(list: "open", index: 0))
        XCTAssertEqual(drops.count, 2)
    }

    /// The gap is always somewhere: it starts in the card's own place and,
    /// over no list, stays where it last was — lists never jump as the
    /// pointer crosses empty board, and letting go lands at the gap.
    func testTheGapStaysPutOverEmptyBoard() {
        var drops: [BoardDropSpot] = []
        let drag = board { _, spot in drops.append(spot) }
        drag.begin(BoardDragItem(kind: .task, id: "b", list: "open", index: 1, size: card))
        drag.move(to: CGPoint(x: 800, y: 150))
        XCTAssertEqual(drag.spot, BoardDropSpot(list: "open", index: 1))
        drag.move(to: CGPoint(x: 400, y: 150))
        XCTAssertEqual(drag.spot, BoardDropSpot(list: "in_progress", index: 1))
        drag.move(to: CGPoint(x: 800, y: 150))
        XCTAssertEqual(drag.spot, BoardDropSpot(list: "in_progress", index: 1))
        drag.drop(at: CGPoint(x: 800, y: 150))
        XCTAssertEqual(drops, [BoardDropSpot(list: "in_progress", index: 1)])
        XCTAssertNil(drag.spot)
    }

    /// A card grabbed near the board's edge does not scroll the board until
    /// the pointer has left the edge once and come back.
    func testEdgeScrollingWaitsUntilThePointerLeavesTheEdge() {
        let drag = board { _, _ in }
        drag.begin(BoardDragItem(kind: .task, id: "a", list: "open", index: 0, size: card))
        drag.move(to: CGPoint(x: 30, y: 60))
        XCTAssertNil(drag.edge)
        drag.move(to: CGPoint(x: 120, y: 60))
        drag.move(to: CGPoint(x: 30, y: 60))
        XCTAssertEqual(drag.edge, .leading)
    }

    /// A list that takes no such card is never a spot.
    func testAListThatTakesNothingIsNoSpot() {
        var drops = 0
        let drag = board { _, _ in drops += 1 }
        drag.accepting["in_progress"] = .project
        drag.begin(BoardDragItem(kind: .task, id: "a", list: "open", index: 0, size: card))
        drag.drop(at: CGPoint(x: 400, y: 150))
        XCTAssertEqual(drops, 0)
    }

    /// The server keeps a done task done unless it is reopened, so moving one
    /// out of Done to a working list reopens it first.
    func testLeavingDoneReopensFirst() {
        XCTAssertEqual(ProjectsModel.statusWrites(from: "done", to: "in_progress"), ["open", "in_progress"])
        XCTAssertEqual(ProjectsModel.statusWrites(from: "done", to: "blocked"), ["open", "blocked"])
        XCTAssertEqual(ProjectsModel.statusWrites(from: "done", to: "open"), ["open"])
        XCTAssertEqual(ProjectsModel.statusWrites(from: "open", to: "done"), ["done"])
        XCTAssertEqual(ProjectsModel.statusWrites(from: "blocked", to: "in_progress"), ["in_progress"])
        XCTAssertEqual(ProjectsModel.statusWrites(from: "open", to: "open"), [])
    }
}

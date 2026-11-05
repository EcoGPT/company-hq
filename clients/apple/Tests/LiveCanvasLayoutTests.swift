import XCTest

#if !LISTING_HEADLESS
@testable import HQ
#endif

/// The Live canvas's layout: every
/// node inside the width, none on another, the same answer for the same input
/// however it arrives, people alternating down the two sides with their avatars
/// at the outer edge, every session and person drawn (no cap), the lines and where they meet
/// their nodes, the projects in the centre, the
/// overlap arc, and the idle row. Nothing here draws.
final class LiveCanvasLayoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let widths: [CGFloat] = [360, 480, 720, 900, 1000, 1180, 1440, 2400]

    private func thread(
        _ id: String, owner: String, minutesAgo: Double = 1, title: String? = "A session", state: String = "idle",
        tasks: [(String, String, String)] = [], projects: [(String, String)] = [], provider: String = "claude"
    ) -> CodingThread {
        var json: [String: Any] = [
            "session_id": id, "intent": "", "state": state,
            "last_seen_at": 0.0, "last_activity_at": (now.timeIntervalSince1970 - minutesAgo * 60) * 1000,
            "owner_person_id": owner, "owner_name": owner.capitalized,
            "provider": provider, "repo": "tmp-worktree-7",
            "tasks": tasks.map { ["id": $0.0, "ref": $0.1, "title": $0.2] },
            "projects": projects.map { ["id": $0.0, "name": $0.1] },
        ]
        if let title { json["title"] = title }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(CodingThread.self, from: data)
    }

    /// The projects the server keeps for itself, which the centre never draws.
    private let systemIds: Set<String> = ["standing"]

    private func model(
        _ threads: [CodingThread], search: String = "", roster: [LiveThreadsModel.Idle] = []
    ) -> LiveThreadsModel {
        LiveThreadsModel(threads: threads, now: now, search: search, isRemoved: { _ in false }, roster: roster)
    }

    /// Five people: 12, 5, 3, 1 and 2 sessions, linked across the projects.
    private func fixtureThreads() -> [CodingThread] {
        let counts = [("uma", 12), ("bo", 5), ("pat", 3), ("kim", 1), ("lee", 2)]
        var threads: [CodingThread] = []
        var serial = 0
        for (owner, count) in counts {
            for index in 0..<count {
                serial += 1
                let projects: [(String, String)] =
                    switch serial % 4 {
                    case 0: [("o0", "Project 0")]
                    case 1: [("o1", "Project 1")]
                    case 2: [("standing", "Standing")]
                    default: []
                    }
                threads.append(thread("\(owner)-\(index)", owner: owner, minutesAgo: Double(index % 9 + serial % 6), projects: projects))
            }
        }
        return threads
    }

    private func canvas(
        _ threads: [CodingThread]? = nil, systemProjectIds: Set<String>? = nil, width: CGFloat = 1200,
        roster: [LiveThreadsModel.Idle] = []
    ) -> LiveCanvasLayout {
        layoutNow(model: model(threads ?? fixtureThreads(), roster: roster), systemProjectIds: systemProjectIds, width: width)
    }

    /// The layout at the test clock, with the places the person has put nodes.
    private func layoutNow(
        model: LiveThreadsModel, systemProjectIds: Set<String>? = nil, width: CGFloat,
        pins: LiveCanvasPositions = LiveCanvasPositions(), floor: CGRect? = nil
    ) -> LiveCanvasLayout {
        LiveCanvasLayout.layout(
            model: model, systemProjectIds: systemProjectIds ?? systemIds, width: width, now: now, pins: pins, floor: floor)
    }

    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.intersection(b).width > 0.001 && a.intersection(b).height > 0.001
    }

    private func node(_ layout: LiveCanvasLayout, _ kind: LiveCanvasLayout.Kind, _ id: String) -> LiveCanvasLayout.Node {
        layout.nodes.first { $0.kind == kind && $0.refId == id }!
    }

    // MARK: Width

    /// Under the floor the canvas is still laid out, at the floor's width: the view scales it
    /// down to the space (`LiveCanvasCamera.fit`), so a narrow window gets the same picture.
    func testANarrowWidthGetsTheMinimumWidthLayout() {
        let wide = layoutNow(model: model(fixtureThreads()), width: 720)
        XCTAssertEqual(wide.size.width, LiveCanvasLayout.minWidth)
        for width in [719, 600, 480, 360, 100, 0] as [CGFloat] {
            let narrow = layoutNow(model: model(fixtureThreads()), width: width)
            XCTAssertEqual(narrow, wide, "the layout at \(width) is the 720pt layout")
            XCTAssertEqual(narrow.size.width, 720)
        }
    }

    func testANarrowWidthKeepsEveryNodeInsideAndApart() {
        let roster: [LiveThreadsModel.Idle] = [.init(id: "z1", name: "Zed"), .init(id: "z2", name: "Yan")]
        for width in [480, 360] as [CGFloat] {
            let layout = layoutNow(model: model(fixtureThreads(), roster: roster), width: width)
            let bounds = CGRect(origin: .zero, size: layout.size)
            for (index, a) in layout.nodes.enumerated() {
                XCTAssertTrue(bounds.contains(a.frame), "\(a.id) at \(width)")
                for b in layout.nodes[(index + 1)...] { XCTAssertFalse(overlaps(a.frame, b.frame), "\(a.id) and \(b.id) at \(width)") }
            }
        }
    }

    func testTheSameNarrowInputGivesTheSameFrames() {
        let first = layoutNow(model: model(fixtureThreads()), width: 360)
        let again = layoutNow(model: model(fixtureThreads().reversed()), width: 360)
        XCTAssertEqual(first.nodes.map(\.frame), again.nodes.map(\.frame))
        XCTAssertEqual(first, again)
    }

    func testEveryNodeIsInsideTheCanvasAtEveryWidth() {
        for width in widths {
            let layout = canvas(width: width)
            XCTAssertEqual(layout.size.width, min(max(width, LiveCanvasLayout.minWidth), LiveCanvasLayout.maxWidth))
            let bounds = CGRect(origin: .zero, size: layout.size)
            for node in layout.nodes {
                XCTAssertTrue(bounds.contains(node.frame), "\(node.id) at \(width): \(node.frame) in \(bounds)")
                XCTAssertGreaterThan(node.frame.width, 0)
                XCTAssertGreaterThan(node.frame.height, 0)
            }
        }
    }

    func testNoTwoNodesOverlapAtAnyWidth() {
        for width in widths {
            let nodes = canvas(fixtureThreads(), width: width, roster: [.init(id: "z1", name: "Zed"), .init(id: "z2", name: "Yan")]).nodes
            for (index, a) in nodes.enumerated() {
                for b in nodes[(index + 1)...] {
                    XCTAssertFalse(overlaps(a.frame, b.frame), "\(a.id) and \(b.id) at \(width)")
                }
            }
        }
    }

    func testOnePersonAndTwoPeopleStillFit() {
        for people in 1...2 {
            let threads = fixtureThreads().filter { ["uma", "bo"].prefix(people).contains($0.ownerPersonId) }
            let layout = canvas(threads, width: 720)
            XCTAssertEqual(layout.nodes.filter { $0.kind == .person }.count, people)
            for node in layout.nodes { XCTAssertTrue(CGRect(origin: .zero, size: layout.size).contains(node.frame)) }
        }
    }

    func testAWideWindowStopsGrowingTheCanvas() {
        XCTAssertEqual(canvas(width: 3000).size.width, LiveCanvasLayout.maxWidth)
    }

    // MARK: People and sides

    func testPeopleAlternateLeftThenRightByPersonIdAndStackDownEachSide() {
        let layout = canvas(width: 1200)
        let order = model(fixtureThreads()).groups.map(\.id).sorted()
        XCTAssertEqual(order, ["bo", "kim", "lee", "pat", "uma"])
        let people = order.map { node(layout, .person, $0) }
        XCTAssertEqual(people.map(\.side), [.left, .right, .left, .right, .left])
        let left = people.filter { $0.side == .left }.map(\.frame.minY)
        XCTAssertEqual(left, left.sorted(), "later people sit lower on their side")
        XCTAssertEqual(Set(left).count, left.count)
    }

    func testAvatarsSitAtTheOuterEdgeAndPillsBetweenThemAndTheCentre() {
        let layout = canvas(width: 1200)
        let centre = layout.nodes.filter { $0.kind == .hub }
        let centreMin = centre.map(\.frame.minX).min()!, centreMax = centre.map(\.frame.maxX).max()!
        for person in layout.nodes where person.kind == .person {
            if person.side == .left {
                XCTAssertLessThan(person.frame.minX, 10)
            } else {
                XCTAssertGreaterThan(person.frame.maxX, 1190)
            }
        }
        for pill in layout.nodes where pill.kind == .session {
            if pill.side == .left {
                XCTAssertGreaterThan(pill.frame.minX, 80)
                XCTAssertLessThan(pill.frame.maxX, centreMin)
            } else {
                XCTAssertGreaterThan(pill.frame.minX, centreMax)
                XCTAssertLessThan(pill.frame.maxX, 1120)
            }
        }
        XCTAssertTrue(centre.allSatisfy { $0.side == .center })
    }

    func testAPersonsAvatarIsCentredOnTheirPills() {
        let layout = canvas(width: 1200)
        for person in layout.nodes where person.kind == .person {
            let ids = Set(layout.trees.filter { $0.personId == person.refId }.map(\.targetId))
            let rows = layout.nodes.filter { $0.kind == .session && ids.contains($0.refId) && $0.side == person.side }
            let top = rows.map(\.frame.minY).min()!, bottom = rows.map(\.frame.maxY).max()!
            XCTAssertEqual(person.avatar.midY, (top + bottom) / 2, accuracy: 1.5, person.refId)
        }
    }

    // MARK: Determinism

    func testTheSameInputGivesTheSameLayout() {
        XCTAssertEqual(canvas(), canvas())
    }

    func testShufflingTheInputChangesNothing() {
        let threads = fixtureThreads()
        var shuffled = threads
        var generator = SeededGenerator(seed: 7)
        shuffled.shuffle(using: &generator)
        XCTAssertNotEqual(threads.map(\.sessionId), shuffled.map(\.sessionId))
        XCTAssertEqual(canvas(threads), canvas(shuffled))
        XCTAssertEqual(canvas(threads), canvas(threads.reversed()))
    }

    // MARK: The cap

    func testNamedAndUnnamedSessionsAreAllDrawn() {
        let layout = canvas()
        let ada = layout.nodes.filter { $0.kind == .session && $0.refId.hasPrefix("uma-") }
        XCTAssertEqual(ada.count, 12, "past the list's cap of \(LiveThreadsModel.perPersonCap), still drawn")
        let threads =
            (0..<3).map { thread("n\($0)", owner: "uma", minutesAgo: Double($0)) }
            + (0..<4).map { thread("u\($0)", owner: "uma", minutesAgo: Double(10 + $0), title: nil) }
        let unnamed = canvas(threads)
        XCTAssertEqual(Set(unnamed.nodes.filter { $0.kind == .session }.map(\.refId)), ["n0", "n1", "n2", "u0", "u1", "u2", "u3"])
        XCTAssertEqual(unnamed.nodes.first { $0.kind == .person }?.count, 7)
    }

    func testSessionsGroupByProjectSoTheirLinesSitTogether() {
        let threads = [
            thread("a", owner: "uma", minutesAgo: 1, projects: [("o2", "Project 2")]),
            thread("b", owner: "uma", minutesAgo: 2),
            thread("c", owner: "uma", minutesAgo: 3, projects: [("o0", "Project 0")]),
            thread("d", owner: "uma", minutesAgo: 4, projects: [("o2", "Project 2")]),
        ]
        let layout = canvas(threads)
        let column = layout.nodes.filter { $0.kind == .session }.sorted { $0.frame.minY < $1.frame.minY }.map(\.refId)
        XCTAssertEqual(column, ["a", "d", "c", "b"], "the project with the most agents first, then by session id; none last")
    }

    // MARK: Every live session is drawn (no cap, no "+N more", no person limit)

    func testFortyOneSessionsOfOnePersonAreAllDrawn() {
        let threads = (0..<41).map { thread("s\($0)", owner: "uma", minutesAgo: Double($0 % 14)) }
        let layout = canvas(threads, width: 1200)
        XCTAssertEqual(layout.nodes.filter { $0.kind == .session }.count, 41)
        XCTAssertEqual(layout.trees.count, 41, "one tree line a session and nothing else, so no chip")
        XCTAssertEqual(layout.nodes.filter { $0.kind == .person }.map(\.count), [41])
        let bounds = CGRect(origin: .zero, size: layout.size)
        for (index, a) in layout.nodes.enumerated() {
            XCTAssertTrue(bounds.contains(a.frame), a.id)
            for b in layout.nodes[(index + 1)...] { XCTAssertFalse(overlaps(a.frame, b.frame), "\(a.id) and \(b.id)") }
        }
        XCTAssertGreaterThan(layout.size.height, 41 * LiveCanvasLayout.rowStep, "the canvas grows taller instead of folding")
    }

    func testFourteenPeopleAreAllPlaced() {
        let threads = (0..<14).flatMap { person in
            (0..<2).map { thread("p\(person)-\($0)", owner: "p\(person)", minutesAgo: Double(person % 8 + $0)) }
        }
        let layout = canvas(threads, width: 1400)
        XCTAssertEqual(layout.nodes.filter { $0.kind == .person }.count, 14)
        XCTAssertEqual(layout.nodes.filter { $0.kind == .session }.count, 28)
        XCTAssertTrue(layout.nodes.contains { $0.kind == .person && $0.refId == "p13" })
        let bounds = CGRect(origin: .zero, size: layout.size)
        for (index, a) in layout.nodes.enumerated() {
            XCTAssertTrue(bounds.contains(a.frame), a.id)
            for b in layout.nodes[(index + 1)...] { XCTAssertFalse(overlaps(a.frame, b.frame), "\(a.id) and \(b.id)") }
        }
    }

    func testTheSameBigInputGivesTheSameFrames() {
        var threads: [CodingThread] = []
        for index in 0..<41 {
            threads.append(thread("s\(index)", owner: "uma", minutesAgo: Double(index % 14), title: index % 5 == 0 ? nil : "Session \(index)"))
        }
        for person in 0..<12 {
            for index in 0..<3 { threads.append(thread("q\(person)-\(index)", owner: "q\(person)", minutesAgo: Double(person + index))) }
        }
        let first = canvas(threads, width: 1300)
        let second = canvas(threads.reversed(), width: 1300)
        XCTAssertEqual(first.nodes.map { $0.frame }, second.nodes.map { $0.frame })
        XCTAssertEqual(first.nodes.map { $0.id }, second.nodes.map { $0.id })
        XCTAssertEqual(first, second)
    }

    // MARK: The centre

    func testTheMostUsedProjectsStackFromTheTopAtAFixedGapHoweverTallTheCanvas() {
        var threads: [CodingThread] = []
        for index in 0..<41 {
            threads.append(thread("s\(index)", owner: "uma", minutesAgo: Double(index % 14), projects: [("o\(index % 4)", "Project \(index % 4)")]))
        }
        threads += (0..<3).map { thread("a\($0)", owner: "bo", minutesAgo: Double($0 + 1)) }
        let layout = canvas(threads, width: 1200)
        let centre = layout.nodes.filter { $0.kind == .hub }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(centre.count, 4)
        XCTAssertLessThan(centre[0].frame.minY, 60, "the first sits at the top of a \(layout.size.height)pt canvas")
        for (a, b) in zip(centre, centre.dropFirst()) {
            XCTAssertEqual(b.frame.minY - a.frame.maxY, LiveCanvasLayout.centerGap, "a fixed gap")
        }
        XCTAssertEqual(Set(centre.map(\.frame.minX)).count, 1, "one centre column")
        XCTAssertEqual(centre[0].frame.midX, layout.size.width / 2, accuracy: 1)
        XCTAssertGreaterThan(layout.size.height - centre.last!.frame.maxY, 600, "the room below is left free")
    }

    func testAProjectCountsItsAgents() {
        let layout = canvas(
            [
                thread("a", owner: "uma", projects: [("o0", "Project 0")]), thread("b", owner: "bo", projects: [("o0", "Project 0")]),
                thread("c", owner: "bo", title: nil, projects: [("o0", "Project 0")]),
            ])
        XCTAssertEqual(node(layout, .hub, "o0").count, 2, "a session with no name is not counted")
        XCTAssertFalse(layout.nodes.contains { $0.kind == .hub && $0.refId == "o1" })
    }

    // MARK: Lines

    func testEdgesRunFromAPillsInnerEdgeToItsProjectsNearSide() {
        let layout = canvas(width: 1200)
        XCTAssertFalse(layout.edges.isEmpty)
        for edge in layout.edges {
            let pill = node(layout, .session, edge.sessionId)
            let target = node(layout, .hub, edge.targetId)
            switch edge.side {
            case .left:
                XCTAssertEqual(edge.from, pill.rightAnchor)
                XCTAssertEqual(edge.to, target.leftAnchor)
            case .right:
                XCTAssertEqual(edge.from, pill.leftAnchor)
                XCTAssertEqual(edge.to, target.rightAnchor)
            case .center:
                XCTFail("an edge always belongs to a side")
            }
            XCTAssertEqual(edge.side, pill.side)
            XCTAssertTrue(pill.linked)
        }
    }

    func testEdgesFollowTheProjectsTheListShows() {
        let threads = fixtureThreads()
        let listModel = model(threads)
        let layout = layoutNow(model: listModel, width: 1200)
        let edges = Dictionary(uniqueKeysWithValues: layout.edges.map { ($0.sessionId, $0.targetId) })
        let hubs = Set(layout.nodes.filter { $0.kind == .hub }.map(\.refId))
        for pill in layout.nodes where pill.kind == .session {
            let row = listModel.groups.flatMap { $0.named + $0.unnamed }.first { $0.id == pill.refId }!
            let projectIds = Set(row.projects.map(\.id))
            if let target = edges[row.id] {
                XCTAssertTrue(projectIds.contains(target) && hubs.contains(target), "the line ends on one of its projects")
            } else {
                XCTAssertTrue(projectIds.isDisjoint(with: hubs), "an unlinked session gets no edge")
            }
            XCTAssertEqual(pill.linked, edges[row.id] != nil)
        }
        XCTAssertTrue(edges.values.contains("o0") && edges.values.contains("o1"))
        XCTAssertFalse(hubs.contains("standing"), "the server's own project is never a hub")
    }

    func testEveryLineEndsOnANodeEdge() {
        for width in widths {
            let layout = canvas(width: width)
            let frames = layout.nodes.map(\.frame)
            func onAnEdge(_ point: CGPoint) -> Bool {
                frames.contains { frame in
                    let inside = frame.insetBy(dx: -0.01, dy: -0.01).contains(point)
                    let onSide = abs(point.x - frame.minX) < 0.01 || abs(point.x - frame.maxX) < 0.01
                    return inside && onSide
                }
            }
            for edge in layout.edges {
                XCTAssertTrue(onAnEdge(edge.from) && onAnEdge(edge.to), "edge \(edge.id) at \(width)")
            }
            for tree in layout.trees {
                XCTAssertTrue(onAnEdge(tree.to), "tree \(tree.id) at \(width)")
                let person = node(layout, .person, tree.personId)
                let avatar = person.avatar
                XCTAssertEqual(tree.from.y, avatar.midY, accuracy: 0.01)
                XCTAssertEqual(tree.from.x, tree.side == .left ? avatar.maxX : avatar.minX, accuracy: 0.01)
            }
        }
    }

    func testEveryPillHasATreeFromItsPerson() {
        let layout = canvas()
        for pill in layout.nodes where pill.kind == .session {
            let trees = layout.trees.filter { $0.targetId == pill.refId }
            XCTAssertEqual(trees.count, 1, pill.id)
        }
        for tree in layout.trees {
            let target = layout.nodes.first { $0.kind == .session && $0.refId == tree.targetId }
            XCTAssertNotNil(target)
            XCTAssertEqual(tree.side, target?.side)
        }
    }

    func testOnlyAnActiveSessionsLinesAreMarkedToFlow() {
        // Fresh is under ten minutes (the filled green dot); the ring (10 to 15 minutes, the
        // most the canvas draws) is not flowing.
        let threads = [
            thread("fresh", owner: "uma", minutesAgo: 2, projects: [("o0", "Project 0")]),
            thread("recent", owner: "uma", minutesAgo: 12, projects: [("o0", "Project 0")]),
            thread("other", owner: "uma", minutesAgo: 13, projects: [("o1", "Project 1")]),
        ]
        let layout = canvas(threads)
        XCTAssertEqual(Set(layout.nodes.filter { $0.kind == .session && $0.isActive }.map(\.refId)), ["fresh"])
        XCTAssertEqual(layout.edges.filter(\.isActive).map(\.sessionId), ["fresh"])
        XCTAssertEqual(layout.edges.count, 3)
        XCTAssertEqual(layout.trees.filter(\.isActive).map(\.targetId), ["fresh"])
        XCTAssertEqual(layout.trees.count, 3)
    }

    func testActiveFlagsFollowTheListsAgeMark() {
        let listModel = model(fixtureThreads())
        let layout = layoutNow(model: listModel, width: 1200)
        let rows = Dictionary(uniqueKeysWithValues: listModel.groups.flatMap { $0.named + $0.unnamed }.map { ($0.id, $0) })
        for pill in layout.nodes where pill.kind == .session {
            XCTAssertEqual(pill.isActive, rows[pill.refId]?.age == .fresh, pill.refId)
        }
    }

    // MARK: The camera (zoom and pan arithmetic)

    private let content = CGSize(width: 1000, height: 3000)
    private let viewport = CGSize(width: 1000, height: 700)

    func testTheCameraOpensFittedToTheWidthAtTheTop() {
        let fit = LiveCanvasCamera.fit(content: content, viewport: viewport)
        XCTAssertEqual(fit, LiveCanvasCamera(scale: 1, offset: .zero, followsFit: true))
        // A window wider than the capped canvas centres it at 1:1.
        let wide = LiveCanvasCamera.fit(content: CGSize(width: 1600, height: 900), viewport: CGSize(width: 2000, height: 800))
        XCTAssertEqual(wide.scale, 1)
        XCTAssertEqual(wide.offset.x, 200)
        XCTAssertEqual(wide.offset.y, 0)
    }

    func testTheCameraComesBackFromAThreadWhereItWasLeft() {
        // The board is rebuilt when a thread opens; `LiveThreadsStore` above it holds the camera,
        // and the viewport opens at it. With nothing held it opens fitted.
        let fit = LiveCanvasCamera.opening(saved: nil, content: content, viewport: viewport)
        XCTAssertEqual(fit, LiveCanvasCamera.fit(content: content, viewport: viewport))
        let left = LiveCanvasCamera(scale: 1.8, offset: CGPoint(x: -300, y: -900))
        XCTAssertEqual(LiveCanvasCamera.opening(saved: left, content: content, viewport: viewport), left)
    }

    func testASavedCameraIsClampedToTheWindowItComesBackIn() {
        let far = LiveCanvasCamera(scale: 2, offset: CGPoint(x: -99_999, y: 99_999))
        let opened = LiveCanvasCamera.opening(saved: far, content: content, viewport: viewport)
        XCTAssertEqual(opened.scale, 2)
        XCTAssertEqual(opened.offset.x, LiveCanvasCamera.keepVisible - content.width * 2, "80pt of the right edge stay in view")
        XCTAssertEqual(opened.offset.y, viewport.height - LiveCanvasCamera.keepVisible, "80pt of the top stay in view")
        XCTAssertEqual(opened, far.clamped(content: content, viewport: viewport))
    }

    func testZoomingKeepsThePointUnderTheAnchorStill() {
        let start = LiveCanvasCamera(scale: 1, offset: CGPoint(x: -120, y: -300))
        let anchor = CGPoint(x: 400, y: 250)
        let before = CGPoint(x: (anchor.x - start.offset.x) / start.scale, y: (anchor.y - start.offset.y) / start.scale)
        for target in [0.5, 1.7, 2.5] as [CGFloat] {
            let zoomed = start.zoomed(to: target, around: anchor)
            let after = CGPoint(x: (anchor.x - zoomed.offset.x) / zoomed.scale, y: (anchor.y - zoomed.offset.y) / zoomed.scale)
            XCTAssertEqual(after.x, before.x, accuracy: 0.001)
            XCTAssertEqual(after.y, before.y, accuracy: 0.001)
        }
    }

    func testZoomStaysBetweenFortyAndTwoHundredFiftyPercent() {
        let camera = LiveCanvasCamera()
        XCTAssertEqual(camera.zoomed(to: 0.01, around: .zero).scale, 0.4)
        XCTAssertEqual(camera.zoomed(to: 40, around: .zero).scale, 2.5)
        XCTAssertFalse(camera.zoomed(to: 0.01, around: .zero).canZoomOut)
        XCTAssertFalse(camera.zoomed(to: 40, around: .zero).canZoomIn)
        XCTAssertTrue(camera.canZoomIn && camera.canZoomOut)
        XCTAssertEqual(camera.zoomed(to: 1.25, around: .zero).zoomed(to: 1.25 / LiveCanvasCamera.step, around: .zero).scale, 1, accuracy: 0.0001)
    }

    // A narrow window: the canvas is laid out at 720pt and the card is narrower.

    func testANarrowViewportOpensFittedToItsWidthAtTheTop() {
        let canvas = CGSize(width: LiveCanvasLayout.minWidth, height: 3000)
        for width in [600, 480, 360, 240] as [CGFloat] {
            let fit = LiveCanvasCamera.fit(content: canvas, viewport: CGSize(width: width, height: 700))
            XCTAssertEqual(fit.scale, width / LiveCanvasLayout.minWidth, accuracy: 0.0001, "fit scale at \(width)")
            XCTAssertEqual(fit.offset, .zero, "the scaled canvas fills the width exactly")
            let scaled = canvas.width * fit.scale
            XCTAssertEqual(scaled, width, accuracy: 0.001)
        }
    }

    func testTheMinimumZoomFollowsTheFitWhenTheFitIsBelowForty() {
        let canvas = CGSize(width: LiveCanvasLayout.minWidth, height: 3000)
        // 240 / 720 = 33%: below the usual 40% floor, so fit and zoom out reach it.
        let small = LiveCanvasCamera.fit(content: canvas, viewport: CGSize(width: 240, height: 700))
        XCTAssertEqual(small.scale, 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(small.zoomed(to: 0.01, around: .zero).scale, small.scale, accuracy: 0.0001, "cannot go below the fit")
        XCTAssertFalse(small.canZoomOut, "already at the floor")
        XCTAssertTrue(small.canZoomIn)
        XCTAssertEqual(small.clamped(content: canvas, viewport: CGSize(width: 240, height: 700)), small, "the fit is a camera that stays")
        // It can still move up from there and come back to the fit.
        let up = small.zoomed(to: small.scale * LiveCanvasCamera.step, around: .zero)
        XCTAssertTrue(up.canZoomOut)
        XCTAssertEqual(up.zoomed(to: 0.01, around: .zero).scale, small.scale, accuracy: 0.0001)
    }

    func testTheMinimumZoomStaysFortyPercentWhenTheFitIsAboveIt() {
        let canvas = CGSize(width: LiveCanvasLayout.minWidth, height: 3000)
        for width in [720, 480, 360, 288] as [CGFloat] {
            let fit = LiveCanvasCamera.fit(content: canvas, viewport: CGSize(width: width, height: 700))
            XCTAssertEqual(fit.zoomed(to: 0.01, around: .zero).scale, min(0.4, fit.scale), accuracy: 0.0001, "\(width)")
            XCTAssertEqual(fit.zoomed(to: 0.01, around: .zero).scale, 0.4, accuracy: 0.0001, "\(width): 40% is at most the fit")
        }
        // A saved camera on a window that is wide again is held to 40%.
        let was = LiveCanvasCamera.fit(content: canvas, viewport: CGSize(width: 240, height: 700))
        XCTAssertEqual(was.clamped(content: canvas, viewport: CGSize(width: 900, height: 700)).scale, 0.4, accuracy: 0.0001)
    }

    // A camera at the fit follows it, scrolled or not: only the width decides.

    /// The canvas as it is laid out for a card of this width, and the viewport that card makes.
    private func cardFor(_ width: CGFloat, height: CGFloat = 700) -> (content: CGSize, viewport: CGSize) {
        (CGSize(width: max(width, LiveCanvasLayout.minWidth), height: 2400), CGSize(width: width, height: height))
    }

    /// The camera as the viewport leaves it after a two-finger scroll of `down` points at the fit.
    private func scrolled(_ width: CGFloat, by down: CGFloat) -> LiveCanvasCamera {
        let (content, viewport) = cardFor(width)
        return LiveCanvasCamera.fit(content: content, viewport: viewport)
            .panned(by: CGSize(width: 0, height: -down)).clamped(content: content, viewport: viewport)
    }

    func testAScrolledCameraAtTheFitStillFitsTheWidthWhenItComesBackWide() {
        let saved = scrolled(460, by: 200)
        let (content, viewport) = cardFor(1160)
        let opened = LiveCanvasCamera.opening(saved: saved, content: content, viewport: viewport)
        XCTAssertEqual(opened.scale, 1, accuracy: 0.0001, "the 460pt card's 64% is not carried into 1160pt")
        XCTAssertEqual(opened.offset.x, 0, accuracy: 0.5)
        XCTAssertLessThan(opened.offset.y, 0, "still scrolled down")
    }

    func testAScrolledCameraAtTheFitStillFitsTheWidthWhenItComesBackNarrow() {
        let saved = scrolled(1160, by: 300)
        let (content, viewport) = cardFor(460)
        let opened = LiveCanvasCamera.opening(saved: saved, content: content, viewport: viewport)
        XCTAssertEqual(opened.scale, 460 / LiveCanvasLayout.minWidth, accuracy: 0.0001, "the 720pt canvas is not cut off at 1:1")
        XCTAssertEqual(opened.offset.x, 0, accuracy: 0.5)
    }

    func testScrollingDownDoesNotStopACameraFollowingTheFit() {
        let (content, viewport) = cardFor(460)
        let fit = LiveCanvasCamera.fit(content: content, viewport: viewport)
        XCTAssertTrue(fit.followsFit)
        let down = scrolled(460, by: 200)
        XCTAssertTrue(down.followsFit, "scrolled down, still the fit's width")
        XCTAssertEqual(down.offset.y, -200)
        XCTAssertNotEqual(down, fit, "the Fit button still has somewhere to go back to")
        XCTAssertTrue(down.panned(by: CGSize(width: 0, height: 200)).clamped(content: content, viewport: viewport) == fit)
    }

    func testZoomingOrPanningSidewaysStopsACameraFollowingTheFit() {
        let (content, viewport) = cardFor(460)
        let fit = LiveCanvasCamera.fit(content: content, viewport: viewport)
        let zoomed = fit.zoomed(to: fit.scale * 1.25, around: .zero).clamped(content: content, viewport: viewport)
        XCTAssertFalse(zoomed.followsFit)
        XCTAssertTrue(zoomed.zoomed(to: fit.scale, around: .zero).clamped(content: content, viewport: viewport).followsFit, "back at the fit width")
        XCTAssertFalse(fit.panned(by: CGSize(width: 30, height: 0)).clamped(content: content, viewport: viewport).followsFit)
    }

    func testAFollowingCameraKeepsItsHeightAcrossAResizeAndBack() {
        let narrow = cardFor(460), wide = cardFor(1160)
        let start = scrolled(460, by: 200)
        let scale = 460 / LiveCanvasLayout.minWidth
        // Wider: 1:1, the canvas starts at the left edge, still looking at the same height of it.
        let grown = start.resized(content: wide.content, viewport: wide.viewport)
        XCTAssertEqual(grown.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(grown.offset.x, 0, accuracy: 0.001)
        XCTAssertEqual(grown.offset.y, -200 / scale, accuracy: 0.001)
        XCTAssertTrue(grown.followsFit)
        // Narrower again: back to the card's fit, at the height it came from.
        let shrunk = grown.resized(content: narrow.content, viewport: narrow.viewport)
        XCTAssertEqual(shrunk.scale, scale, accuracy: 0.0001)
        XCTAssertEqual(shrunk.offset.x, 0, accuracy: 0.001)
        XCTAssertEqual(shrunk.offset.y, -200, accuracy: 0.001)
        XCTAssertTrue(shrunk.followsFit)
        // The canvas fills the card's width and never runs past it.
        XCTAssertEqual(narrow.content.width * shrunk.scale, narrow.viewport.width, accuracy: 0.001)
    }

    func testAFollowingCameraFollowsThroughTheSmallerWidths() {
        // Scrolled at 600, window narrowed to 400: the 720pt canvas still fills the card.
        let was = scrolled(600, by: 200)
        let (content, viewport) = cardFor(400)
        let now = was.resized(content: content, viewport: viewport)
        XCTAssertEqual(now.scale, 400 / LiveCanvasLayout.minWidth, accuracy: 0.0001)
        XCTAssertEqual(content.width * now.scale, 400, accuracy: 0.001)
    }

    func testAFollowingCameraKeepsFollowingWhenTheCanvasChangesAtTheSameWidth() {
        let (content, viewport) = cardFor(460)
        let taller = CGSize(width: content.width, height: content.height + 900)
        let now = scrolled(460, by: 200).resized(content: taller, viewport: viewport)
        XCTAssertEqual(now, scrolled(460, by: 200), "a taller canvas at the same width changes nothing")
    }

    func testACameraTheCardZoomedItselfIsNotRefitted() {
        let (content, viewport) = cardFor(460)
        let own = LiveCanvasCamera(scale: 1.5, offset: CGPoint(x: -100, y: -400))
        let wide = cardFor(1160)
        XCTAssertFalse(own.clamped(content: content, viewport: viewport).followsFit)
        XCTAssertEqual(own.resized(content: wide.content, viewport: wide.viewport).scale, 1.5, "their zoom, kept")
        XCTAssertEqual(own.resized(content: content, viewport: viewport), own.clamped(content: content, viewport: viewport))
    }

    func testOnlyTheExactFitIsHeldAsNothingSaved() {
        let (content, viewport) = cardFor(460)
        XCTAssertNil(LiveCanvasCamera.fit(content: content, viewport: viewport).kept(content: content, viewport: viewport))
        let down = scrolled(460, by: 200)
        XCTAssertEqual(down.kept(content: content, viewport: viewport), down, "a scrolled fit is kept, flag and all")
    }

    func testTheCardTakesTheWholeSpaceEvenPastTheCanvas() {
        let canvas = CGSize(width: 1600, height: 3000)
        XCTAssertEqual(LiveCanvasCamera.cardWidth(content: canvas, space: 360), 360)
        XCTAssertEqual(LiveCanvasCamera.cardWidth(content: canvas, space: 1600), 1600)
        XCTAssertEqual(LiveCanvasCamera.cardWidth(content: canvas, space: 2200), 2200, "a window past the widest layout still fills")
        XCTAssertEqual(LiveCanvasCamera.cardWidth(content: canvas, space: 0), 1600, "nothing measured yet: the canvas's own width")
        let fit = LiveCanvasCamera.fit(content: canvas, viewport: CGSize(width: 2200, height: 900))
        XCTAssertEqual(fit.scale, 1, "the drawing stays at 100% in the wider card")
        XCTAssertEqual(fit.offset, CGPoint(x: 300, y: 0), "centred, at the top")
    }

    // The window's gutter: a window from 720pt up is 1:1. The card's height (900 below) never
    // moves the fit, which reads only the width.

    func testTheCanvasStaysOneToOneInAWindowFromTheFloorUp() {
        let gutter: CGFloat = 20
        for window in 720...760 {
            let width = CGFloat(window)
            let inset = LiveCanvasLayout.stageInset(windowWidth: width, gutter: gutter)
            let space = width - 2 * inset
            XCTAssertGreaterThanOrEqual(space, LiveCanvasLayout.minWidth, "window \(window)")
            let content = CGSize(width: min(max(space, LiveCanvasLayout.minWidth), LiveCanvasLayout.maxWidth), height: 2000)
            let fit = LiveCanvasCamera.fit(content: content, viewport: CGSize(width: LiveCanvasCamera.cardWidth(content: content, space: space), height: 900))
            XCTAssertEqual(fit.scale, 1, accuracy: 0.0001, "window \(window) is shown at 100%")
        }
        XCTAssertEqual(LiveCanvasLayout.stageInset(windowWidth: 760, gutter: gutter), gutter)
        XCTAssertEqual(LiveCanvasLayout.stageInset(windowWidth: 1200, gutter: gutter), gutter, "wide windows keep the gutter")
    }

    func testAWindowUnderTheFloorKeepsTheGutterAndScalesTheCanvasToWhatIsLeft() {
        let gutter: CGFloat = 20
        for window in [719, 600, 460, 300] as [CGFloat] {
            let inset = LiveCanvasLayout.stageInset(windowWidth: window, gutter: gutter)
            XCTAssertEqual(inset, gutter, "window \(window)")
            let space = window - 2 * inset
            let content = CGSize(width: LiveCanvasLayout.minWidth, height: 2000)
            let fit = LiveCanvasCamera.fit(content: content, viewport: CGSize(width: LiveCanvasCamera.cardWidth(content: content, space: space), height: 900))
            XCTAssertEqual(fit.scale, space / LiveCanvasLayout.minWidth, accuracy: 0.0001)
        }
    }

    func testTheCanvasChoiceIsOfferedAtEveryWidthButNotOnAnIPhoneOrUnderVoiceOver() {
        XCTAssertTrue(LiveCanvasLayout.isOffered(voiceOver: false, isPhone: false), "a narrow Mac window or an iPad split view")
        XCTAssertFalse(LiveCanvasLayout.isOffered(voiceOver: true, isPhone: false))
        XCTAssertFalse(LiveCanvasLayout.isOffered(voiceOver: false, isPhone: true))
        XCTAssertFalse(LiveCanvasLayout.isOffered(voiceOver: true, isPhone: true))
    }

    func testPanningKeepsTheCanvasReachableAndTheBottomWithinReach() {
        let up = LiveCanvasCamera().panned(by: CGSize(width: 0, height: -99_999)).clamped(content: content, viewport: viewport)
        XCTAssertEqual(up.offset.y, LiveCanvasCamera.keepVisible - content.height, "the bottom 80pt can still be brought up")
        let down = LiveCanvasCamera().panned(by: CGSize(width: 0, height: 99_999)).clamped(content: content, viewport: viewport)
        XCTAssertEqual(down.offset.y, viewport.height - LiveCanvasCamera.keepVisible)
        let sideways = LiveCanvasCamera(scale: 2, offset: .zero).panned(by: CGSize(width: -99_999, height: 0)).clamped(content: content, viewport: viewport)
        XCTAssertEqual(sideways.offset.x, LiveCanvasCamera.keepVisible - content.width * 2)
    }

    func testACanvasSmallerThanTheViewportCanSitAnywhereWithEightyPointsInIt() {
        let small = CGSize(width: 400, height: 200)
        let zoomedOut = LiveCanvasCamera(scale: 0.5, offset: .zero)
        let far = zoomedOut.panned(by: CGSize(width: 99_999, height: 99_999)).clamped(content: small, viewport: viewport)
        XCTAssertEqual(far.offset.x, viewport.width - LiveCanvasCamera.keepVisible)
        XCTAssertEqual(far.offset.y, viewport.height - LiveCanvasCamera.keepVisible)
        XCTAssertEqual(zoomedOut.clamped(content: small, viewport: viewport), zoomedOut, "where it already is, it stays")
    }

    // MARK: Projects in the centre

    private func projectThreads() -> [CodingThread] {
        [
            thread("a", owner: "uma", minutesAgo: 1, projects: [("p1", "Image fleet")]),
            thread("b", owner: "uma", minutesAgo: 2, projects: [("p1", "Image fleet"), ("p2", "Onboarding")]),
            thread("c", owner: "bo", minutesAgo: 3, projects: [("p2", "Onboarding")]),
            thread("d", owner: "bo", minutesAgo: 4, projects: [("standing", "Standing")]),
            thread("e", owner: "pat", minutesAgo: 5, projects: [("p3", "Blog")]),
            thread("f", owner: "pat", minutesAgo: 6),
        ]
    }

    func testTheCentreHoldsTheProjectsAgentsAreOn() {
        let layout = canvas(projectThreads())
        XCTAssertTrue(layout.usesHubs)
        let hubs = layout.nodes.filter { $0.kind == .hub }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(hubs.map(\.refId), ["p1", "p2", "p3"], "most agents first, then by name")
        XCTAssertEqual(hubs.map(\.count), [2, 2, 1])
        XCTAssertNotNil(layout.hubCaptionCenter)
        XCTAssertEqual(LiveCanvasLayout.hubCaption, "Projects")
        let captionY = layout.hubCaptionCenter!.y
        XCTAssertTrue(hubs.allSatisfy { $0.frame.minY > captionY })
        XCTAssertEqual(layout.edges.count, 4, "a, b, c and e each reach a project")
        XCTAssertEqual(Set(layout.edges.map(\.targetId)), ["p1", "p2", "p3"])
    }

    func testTheCentreNeverUsesTheServersOwnProjects() {
        let layout = canvas(projectThreads())
        let ids = Set(layout.nodes.filter { $0.kind == .hub }.map(\.refId))
        XCTAssertFalse(ids.contains("standing"))
        // A project the app knows as the server's own, by id, is left out whatever its name.
        XCTAssertFalse(canvas(projectThreads(), systemProjectIds: ["standing", "p1"]).nodes.contains { $0.kind == .hub && $0.refId == "p1" })
        // A name alone makes nothing a system project.
        XCTAssertTrue(canvas(projectThreads(), systemProjectIds: []).nodes.contains { $0.kind == .hub && $0.refId == "standing" })
    }

    func testTheCentreStopsAtFiveProjects() {
        let threads = (0..<8).map { thread("s\($0)", owner: "uma", minutesAgo: Double($0 + 1), projects: [("p\($0)", "Project \($0)")]) }
        let layout = canvas(threads)
        XCTAssertEqual(layout.nodes.filter { $0.kind == .hub }.count, 5)
        XCTAssertEqual(layout.edges.count, 5, "a project past the fifth draws no line")
    }

    func testAProjectNoDrawnAgentIsOnIsNotAHub() {
        let layout = canvas([thread("a", owner: "uma", title: nil, projects: [("p9", "Unnamed only")])])
        XCTAssertFalse(layout.usesHubs)
        XCTAssertNil(layout.hubCaptionCenter)
    }

    // MARK: Overlap

    private let shared = ("t9", "HQ-\(900)", "Ship the thing")

    func testTwoPeopleOnTheSameRealTaskAreJoinedByAnArcOverTheTop() {
        let layout = canvas(
            [
                // By person id bo is left, bob right and pat left again.
                thread("1", owner: "bo", minutesAgo: 1, tasks: [shared]), thread("2", owner: "bob", minutesAgo: 2, tasks: [shared]),
                thread("3", owner: "pat", minutesAgo: 3, tasks: [("t10", "HQ-\(901)", "Else")]),
            ])
        XCTAssertEqual(layout.overlaps.count, 1)
        let arc = layout.overlaps[0]
        XCTAssertEqual(arc.taskId, "t9")
        XCTAssertEqual(Set(arc.sessionIds), ["1", "2"])
        let a = node(layout, .session, "1"), b = node(layout, .session, "2")
        XCTAssertNotEqual(a.side, b.side)
        let (left, right) = a.side == .left ? (a, b) : (b, a)
        XCTAssertEqual(arc.from, left.rightAnchor)
        XCTAssertEqual(arc.to, right.leftAnchor)
        XCTAssertLessThan(arc.control1.y, arc.from.y, "it rises over the top")
        // No label: the band above the pills holds only the arcs.
        XCTAssertLessThanOrEqual(layout.nodes.map(\.frame.minY).min()!, 26, "no label row pushes the pills down")
    }

    func testOnePersonOnATaskTwiceNeverMakesAnArc() {
        let layout = canvas([
            thread("1", owner: "uma", minutesAgo: 1, tasks: [shared]),
            thread("2", owner: "uma", minutesAgo: 2, tasks: [shared]),
        ])
        XCTAssertTrue(layout.overlaps.isEmpty)
    }

    func testAnArcReachesASessionPastTheListsCap() {
        let bo = (0..<9).map { thread("a\($0)", owner: "bo", minutesAgo: Double($0 + 2), tasks: $0 == 8 ? [shared] : []) }
        let layout = canvas([thread("1", owner: "uma", minutesAgo: 1, tasks: [shared])] + bo)
        XCTAssertEqual(layout.overlaps.map(\.taskId), ["t9"])
        XCTAssertEqual(Set(layout.overlaps[0].sessionIds), ["1", "a8"])
    }

    func testAtMostThreeArcsAndEachPeaksInItsOwnLane() {
        var threads: [CodingThread] = []
        for task in 0..<5 {
            let ref = ("t\(task)", "HQ-\(100 + task)", "Task \(task)")
            threads.append(thread("s\(task)", owner: "uma", minutesAgo: Double(task + 1), tasks: [ref]))
            threads.append(thread("a\(task)", owner: "bo", minutesAgo: Double(task + 1), tasks: [ref]))
        }
        let layout = canvas(threads)
        XCTAssertEqual(layout.overlaps.count, LiveCanvasLayout.maxOverlaps)
        let peaks = layout.overlaps.map { min($0.control1.y, $0.control2.y) }
        XCTAssertEqual(Set(peaks).count, 3, "each arc has its own lane")
    }

    // MARK: The idle row

    func testPeopleWithNoAgentsStandInARowAtTheBottom() {
        let roster: [LiveThreadsModel.Idle] = [.init(id: "zed", name: "Zed"), .init(id: "yan", name: "Yan"), .init(id: "uma", name: "Uma")]
        let layout = canvas(roster: roster)
        let idle = layout.nodes.filter { $0.kind == .idle }
        XCTAssertEqual(Set(idle.map(\.refId)), ["zed", "yan"], "Uma has agents, so is not idle")
        let others = layout.nodes.filter { $0.kind != .idle }
        XCTAssertGreaterThan(idle.map(\.frame.minY).min()!, others.map(\.frame.maxY).max()!)
        XCTAssertEqual(Set(idle.map(\.frame.minY)).count, 1, "one row")
        XCTAssertEqual(idle.sorted { $0.frame.minX < $1.frame.minX }.map(\.refId), ["yan", "zed"], "by name")
    }

    func testNoIdlePeopleNoIdleRow() {
        let layout = canvas()
        XCTAssertTrue(layout.nodes.filter { $0.kind == .idle }.isEmpty)
    }

    func testAPersonWithOnlyEarlierSessionsIsIdle() {
        let layout = canvas([
            thread("a", owner: "uma"), thread("old", owner: "pat", minutesAgo: 400), thread("gone", owner: "kim", state: "ended"),
        ])
        XCTAssertEqual(Set(layout.nodes.filter { $0.kind == .idle }.map(\.refId)), ["pat", "kim"])
        XCTAssertEqual(layout.nodes.filter { $0.kind == .person }.map(\.refId), ["uma"])
    }

    func testAManyIdlePeopleWrapIntoRowsInsideTheCanvas() {
        let roster = (0..<40).map { LiveThreadsModel.Idle(id: "i\($0)", name: "Person \($0)") }
        let layout = canvas(width: 720, roster: roster)
        XCTAssertGreaterThan(Set(layout.nodes.filter { $0.kind == .idle }.map(\.frame.minY)).count, 1)
        for node in layout.nodes { XCTAssertTrue(CGRect(origin: .zero, size: layout.size).contains(node.frame)) }
    }

    // MARK: Parity with the list

    func testTheCanvasHoldsTheListsLiveSetLessWhatIsNotActiveNow() {
        let threads = fixtureThreads() + [
            thread("old", owner: "uma", minutesAgo: 300, title: "Older today"), thread("done", owner: "uma", minutesAgo: 5, title: "Ended", state: "ended"),
            thread("quiet", owner: "uma", minutesAgo: 90, title: "Quiet for an hour and a half"),
        ]
        let listModel = model(threads)
        let layout = layoutNow(model: listModel, width: 1200)
        let onCanvas = Set(layout.nodes.filter { $0.kind == .session }.map(\.refId))
        XCTAssertFalse(onCanvas.contains("old"))
        XCTAssertFalse(onCanvas.contains("done"))
        var inList = Set<String>()
        for group in listModel.groups {
            for case .row(let row) in listModel.items(group, expanded: Set([LiveThreadsModel.moreKey(group.id), LiveThreadsModel.foldedKey(group.id)]))
            where !group.earlier.contains(where: { $0.id == row.id }) {
                inList.insert(row.id)
            }
        }
        XCTAssertEqual(onCanvas.union(["quiet"]), inList, "the list with every fold opened, plus the one quiet for 90 minutes")
        for person in layout.nodes where person.kind == .person {
            let listed = listModel.groups.first { $0.id == person.refId }?.agentCount
            XCTAssertEqual(person.count, person.refId == "uma" ? listed.map { $0 - 1 } : listed, "the pills drawn")
        }
        XCTAssertEqual(LiveCanvasLayout.activeCount(model: listModel, now: now), onCanvas.count)
    }

    func testPeopleRunInPersonIdOrderNotTheListsRecencyOrder() {
        let listModel = model(fixtureThreads())
        let layout = layoutNow(model: listModel, width: 1200)
        XCTAssertEqual(layout.nodes.filter { $0.kind == .person }.map(\.refId), listModel.groups.map(\.id).sorted())
    }

    func testASearchKeepsOnlyTheMatchingSessions() {
        let threads = [
            thread("a", owner: "uma", title: "Fix the importer"), thread("b", owner: "uma", title: "Write the blog"),
            thread("c", owner: "bo", title: "Blog images"),
        ]
        let layout = layoutNow(model: model(threads, search: "blog"), width: 1200)
        XCTAssertEqual(Set(layout.nodes.filter { $0.kind == .session }.map(\.refId)), ["b", "c"])
    }

    /// A keystroke in the search never flips anyone to the other side: sides come from the whole
    /// roster, not from whose rows the search left.
    func testASearchThatHidesOnePersonKeepsEveryoneElsesSideAndPlace() {
        let threads = [
            thread("a1", owner: "bo", title: "Fix the importer"), thread("b1", owner: "bob", title: "Fix the blog"),
            thread("c1", owner: "carl", title: "Write the docs"), thread("d1", owner: "dave", title: "Fix the tests"),
        ]
        let roster = ["bo", "bob", "carl", "dave", "eve"].map { LiveThreadsModel.Idle(id: $0, name: $0.capitalized) }
        let all = layoutNow(model: model(threads, roster: roster), width: 1200)
        let searched = layoutNow(model: model(threads, search: "fix", roster: roster), width: 1200)
        XCTAssertNil(searched.nodes.first { $0.kind == .person && $0.refId == "carl" }, "the search hides Carl")
        XCTAssertEqual(["bo", "bob", "carl", "dave"].map { node(all, .person, $0).side }, [.left, .right, .left, .right])
        for (person, pill) in [("bo", "a1"), ("bob", "b1"), ("dave", "d1")] {
            XCTAssertEqual(node(searched, .person, person).side, node(all, .person, person).side, person)
            XCTAssertEqual(node(searched, .person, person).frame, node(all, .person, person).frame, person)
            XCTAssertEqual(node(searched, .session, pill).frame, node(all, .session, pill).frame, pill)
        }
    }

    // MARK: Empty

    func testNothingLiveIsAnEmptyLayout() {
        let layout = layoutNow(model: model([]), width: 1200)
        XCTAssertTrue(layout.nodes.isEmpty)
        XCTAssertTrue(layout.edges.isEmpty)
    }

    // MARK: Stable places

    /// Pins for the tests: key -> (x fraction of the width, y).
    private func pinned(_ entries: [String: (Double, Double)]) -> LiveCanvasPositions {
        var pins = LiveCanvasPositions()
        for (key, place) in entries { pins.set(key, xFraction: place.0, y: place.1, at: now) }
        return pins
    }

    private func mid(_ node: LiveCanvasLayout.Node) -> CGPoint { CGPoint(x: node.frame.midX, y: node.frame.midY) }

    /// (a) Whose activity is newest decides nothing: no side and no place moves.
    func testSwappingTwoPeoplesLatestActivityMovesNoOne() {
        func threads(ada: Double, bo: Double) -> [CodingThread] {
            [
                thread("uma-1", owner: "uma", minutesAgo: ada, projects: [("o1", "Project 1")]),
                thread("uma-2", owner: "uma", minutesAgo: ada + 2),
                thread("bo-1", owner: "bo", minutesAgo: bo, projects: [("o0", "Project 0")]),
                thread("bo-2", owner: "bo", minutesAgo: bo + 3, projects: [("o1", "Project 1")]),
                thread("pat-1", owner: "pat", minutesAgo: 6),
            ]
        }
        let before = canvas(threads(ada: 1, bo: 8)), after = canvas(threads(ada: 8, bo: 1))
        XCTAssertEqual(model(threads(ada: 1, bo: 8)).groups.map(\.id).first, "uma", "uma was the most recent")
        XCTAssertEqual(model(threads(ada: 8, bo: 1)).groups.map(\.id).first, "bo", "now bo is")
        XCTAssertEqual(before.nodes.map(\.id), after.nodes.map(\.id))
        XCTAssertEqual(before.nodes.map(\.frame), after.nodes.map(\.frame), "same sides, same y positions")
        XCTAssertEqual(before.nodes.map(\.side), after.nodes.map(\.side))
        XCTAssertEqual(before.size, after.size)
        XCTAssertEqual(["bo", "pat", "uma"].map { node(before, .person, $0).side }, [.left, .right, .left])
    }

    /// A person's sides do not depend on who else is active: idle people hold their place in the order.
    func testASideDoesNotDependOnWhoElseIsActive() {
        let roster: [LiveThreadsModel.Idle] = [.init(id: "bob", name: "Bob")]
        let both = canvas(
            [thread("a", owner: "bo"), thread("c", owner: "carl")], roster: roster)
        let bobBusy = canvas(
            [thread("a", owner: "bo"), thread("b", owner: "bob"), thread("c", owner: "carl")], roster: roster)
        XCTAssertEqual(node(both, .person, "carl").side, node(bobBusy, .person, "carl").side)
        XCTAssertEqual(node(both, .person, "carl").side, .left, "bo, bob, carl: carl is third")
    }

    func testAPersonsPillsRunByProjectThenSessionIdNeverByRecency() {
        let threads = [
            thread("z", owner: "uma", minutesAgo: 1),
            thread("b", owner: "uma", minutesAgo: 9, projects: [("o1", "Project 1")]),
            thread("a", owner: "uma", minutesAgo: 5, projects: [("o1", "Project 1")]),
            thread("c", owner: "uma", minutesAgo: 3, projects: [("o0", "Project 0")]),
        ]
        let column = canvas(threads).nodes.filter { $0.kind == .session }.sorted { $0.frame.minY < $1.frame.minY }.map(\.refId)
        XCTAssertEqual(column, ["a", "b", "c", "z"], "the project with the most agents first, then the next, then none")
    }

    /// (b) The canvas draws what is active now; the list keeps its three hours.
    func testASessionTwentyMinutesOldIsNotDrawnAndItsOnlyPersonIsIdle() {
        let layout = canvas([thread("old", owner: "uma", minutesAgo: 20), thread("new", owner: "pat", minutesAgo: 5)])
        XCTAssertEqual(layout.nodes.filter { $0.kind == .session }.map(\.refId), ["new"])
        XCTAssertEqual(layout.nodes.filter { $0.kind == .person }.map(\.refId), ["pat"])
        XCTAssertEqual(layout.nodes.filter { $0.kind == .idle }.map(\.refId), ["uma"])
        XCTAssertEqual(LiveCanvasLayout.activeMinutes, 15)
        let edge = canvas([thread("in", owner: "a", minutesAgo: 15), thread("out", owner: "b", minutesAgo: 15.5)])
        XCTAssertEqual(edge.nodes.filter { $0.kind == .session }.map(\.refId), ["in"])
    }

    func testWhenNoOneIsActiveTheCanvasIsOnlyTheIdleRow() {
        let layout = canvas([thread("old", owner: "uma", minutesAgo: 60)])
        XCTAssertEqual(layout.nodes.map(\.kind), [.idle])
        XCTAssertGreaterThan(layout.size.height, 0)
        for node in layout.nodes { XCTAssertTrue(CGRect(origin: .zero, size: layout.size).contains(node.frame), node.id) }
        XCTAssertEqual(LiveCanvasLayout.activeCount(model: model([thread("old", owner: "uma", minutesAgo: 60)]), now: now), 0)
    }

    func testProjectCountsCountDrawnPillsOnly() {
        let layout = canvas([
            thread("a", owner: "uma", minutesAgo: 2, projects: [("o0", "Project 0")]),
            thread("b", owner: "uma", minutesAgo: 40, projects: [("o0", "Project 0")]),
        ])
        XCTAssertEqual(node(layout, .hub, "o0").count, 1)
        XCTAssertEqual(node(layout, .person, "uma").count, 1)
    }

    /// (c) A pinned session sits centred on its pin and its lines meet the moved frame.
    func testAPinnedSessionIsCentredAtItsPinAndItsLinesFollow() {
        let threads = [
            thread("a", owner: "uma", minutesAgo: 1, projects: [("o0", "Project 0")]),
            thread("b", owner: "uma", minutesAgo: 2, projects: [("o0", "Project 0")]),
        ]
        let pins = pinned([LiveCanvasPositions.sessionKey("a"): (0.3, 640)])
        let layout = layoutNow(model: model(threads), width: 1000, pins: pins)
        let a = node(layout, .session, "a")
        XCTAssertEqual(a.frame.midX, 300, accuracy: 0.001)
        XCTAssertEqual(a.frame.midY, 640, accuracy: 0.001)
        let tree = layout.trees.first { $0.targetId == "a" }!
        XCTAssertEqual(tree.to, CGPoint(x: a.frame.minX, y: a.frame.midY), "the tree ends on the pill's near edge")
        let edge = layout.edges.first { $0.sessionId == "a" }!
        XCTAssertEqual(edge.from, a.rightAnchor)
        XCTAssertEqual(edge.to, node(layout, .hub, "o0").leftAnchor)
        XCTAssertGreaterThanOrEqual(layout.size.height, a.frame.maxY, "the canvas grows to hold it")
        // The other pill stays on its automatic place.
        let auto = canvas(threads, width: 1000)
        XCTAssertEqual(node(layout, .session, "b").frame, node(auto, .session, "b").frame)
    }

    /// A pin to the other side of the canvas flips the tree and edge ends to face it.
    func testALinesEndsFaceTheNodeWhereverItIsDragged() {
        let threads = [thread("a", owner: "uma", minutesAgo: 1, projects: [("o0", "Project 0")])]
        let layout = layoutNow(
            model: model(threads), width: 1000,
            pins: pinned([LiveCanvasPositions.sessionKey("a"): (0.85, 100)]))
        let a = node(layout, .session, "a")
        XCTAssertEqual(layout.edges.first!.from, a.leftAnchor, "the project is to its left now")
        XCTAssertEqual(layout.edges.first!.to, node(layout, .hub, "o0").rightAnchor)
    }

    /// (d) A pinned person takes their unpinned pills along; a pinned pill stays.
    func testAPinnedPersonMovesTheirUnpinnedPillsByTheSameDeltaAndLeavesPinnedOnes() {
        let threads = (0..<3).map { thread("s\($0)", owner: "uma", minutesAgo: Double($0 + 1)) }
        let auto = layoutNow(model: model(threads), width: 1000)
        let before = node(auto, .person, "uma")
        let target = CGPoint(x: 300, y: before.frame.midY + 250)
        let pins = pinned([
            LiveCanvasPositions.personKey("uma"): (0.3, Double(target.y)),
            LiveCanvasPositions.sessionKey("s1"): (0.6, 90),
        ])
        let layout = layoutNow(model: model(threads), width: 1000, pins: pins)
        let person = node(layout, .person, "uma")
        XCTAssertEqual(mid(person).x, target.x, accuracy: 0.001)
        XCTAssertEqual(mid(person).y, target.y, accuracy: 0.001)
        let delta = CGSize(width: target.x - mid(before).x, height: target.y - mid(before).y)
        for id in ["s0", "s2"] {
            let moved = node(layout, .session, id).frame, was = node(auto, .session, id).frame
            XCTAssertEqual(moved.minX, was.minX + delta.width, accuracy: 0.001, id)
            XCTAssertEqual(moved.minY, was.minY + delta.height, accuracy: 0.001, id)
        }
        let kept = node(layout, .session, "s1")
        XCTAssertEqual(mid(kept).x, 600, accuracy: 0.001)
        XCTAssertEqual(mid(kept).y, 90, accuracy: 0.001)
        XCTAssertEqual(layout.trees.count, 3, "every pill still has its tree")
    }

    func testACanvasGrowsToHoldAPinnedNodeAnywhere() {
        let threads = [thread("a", owner: "uma", minutesAgo: 1)]
        let auto = layoutNow(model: model(threads), width: 1000)
        let layout = layoutNow(
            model: model(threads), width: 1000,
            pins: pinned([LiveCanvasPositions.sessionKey("a"): (1, 5000), LiveCanvasPositions.personKey("uma"): (0, -50)]))
        let a = node(layout, .session, "a"), ada = node(layout, .person, "uma")
        XCTAssertEqual(layout.pinPoint(forDrawn: mid(a)).x, 1000, accuracy: 0.001, "centred on its pin, half past the right edge")
        XCTAssertEqual(layout.pinPoint(forDrawn: mid(a)).y, 5000, accuracy: 0.001)
        XCTAssertEqual(layout.pinPoint(forDrawn: mid(ada)).x, 0, accuracy: 0.001, "centred on the left edge")
        XCTAssertEqual(layout.pinPoint(forDrawn: mid(ada)).y, -50, accuracy: 0.001, "and above the top")
        XCTAssertGreaterThan(layout.size.height, 5000)
        XCTAssertGreaterThan(layout.size.width, auto.size.width)
        XCTAssertLessThan(layout.origin.x, 0)
        XCTAssertLessThan(layout.origin.y, 0)
        assertNodesInside(layout)
    }

    func testPinnedProjectsAndIdleFacesMoveAndTheirLinesFollow() {
        let threads = [thread("a", owner: "uma", minutesAgo: 1, projects: [("o1", "Project 1")]), thread("z", owner: "zed", minutesAgo: 90)]
        let layout = layoutNow(
            model: model(threads), width: 1000,
            pins: pinned([
                LiveCanvasPositions.hubKey("o1"): (0.5, 800), LiveCanvasPositions.idleKey("zed"): (0.2, 1200),
            ]))
        let o1 = node(layout, .hub, "o1")
        XCTAssertEqual(mid(o1).x, 500, accuracy: 0.001)
        XCTAssertEqual(mid(o1).y, 800, accuracy: 0.001)
        XCTAssertEqual(layout.edges.first!.to, o1.leftAnchor)
        let zed = node(layout, .idle, "zed")
        XCTAssertEqual(mid(zed).x, 200, accuracy: 0.001)
        XCTAssertEqual(mid(zed).y, 1200, accuracy: 0.001)
    }

    /// A person's place and their idle face's place are two pins: a person dragged while
    /// active does not drag the face they show once idle, and the reverse.
    func testAPersonPinNeverMovesTheirIdleFaceAndAnIdlePinNeverMovesThePerson() {
        let threads = [thread("a", owner: "uma", minutesAgo: 1), thread("z", owner: "zed", minutesAgo: 90)]
        let auto = layoutNow(model: model(threads), width: 1000)
        let personPinned = layoutNow(
            model: model(threads), width: 1000,
            pins: pinned([LiveCanvasPositions.personKey("zed"): (0.2, 1200), LiveCanvasPositions.idleKey("uma"): (0.8, 900)]))
        XCTAssertEqual(node(personPinned, .idle, "zed").frame, node(auto, .idle, "zed").frame, "a person: pin is not the idle face's")
        XCTAssertEqual(node(personPinned, .person, "uma").frame, node(auto, .person, "uma").frame, "an idle: pin is not the person's")
        let idlePinned = layoutNow(
            model: model(threads), width: 1000, pins: pinned([LiveCanvasPositions.idleKey("zed"): (0.2, 1200)]))
        XCTAssertEqual(mid(node(idlePinned, .idle, "zed")).x, 200, accuracy: 0.001)
        XCTAssertEqual(mid(node(idlePinned, .idle, "zed")).y, 1200, accuracy: 0.001)
        XCTAssertEqual(node(auto, .idle, "zed").pinKey, "idle:zed")
        XCTAssertEqual(node(auto, .person, "uma").pinKey, "person:uma")
    }

    // MARK: Dragging (pure parts)

    /// A shaky tap is a tap: under 8 canvas points of travel nothing is saved.
    func testAMoveUnderEightPointsIsNotADrop() {
        XCTAssertFalse(LiveCanvasLayout.isDrop(translation: .zero))
        XCTAssertFalse(LiveCanvasLayout.isDrop(translation: CGSize(width: 3, height: 4)))
        XCTAssertFalse(LiveCanvasLayout.isDrop(translation: CGSize(width: -7.9, height: 0)))
        XCTAssertTrue(LiveCanvasLayout.isDrop(translation: CGSize(width: 0, height: 8)))
        XCTAssertTrue(LiveCanvasLayout.isDrop(translation: CGSize(width: -6, height: 6)))
    }

    /// While a node is dragged the canvas never gets smaller than when the drag began, on any
    /// side, so the camera is not re-clamped (and its corner not moved) under the pointer.
    func testWhileDraggingTheCanvasNeverGetsSmallerOnAnySideComparedWithWhenTheDragBegan() {
        let threads = [thread("a", owner: "uma", minutesAgo: 1, projects: [("o0", "Project 0")])]
        func layout(_ x: Double, _ y: Double, floor: CGRect? = nil) -> LiveCanvasLayout {
            layoutNow(
                model: model(threads), width: 1000,
                pins: pinned([LiveCanvasPositions.sessionKey("a"): (x, y)]), floor: floor)
        }
        // The drag began on a canvas that reaches far left, right, up and down.
        let began = LiveCanvasLayout.canvasBounds(width: 1000, bottom: 600, reaching: [CGRect(x: -700, y: -500, width: 3000, height: 2500)])
        XCTAssertEqual(began, CGRect(x: -714, y: -514, width: 3028, height: 2528))
        // Now the node is back in the middle: the canvas keeps every side it had.
        let dragged = layout(0.5, 200, floor: began)
        XCTAssertEqual(dragged.bounds, began, "no side shrinks")
        XCTAssertEqual(dragged.origin, began.origin, "the corner stays")
        XCTAssertEqual(layout(0.5, 200).bounds.size.width, 1000, "without the floor it would have shrunk to the layout")
        // And the floor never stops it growing past its sides.
        let past = layout(4, -2000, floor: began)
        XCTAssertLessThan(past.origin.y, began.origin.y)
        XCTAssertGreaterThanOrEqual(past.bounds.maxX, began.maxX)
        XCTAssertLessThanOrEqual(past.bounds.minX, began.minX)
        XCTAssertGreaterThanOrEqual(past.bounds.maxY, began.maxY)
    }

    /// (g) Wider or narrower, a pin keeps its share of the width.
    func testAPinKeepsItsXFractionWhenTheWidthChanges() {
        let threads = [thread("a", owner: "uma", minutesAgo: 1)]
        let pins = pinned([LiveCanvasPositions.sessionKey("a"): (0.4, 300)])
        for width in [720, 900, 1234, 1600] as [CGFloat] {
            let layout = layoutNow(model: model(threads), width: width, pins: pins)
            XCTAssertEqual(node(layout, .session, "a").frame.midX / layout.size.width, 0.4, accuracy: 0.0001, "at \(width)")
        }
    }

    func testNoPinsIsTheAutomaticLayout() {
        XCTAssertEqual(
            layoutNow(model: model(fixtureThreads()), width: 1200, pins: LiveCanvasPositions()),
            canvas(width: 1200))
    }

    // MARK: Saved places

    /// (f) The pins round-trip through JSON, old session pins are pruned and the count is capped.
    func testPositionsRoundTripThroughJSON() throws {
        var pins = LiveCanvasPositions()
        pins.set("person:uma", xFraction: 0.25, y: 120.5, at: now)
        pins.set("session:s1", xFraction: 0.75, y: 300, at: now.addingTimeInterval(-60))
        pins.set("hub:o1", xFraction: 1.4, y: 10, at: now)
        XCTAssertEqual(pins.pin(for: "hub:o1")?.xFraction, 1.4, "a fraction past 1 is a node past the right edge")
        let data = try JSONEncoder().encode(pins)
        XCTAssertEqual(try JSONDecoder().decode(LiveCanvasPositions.self, from: data), pins)
        XCTAssertNil(try? JSONDecoder().decode(LiveCanvasPositions.self, from: Data("nope".utf8)))
    }

    func testSessionPinsOlderThanFourteenDaysArePrunedAndOtherKindsKept() {
        var pins = LiveCanvasPositions()
        let day: TimeInterval = 86_400
        pins.set("session:old", xFraction: 0.5, y: 1, at: now.addingTimeInterval(-15 * day))
        pins.set("session:fresh", xFraction: 0.5, y: 1, at: now.addingTimeInterval(-13 * day))
        pins.set("person:uma", xFraction: 0.5, y: 1, at: now.addingTimeInterval(-90 * day))
        pins.prune(now: now)
        XCTAssertEqual(Set(pins.pins.keys), ["session:fresh", "person:uma"])
    }

    func testPositionsAreCappedAtFiveHundredDroppingTheOldest() {
        var pins = LiveCanvasPositions()
        for index in 0..<520 { pins.set("session:s\(index)", xFraction: 0.5, y: Double(index), at: now.addingTimeInterval(Double(-index))) }
        pins.prune(now: now)
        XCTAssertEqual(pins.pins.count, LiveCanvasPositions.maxPins)
        XCTAssertNotNil(pins.pin(for: "session:s0"))
        XCTAssertNil(pins.pin(for: "session:s519"), "the oldest went")
        XCTAssertNotNil(pins.pin(for: "session:s499"))
    }

    func testTheStoreKeepsPinsPerHubAndPersonAndPrunesOnSave() {
        let suite = "org.example.hq.live-canvas-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let mine = LiveCanvasPositionsStore(hub: "https://hq.example/", personID: "me", defaults: defaults)
        var pins = LiveCanvasPositions()
        pins.set("person:uma", xFraction: 0.5, y: 10, at: now)
        pins.set("session:gone", xFraction: 0.5, y: 10, at: now.addingTimeInterval(-20 * 86_400))
        let saved = mine.save(pins, now: now)
        XCTAssertEqual(Set(saved.pins.keys), ["person:uma"])
        XCTAssertEqual(mine.load(now: now), saved)
        XCTAssertEqual(LiveCanvasPositionsStore(hub: "https://hq.example", personID: "me", defaults: defaults).load(now: now), saved, "the hub's trailing slash is not a scope")
        XCTAssertTrue(LiveCanvasPositionsStore(hub: "https://hq.example", personID: "you", defaults: defaults).load(now: now).isEmpty)
        XCTAssertTrue(LiveCanvasPositionsStore(hub: "https://other.example", personID: "me", defaults: defaults).load(now: now).isEmpty)
        mine.save(LiveCanvasPositions(), now: now)
        XCTAssertTrue(mine.load(now: now).isEmpty)
    }

    func testLiveKeepsItsStoredKeyAndControlKeepsItsOwnPlaces() throws {
        let suite = "org.example.hq.live-canvas-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = try JSONEncoder().encode(["https://hq.example", "me"]).base64EncodedString()
        let live = LiveCanvasPositionsStore(hub: "https://hq.example/", personID: "me", defaults: defaults)
        // Stored keys keep their values: a rename would drop everyone's places.
        XCTAssertEqual(live.key, "hq-live-canvas-positions-v1." + scope)
        XCTAssertEqual(LiveCanvasPositionsStore.liveKeyPrefix, "hq-live-canvas-positions-v1")
        let control = LiveCanvasPositionsStore(
            hub: "https://hq.example/", personID: "me", defaults: defaults, keyPrefix: LiveCanvasPositionsStore.controlKeyPrefix)
        XCTAssertEqual(control.key, "hq-control-canvas-positions-v1." + scope)
        XCTAssertNotEqual(control.key, live.key)
        // Control's places and Live's never touch.
        var pins = LiveCanvasPositions()
        pins.set(LiveCanvasPositions.hubKey("o1"), xFraction: 0.4, y: 80, at: now)
        control.save(pins, now: now)
        XCTAssertEqual(control.load(now: now).pins.keys.sorted(), ["hub:o1"])
        XCTAssertTrue(live.load(now: now).isEmpty)
        live.save(LiveCanvasPositions(), now: now)
        XCTAssertFalse(control.load(now: now).isEmpty, "clearing Live leaves Control's places")
    }

    // MARK: Free drag (no invisible walls)

    /// Uma's `a` and Bo's `b`, both on `o0`; a pin on `a` only. Two more projects keep the centre
    /// column about as tall as the camera tests expect.
    private func freeDragLayout(_ x: Double, _ y: Double, width: CGFloat = 1000) -> (pinned: LiveCanvasLayout, auto: LiveCanvasLayout) {
        let threads = [
            thread("a", owner: "uma", minutesAgo: 1, projects: [("o0", "Project 0")]),
            thread("b", owner: "bo", minutesAgo: 2, projects: [("o0", "Project 0")]),
            thread("c", owner: "uma", minutesAgo: 3, projects: [("o1", "Project 1")]),
            thread("d", owner: "bo", minutesAgo: 4, projects: [("o2", "Project 2")]),
        ]
        let pins = pinned([LiveCanvasPositions.sessionKey("a"): (x, y)])
        return (
            layoutNow(model: model(threads), width: width, pins: pins),
            layoutNow(model: model(threads), width: width)
        )
    }

    /// Where `a` sits relative to the project, which no pin moves: the same however far the
    /// drawing is shifted to hold the node.
    private func offsetFromProject(_ layout: LiveCanvasLayout) -> CGPoint {
        let a = mid(node(layout, .session, "a")), o = mid(node(layout, .hub, "o0"))
        return CGPoint(x: a.x - o.x, y: a.y - o.y)
    }

    private func assertNodesInside(_ layout: LiveCanvasLayout, file: StaticString = #filePath, line: UInt = #line) {
        let bounds = CGRect(origin: .zero, size: layout.size)
        for node in layout.nodes {
            XCTAssertTrue(bounds.contains(node.frame), "\(node.id) \(node.frame) outside \(bounds)", file: file, line: line)
        }
    }

    func testANodeDraggedPastTheRightEdgeKeepsItsPlaceAndTheCanvasGrowsToHoldIt() {
        let (layout, auto) = freeDragLayout(1.4, 300)
        let o0 = mid(node(auto, .hub, "o0"))
        XCTAssertEqual(offsetFromProject(layout).x, 1400 - o0.x, accuracy: 0.001, "centred at 1.4 of the width, not stopped at the edge")
        XCTAssertEqual(offsetFromProject(layout).y, 300 - o0.y, accuracy: 0.001)
        XCTAssertGreaterThan(layout.size.width, 1400, "the canvas widens to hold it")
        assertNodesInside(layout)
        let a = node(layout, .session, "a")
        XCTAssertEqual(layout.edges.first { $0.sessionId == "a" }?.from, a.leftAnchor, "its line follows it")
        XCTAssertEqual(layout.trees.first { $0.targetId == "a" }?.to, CGPoint(x: a.frame.minX, y: a.frame.midY), "the tree meets its near edge")
    }

    func testANodeDraggedPastTheLeftEdgeKeepsItsPlaceAndTheCanvasGrowsToHoldIt() {
        let (layout, auto) = freeDragLayout(-0.4, 300)
        let o0 = mid(node(auto, .hub, "o0"))
        XCTAssertEqual(offsetFromProject(layout).x, -400 - o0.x, accuracy: 0.001, "centred at -0.4 of the width")
        XCTAssertEqual(offsetFromProject(layout).y, 300 - o0.y, accuracy: 0.001)
        XCTAssertGreaterThan(layout.size.width, 1000 + 400 - 1, "the canvas widens to the left of the old edge too")
        assertNodesInside(layout)
        let a = node(layout, .session, "a")
        XCTAssertEqual(layout.edges.first { $0.sessionId == "a" }?.from, a.rightAnchor)
    }

    func testANodeDraggedAboveTheTopKeepsItsPlaceAndTheCanvasGrowsToHoldIt() {
        let (layout, auto) = freeDragLayout(0.5, -600)
        let o0 = mid(node(auto, .hub, "o0"))
        XCTAssertEqual(offsetFromProject(layout).y, -600 - o0.y, accuracy: 0.001, "600 above the old top")
        XCTAssertEqual(offsetFromProject(layout).x, 500 - o0.x, accuracy: 0.001)
        XCTAssertGreaterThan(layout.size.height, auto.size.height + 600 - 1, "the canvas grows upward")
        assertNodesInside(layout)
    }

    func testEveryLineOfAFarNodeStaysInsideTheCanvas() {
        for place in [(1.6, -300.0), (-0.6, 2000.0), (0.5, -900.0)] {
            let layout = freeDragLayout(place.0, place.1).pinned
            let bounds = CGRect(origin: .zero, size: layout.size)
            for line in layout.edges.flatMap({ [$0.from, $0.to] }) + layout.trees.flatMap({ [$0.from, $0.to] }) {
                XCTAssertTrue(bounds.contains(line), "\(line) outside \(bounds) for \(place)")
            }
        }
    }

    func testASavedPinOutsideTheOldRangeRoundTripsAndLandsWhereItWas() throws {
        var pins = LiveCanvasPositions()
        pins.set("session:a", xFraction: -1.5, y: -800, at: now)
        pins.set("session:b", xFraction: 2.25, y: 4000, at: now)
        XCTAssertEqual(pins.pin(for: "session:a")?.xFraction, -1.5)
        XCTAssertEqual(pins.pin(for: "session:a")?.y, -800)
        XCTAssertEqual(pins.pin(for: "session:b")?.xFraction, 2.25)
        let data = try JSONEncoder().encode(pins)
        XCTAssertEqual(try JSONDecoder().decode(LiveCanvasPositions.self, from: data), pins)
        // A record the old build wrote (fractions inside 0...1) decodes unchanged.
        let old = Data(#"{"pins":{"session:a":{"xFraction":0.25,"y":120,"savedAt":0}}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(LiveCanvasPositions.self, from: old).pin(for: "session:a")?.xFraction, 0.25)
    }

    func testOnlyAbsurdPinsAreBoundedAndNonFiniteOnesAreRefused() {
        var pins = LiveCanvasPositions()
        pins.set("session:far", xFraction: 900, y: -9_000_000, at: now)
        XCTAssertEqual(pins.pin(for: "session:far")?.xFraction, LiveCanvasPositions.maxFraction)
        XCTAssertEqual(pins.pin(for: "session:far")?.y, -LiveCanvasPositions.maxY)
        pins.set("session:nan", xFraction: .nan, y: 5, at: now)
        pins.set("session:inf", xFraction: 0.5, y: .infinity, at: now)
        XCTAssertNil(pins.pin(for: "session:nan"))
        XCTAssertNil(pins.pin(for: "session:inf"))
        XCTAssertEqual(LiveCanvasPositions.maxFraction, 4)
        XCTAssertEqual(LiveCanvasPositions.maxY, 10_000)
    }

    func testThePanIsFreePastTheOldSlackButAtLeastEightyPointsOfCanvasStayInView() {
        let content = CGSize(width: 1000, height: 2400), viewport = CGSize(width: 1000, height: 700)
        let right = LiveCanvasCamera().panned(by: CGSize(width: 600, height: 0)).clamped(content: content, viewport: viewport)
        XCTAssertEqual(right.offset.x, 600, "well past the old 48pt slack")
        let farRight = LiveCanvasCamera().panned(by: CGSize(width: 99_999, height: 0)).clamped(content: content, viewport: viewport)
        XCTAssertEqual(farRight.offset.x, viewport.width - LiveCanvasCamera.keepVisible, "80pt of the left edge stay in view")
        let farLeft = LiveCanvasCamera().panned(by: CGSize(width: -99_999, height: 0)).clamped(content: content, viewport: viewport)
        XCTAssertEqual(farLeft.offset.x, LiveCanvasCamera.keepVisible - content.width, "80pt of the right edge stay in view")
        let farDown = LiveCanvasCamera().panned(by: CGSize(width: 0, height: 99_999)).clamped(content: content, viewport: viewport)
        XCTAssertEqual(farDown.offset.y, viewport.height - LiveCanvasCamera.keepVisible)
        let farUp = LiveCanvasCamera(scale: 2).panned(by: CGSize(width: 0, height: -99_999)).clamped(content: content, viewport: viewport)
        XCTAssertEqual(farUp.offset.y, LiveCanvasCamera.keepVisible - content.height * 2)
        XCTAssertEqual(LiveCanvasCamera.keepVisible, 80)
    }

    func testACanvasSmallerThanTheEightyPointsKeepsAllOfItInView() {
        let tiny = CGSize(width: 50, height: 30), viewport = CGSize(width: 1000, height: 700)
        let far = LiveCanvasCamera().panned(by: CGSize(width: 99_999, height: 99_999)).clamped(content: tiny, viewport: viewport)
        XCTAssertEqual(far.offset.x, viewport.width - 50)
        XCTAssertEqual(far.offset.y, viewport.height - 30)
    }

    func testWithNothingOutsideTheAutomaticLayoutTheCanvasKeepsItsCornerAndWidth() {
        let layout = canvas(width: 1000)
        XCTAssertEqual(layout.origin, .zero)
        XCTAssertEqual(layout.baseWidth, 1000)
        XCTAssertEqual(layout.size.width, 1000)
        XCTAssertEqual(layout.bounds, CGRect(origin: .zero, size: layout.size))
        let inside = freeDragLayout(0.5, 200).pinned
        XCTAssertEqual(inside.origin, .zero, "a node moved inside the layout does not move the corner")
        XCTAssertEqual(inside.size.width, 1000)
    }

    func testPinAndDrawnCoordinatesConvertOnlyThroughTheLayout() {
        let layout = freeDragLayout(-0.4, -600).pinned
        let a = node(layout, .session, "a")
        let pin = layout.pinPoint(forDrawn: mid(a))
        XCTAssertEqual(pin.x, -400, accuracy: 0.001)
        XCTAssertEqual(pin.y, -600, accuracy: 0.001)
        let place = layout.pinPlace(forPinPoint: pin)
        XCTAssertEqual(place.xFraction, -0.4, accuracy: 0.0001)
        XCTAssertEqual(place.y, -600, accuracy: 0.001)
        XCTAssertEqual(layout.drawnPoint(forPin: pin), mid(a))
        XCTAssertEqual(layout.baseWidth, 1000, "pins stay fractions of the automatic width")
    }

    /// A drop that moves the canvas's corner: the camera is rebased, so every node that did not
    /// move is at the same viewport point, at any zoom.
    func testADropThatMovesTheCornerKeepsEveryOtherNodeAtTheSameScreenPoint() {
        let before = freeDragLayout(0.5, 300).pinned
        let after = freeDragLayout(-0.5, -700).pinned
        XCTAssertNotEqual(before.origin, after.origin)
        func screen(_ node: LiveCanvasLayout.Node, _ camera: LiveCanvasCamera) -> CGPoint {
            CGPoint(x: node.frame.midX * camera.scale + camera.offset.x, y: node.frame.midY * camera.scale + camera.offset.y)
        }
        for scale in [0.4, 1, 2.5] as [CGFloat] {
            let camera = LiveCanvasCamera(scale: scale, offset: CGPoint(x: 37, y: -21))
            let rebased = camera.rebased(from: before.origin, to: after.origin)
            for node in before.nodes where node.refId != "a" {
                let other = self.node(after, node.kind, node.refId)
                XCTAssertEqual(screen(other, rebased).x, screen(node, camera).x, accuracy: 0.001, "\(node.id) at \(scale)")
                XCTAssertEqual(screen(other, rebased).y, screen(node, camera).y, accuracy: 0.001, "\(node.id) at \(scale)")
            }
            XCTAssertEqual(rebased.scale, scale)
        }
        let same = LiveCanvasCamera(scale: 1.3, offset: CGPoint(x: 5, y: 6))
        XCTAssertEqual(same.rebased(from: before.origin, to: before.origin), same, "no move, no change")
        XCTAssertEqual(
            same.rebased(from: before.origin, to: after.origin).rebased(from: after.origin, to: before.origin).offset.x, same.offset.x,
            accuracy: 0.0001, "and back")
    }

    /// The node under the pointer stays under it while the canvas grows left and up around it.
    func testTheDraggedNodeStaysUnderThePointerWhileTheCanvasGrowsLeftAndUp() {
        let start = freeDragLayout(0.5, 300).pinned
        let a0 = mid(node(start, .session, "a"))
        var camera = LiveCanvasCamera(scale: 0.8, offset: CGPoint(x: 10, y: 20))
        let pointer0 = CGPoint(x: a0.x * 0.8 + 10, y: a0.y * 0.8 + 20)
        var previous = start
        // The pointer drags 40 screen points left and up per step, 12 steps: past the left and top.
        for step in 1...12 {
            let pin = start.pinPoint(forDrawn: a0)
            let target = CGPoint(x: pin.x - CGFloat(step) * 40 / 0.8, y: pin.y - CGFloat(step) * 40 / 0.8)
            let place = start.pinPlace(forPinPoint: target)
            let next = freeDragLayout(place.xFraction, place.y).pinned
            camera = camera.rebased(from: previous.origin, to: next.origin)
            let a = mid(node(next, .session, "a"))
            XCTAssertEqual(a.x * camera.scale + camera.offset.x, pointer0.x - CGFloat(step) * 40, accuracy: 0.001, "step \(step)")
            XCTAssertEqual(a.y * camera.scale + camera.offset.y, pointer0.y - CGFloat(step) * 40, accuracy: 0.001, "step \(step)")
            previous = next
        }
        XCTAssertLessThan(previous.origin.x, 0)
        XCTAssertLessThan(previous.origin.y, 0)
    }

    func testAnOverlapArcOfAFarNodeStaysInsideTheCanvas() {
        let shared = ("t9", "HQ-\(900)", "Ship the thing")
        let threads = [thread("1", owner: "bo", minutesAgo: 1, tasks: [shared]), thread("2", owner: "bob", minutesAgo: 2, tasks: [shared])]
        for place in [(-0.6, -700.0), (1.8, 1500.0), (0.5, -300.0)] {
            let layout = layoutNow(
                model: model(threads), width: 1000,
                pins: pinned([LiveCanvasPositions.sessionKey("1"): place]))
            let arc = layout.overlaps[0]
            let bounds = CGRect(origin: .zero, size: layout.size).insetBy(dx: -0.001, dy: -0.001)
            for step in 0...20 {
                let t = CGFloat(step) / 20, u = 1 - t
                let point = CGPoint(
                    x: u * u * u * arc.from.x + 3 * u * u * t * arc.control1.x + 3 * u * t * t * arc.control2.x + t * t * t * arc.to.x,
                    y: u * u * u * arc.from.y + 3 * u * u * t * arc.control1.y + 3 * u * t * t * arc.control2.y + t * t * t * arc.to.y)
                XCTAssertTrue(bounds.contains(point), "\(point) outside \(bounds) for \(place)")
            }
        }
    }

    func testTheCaptionAndEveryLineShiftWithTheNodes() throws {
        // Projects in the centre carry a caption.
        let threads = [thread("a", owner: "uma", minutesAgo: 1, projects: [("p1", "Image fleet")])]
        let auto = layoutNow(model: model(threads), width: 1000)
        let moved = layoutNow(
            model: model(threads), width: 1000,
            pins: pinned([LiveCanvasPositions.sessionKey("a"): (-0.5, -400)]))
        XCTAssertLessThan(moved.origin.x, 0)
        let caption = try XCTUnwrap(moved.hubCaptionCenter), was = try XCTUnwrap(auto.hubCaptionCenter)
        XCTAssertEqual(caption.x, was.x - moved.origin.x, accuracy: 0.001)
        XCTAssertEqual(caption.y, was.y - moved.origin.y, accuracy: 0.001)
        let hub = node(moved, .hub, "p1"), hubWas = node(auto, .hub, "p1")
        XCTAssertEqual(hub.frame.minX, hubWas.frame.minX - moved.origin.x, accuracy: 0.001)
        XCTAssertEqual(moved.edges[0].to, hub.leftAnchor, "the line meets the shifted hub")
    }

    // MARK: Opening, returning and limits (review of the free-drag canvas)

    /// Where a node's centre lands in the viewport under `camera`.
    private func screen(_ node: LiveCanvasLayout.Node, _ camera: LiveCanvasCamera) -> CGPoint {
        CGPoint(x: node.frame.midX * camera.scale + camera.offset.x, y: node.frame.midY * camera.scale + camera.offset.y)
    }

    private func home(_ layout: LiveCanvasLayout, viewport: CGSize) -> LiveCanvasCamera {
        .home(content: layout.size, viewport: viewport, origin: layout.origin, baseWidth: layout.baseWidth)
    }

    /// 1. A camera records the corner its offset is measured from, so it opens against another
    /// corner (the pins had not been read yet; a node was moved meanwhile) on the same canvas points.
    func testASavedCameraRecordsItsCornerAndOpensWhereItWasLeft() {
        let layout = freeDragLayout(-0.5, -700).pinned
        XCTAssertLessThan(layout.origin.x, 0)
        XCTAssertLessThan(layout.origin.y, 0)
        let viewport = CGSize(width: 1000, height: 700)
        let left = LiveCanvasCamera(scale: 1, offset: CGPoint(x: -50, y: -300), origin: layout.origin)
        let a = node(layout, .session, "a")
        // Against the corner it was set for: exactly as left.
        let same = LiveCanvasCamera.opening(
            saved: left, content: layout.size, viewport: viewport, origin: layout.origin, baseWidth: layout.baseWidth)
        XCTAssertEqual(same, left)
        // Against a corner of zero (the layout before the pins): the same canvas point is under the
        // same viewport point once the corner it is measured from is the real one again.
        let early = LiveCanvasCamera.opening(
            saved: left, content: layout.size, viewport: viewport, origin: .zero, baseWidth: layout.baseWidth)
        XCTAssertEqual(early.origin, .zero)
        XCTAssertNotEqual(early.offset, left.offset)
        let back = early.rebased(to: layout.origin)
        XCTAssertEqual(back.offset.x, left.offset.x, accuracy: 0.001)
        XCTAssertEqual(back.offset.y, left.offset.y, accuracy: 0.001)
        XCTAssertEqual(screen(a, back).x, screen(a, left).x, accuracy: 0.001)
        XCTAssertEqual(screen(a, back).y, screen(a, left).y, accuracy: 0.001)
        // Every way of moving the camera keeps the corner it records.
        XCTAssertEqual(left.panned(by: CGSize(width: 3, height: 4)).origin, layout.origin)
        XCTAssertEqual(left.zoomed(to: 1.5, around: .zero).origin, layout.origin)
        XCTAssertEqual(left.clamped(content: layout.size, viewport: viewport).origin, layout.origin)
        XCTAssertEqual(left.resized(content: layout.size, viewport: viewport).origin, layout.origin)
    }

    /// 3. The opening view is the automatic layout at the top and at its own width, wherever the
    /// canvas around it has grown to; Fit is the whole canvas.
    func testTheOpeningViewShowsTheAutomaticLayoutAtTheTopWhateverIsPinnedAway() {
        for viewport in [CGSize(width: 1000, height: 700), CGSize(width: 500, height: 700)] {
            let (_, auto) = freeDragLayout(0.5, 200)
            let reference = home(auto, viewport: viewport)
            XCTAssertEqual(reference, LiveCanvasCamera.fit(content: auto.size, viewport: viewport), "nothing outside: the opening view is the fit")
            for place in [(0.5, -2000.0), (4.0, 100.0), (-4.0, 100.0), (1.5, 9000.0), (-2.0, -9000.0)] {
                let layout = freeDragLayout(place.0, place.1).pinned
                let open = home(layout, viewport: viewport)
                XCTAssertEqual(open.scale, reference.scale, accuracy: 0.0001, "\(place) at \(viewport.width): not shrunk to hold the far node")
                for target in [(LiveCanvasLayout.Kind.hub, "o0"), (.session, "b"), (.person, "bo")] {
                    let here = screen(node(layout, target.0, target.1), open)
                    let there = screen(node(auto, target.0, target.1), reference)
                    XCTAssertEqual(here.x, there.x, accuracy: 0.01, "\(target.1) \(place)")
                    XCTAssertEqual(here.y, there.y, accuracy: 0.01, "\(target.1) \(place): top of the automatic layout at the top")
                }
                XCTAssertNil(open.kept(content: layout.size, viewport: viewport, baseWidth: layout.baseWidth), "a first look needs no memory")
                XCTAssertEqual(open, open.clamped(content: layout.size, viewport: viewport))
                // Fit is the whole canvas, and is what the person left if they pressed it.
                let fit = LiveCanvasCamera.fit(content: layout.size, viewport: viewport, origin: layout.origin)
                XCTAssertNotEqual(open, fit, "\(place): the far node is reachable by Fit")
                XCTAssertEqual(fit.kept(content: layout.size, viewport: viewport, baseWidth: layout.baseWidth), fit)
                XCTAssertLessThanOrEqual(fit.scale, open.scale)
            }
        }
    }

    /// 2. A corner correction and back leaves the opening view the opening view, so what is held
    /// above the board never depends on which of the canvas's two changes (size, corner) is seen first.
    func testACornerCorrectionLeavesTheOpeningViewNothingToKeep() {
        let viewport = CGSize(width: 1000, height: 700)
        let layout = freeDragLayout(-0.6, -900).pinned
        let target = home(layout, viewport: viewport)
        XCTAssertNil(target.kept(content: layout.size, viewport: viewport, baseWidth: layout.baseWidth))
        let corrected = target.rebased(to: .zero).rebased(to: layout.origin)
        XCTAssertEqual(corrected.offset.x, target.offset.x, accuracy: 0.001)
        XCTAssertEqual(corrected.offset.y, target.offset.y, accuracy: 0.001)
        XCTAssertNil(corrected.kept(content: layout.size, viewport: viewport, baseWidth: layout.baseWidth))
    }

    /// 4. Pins saved under the looser bounds (20 layouts across, 50,000pt down) load clamped to the
    /// new ones, not dropped.
    func testPinsSavedUnderTheOldBoundsLoadClampedNotDropped() {
        let suite = "org.example.hq.live-canvas-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveCanvasPositionsStore(hub: "https://hq.example", personID: "me", defaults: defaults)
        let at = now.timeIntervalSinceReferenceDate
        let record = """
            {"pins":{"person:far":{"xFraction":19.5,"y":-49000,"savedAt":\(at)},\
            "session:near":{"xFraction":-3.5,"y":9000,"savedAt":\(at)},\
            "hub:left":{"xFraction":-20,"y":50000,"savedAt":\(at)}}}
            """
        defaults.set(Data(record.utf8), forKey: store.key)
        let loaded = store.load(now: now)
        XCTAssertEqual(Set(loaded.pins.keys), ["person:far", "session:near", "hub:left"], "none dropped")
        XCTAssertEqual(loaded.pin(for: "person:far")?.xFraction, 4)
        XCTAssertEqual(loaded.pin(for: "person:far")?.y, -10_000)
        XCTAssertEqual(loaded.pin(for: "hub:left")?.xFraction, -4)
        XCTAssertEqual(loaded.pin(for: "hub:left")?.y, 10_000)
        XCTAssertEqual(loaded.pin(for: "session:near")?.xFraction, -3.5, "inside the bounds: unchanged")
        XCTAssertEqual(loaded.pin(for: "session:near")?.y, 9000)
        XCTAssertEqual(loaded.pin(for: "person:far")?.savedAt, loaded.pin(for: "session:near")?.savedAt)
    }

    /// 4. At the bounds the canvas is a size a Mac can draw (its line layers are as big as it is),
    /// and the zoom floor fits it without going lower than it must.
    func testTheCanvasAtThePinBoundsStaysAtASizeAMacCanDraw() {
        XCTAssertEqual(LiveCanvasPositions.maxFraction, 4)
        XCTAssertEqual(LiveCanvasPositions.maxY, 10_000)
        for width in [720, 1000, 1600] as [CGFloat] {
            for corner in [(900.0, -9_000_000.0), (-900.0, 9_000_000.0), (900.0, 9_000_000.0)] {
                let layout = freeDragLayout(corner.0, corner.1, width: width).pinned
                XCTAssertLessThan(layout.size.width, 9.5 * width, "\(width)")
                XCTAssertLessThan(layout.size.height, 20_800, "\(width)")
                let floor = LiveCanvasCamera.minZoom(content: layout.size, viewport: CGSize(width: 1000, height: 700))
                XCTAssertGreaterThanOrEqual(floor, LiveCanvasCamera.hardMinScale)
                XCTAssertGreaterThanOrEqual(floor * layout.size.width, 749, "the floor fits the canvas whole in a 1000pt viewport, \(width)")
            }
        }
        // Never lower than the hard floor, however wide a canvas is asked for.
        XCTAssertEqual(
            LiveCanvasCamera.minZoom(content: CGSize(width: 100_000, height: 100), viewport: CGSize(width: 1000, height: 700)),
            LiveCanvasCamera.hardMinScale)
    }

    // MARK: Overlap arcs of moved pills

    private func sharedTask() -> [CodingThread] {
        let task = ("t9", "HQ-\(900)", "Ship the thing")
        return [thread("1", owner: "bo", minutesAgo: 1, tasks: [task]), thread("2", owner: "bob", minutesAgo: 2, tasks: [task])]
    }

    private func arcPoints(_ arc: LiveCanvasLayout.Overlap, steps: Int = 200) -> [CGPoint] {
        (0...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps), u = 1 - t
            return CGPoint(
                x: u * u * u * arc.from.x + 3 * u * u * t * arc.control1.x + 3 * u * t * t * arc.control2.x + t * t * t * arc.to.x,
                y: u * u * u * arc.from.y + 3 * u * u * t * arc.control1.y + 3 * u * t * t * arc.control2.y + t * t * t * arc.to.y)
        }
    }

    /// 5. Dragging an overlapping pill far down used to throw the arc up above the layout (the
    /// control height was fixed to the lane, so ends at very different heights made the curve
    /// dip about 8% of the drop past it) and the canvas grew upward to hold it, a blank band above
    /// everything. The arc now stays at or below its lane, or below its higher end.
    func testDraggingAnOverlappingPillDownNeverGrowsTheCanvasUpward() {
        let threads = sharedTask()
        for drop in [300.0, 1500.0, 6000.0] {
            let layout = layoutNow(
                model: model(threads), width: 1000,
                pins: pinned([LiveCanvasPositions.sessionKey("1"): (0.2, drop)]))
            XCTAssertEqual(layout.origin.y, 0, "\(drop): no blank band above the layout")
            let arc = layout.overlaps[0]
            let lowest = arcPoints(arc).map(\.y).min()!
            XCTAssertGreaterThanOrEqual(lowest, 8 - 0.01, "\(drop): the arc stays in the lane above the pills")
        }
    }

    func testAnArcNeverRisesAboveItsHigherEndBeyondItsLaneStoodAboveIt() {
        let threads = sharedTask()
        // A pill dragged above the lane: the arc goes no higher than that pill.
        let high = layoutNow(
            model: model(threads), width: 1000,
            pins: pinned([LiveCanvasPositions.sessionKey("1"): (0.2, -500)]))
        let arc = high.overlaps[0]
        let lowest = arcPoints(arc).map(\.y).min()!
        XCTAssertGreaterThanOrEqual(lowest, min(arc.from.y, arc.to.y) - 0.01)
        XCTAssertGreaterThanOrEqual(lowest, CGFloat(0) - 0.01, "the canvas holds it")
    }

    func testTheArcOfTwoPillsAtTheSameHeightIsTheLaneItWasAndOnlyAnUnevenPairIsLifted() {
        XCTAssertEqual(LiveCanvasLayout.controlHeight(from: 40, to: 40, peak: 8), (8 * 8 - 80) / 6, accuracy: 0.000_001)
        XCTAssertEqual(LiveCanvasLayout.controlHeight(from: 60, to: 60, peak: 28), (8 * 28 - 120) / 6, accuracy: 0.000_001)
        // An uneven pair is no lower than the lane's own control, and its curve stays at its floor.
        for (from, to, peak) in [(40.0, 340.0, 8.0), (40.0, 2000.0, 18.0), (500.0, 30.0, 28.0), (-300.0, 200.0, 8.0)] as [(CGFloat, CGFloat, CGFloat)] {
            let c = LiveCanvasLayout.controlHeight(from: from, to: to, peak: peak)
            XCTAssertGreaterThanOrEqual(c, (8 * peak - (from + to)) / 6 - 0.000_001)
            let floor = min(peak, from, to)
            for step in 0...400 {
                let t = CGFloat(step) / 400, u = 1 - t
                let y = from * u * u * u + 3 * u * u * t * c + 3 * u * t * t * c + to * t * t * t
                XCTAssertGreaterThanOrEqual(y, floor - 0.01, "\(from) \(to) \(peak) at \(t)")
            }
        }
    }

    func testProviderTagForNonClaudeSessions() {
        let rows = model([thread("a", owner: "uma", provider: "codex"), thread("b", owner: "uma", provider: "claude")]).groups[0].named
        XCTAssertEqual(rows.first { $0.id == "a" }?.providerText, "Codex")
        XCTAssertNil(rows.first { $0.id == "b" }?.providerText)
    }

    // MARK: Mirrored people

    /// A node's frame in pin space, where the automatic layout and the mirrored one can be compared
    /// (the drawn space shifts with the canvas's corner).
    private func pinSpace(_ node: LiveCanvasLayout.Node, in layout: LiveCanvasLayout) -> CGRect {
        node.frame.offsetBy(dx: layout.origin.x, dy: layout.origin.y)
    }

    private func mirroredPins(_ person: String, base: LiveCanvasPositions = LiveCanvasPositions()) -> LiveCanvasPositions {
        var pins = base
        pins.setMirrored(LiveCanvasPositions.personKey(person), true)
        return pins
    }

    private func pillIds(of person: String, in layout: LiveCanvasLayout) -> [String] {
        layout.trees.filter { $0.personId == person }.map(\.targetId)
    }

    private func fixtureLayout(pins: LiveCanvasPositions = LiveCanvasPositions()) -> LiveCanvasLayout {
        return layoutNow(model: model(fixtureThreads()), width: 1200, pins: pins)
    }

    /// Uma stands on the left with 12 pills, Kim on the right with 1: both ways round.
    private let mirrorPeople: [(id: String, isLeft: Bool)] = [("uma", true), ("kim", false), ("bo", true), ("pat", false)]

    /// (a) A mirrored person's pills stand on the other side of the avatar at the same heights,
    /// each reflected about the avatar's centre line; the avatar and everyone else stay put.
    func testAMirroredPersonsPillsStandOnTheOtherSideOfTheAvatarAtTheSameHeights() {
        let auto = fixtureLayout()
        for (person, isLeft) in mirrorPeople {
            let mirrored = fixtureLayout(pins: mirroredPins(person))
            let ids = pillIds(of: person, in: auto)
            XCTAssertFalse(ids.isEmpty, "\(person) has pills")
            XCTAssertEqual(pillIds(of: person, in: mirrored), ids, "the same pills in the same order")
            let avatar = pinSpace(node(auto, .person, person), in: auto)
            XCTAssertEqual(pinSpace(node(mirrored, .person, person), in: mirrored), avatar, "\(person) did not move")
            for id in ids {
                let before = pinSpace(node(auto, .session, id), in: auto)
                let after = pinSpace(node(mirrored, .session, id), in: mirrored)
                XCTAssertEqual(after.midY, before.midY, accuracy: 0.001, "\(id) keeps its height")
                XCTAssertEqual(after.width, before.width, accuracy: 0.001)
                XCTAssertEqual(after.midX, 2 * avatar.midX - before.midX, accuracy: 0.001, "\(id) is reflected about \(person)")
                if isLeft {
                    XCTAssertLessThan(after.maxX, avatar.minX, "\(id) is now left of \(person)")
                } else {
                    XCTAssertGreaterThan(after.minX, avatar.maxX, "\(id) is now right of \(person)")
                }
            }
            let own = Set(ids.map { "session:\($0)" })
            for other in auto.nodes where !own.contains(other.id) {
                XCTAssertEqual(
                    pinSpace(node(mirrored, other.kind, other.refId), in: mirrored), pinSpace(other, in: auto),
                    "\(other.id) is where it was")
            }
        }
    }

    /// (b) The lines follow: the tree leaves the avatar's edge that faces the pill and reaches the
    /// pill's edge that faces the avatar; the project line leaves the pill's edge that faces the
    /// project and reaches the project's edge that faces the pill.
    func testTheLinesOfAMirroredPersonFollowTheirPills() {
        for (person, isLeft) in mirrorPeople {
            let layout = fixtureLayout(pins: mirroredPins(person))
            let avatar = node(layout, .person, person).avatar
            let trees = layout.trees.filter { $0.personId == person }
            XCTAssertFalse(trees.isEmpty)
            for tree in trees {
                let pill = node(layout, .session, tree.targetId)
                let isRightOfAvatar = pill.frame.midX >= avatar.midX
                XCTAssertEqual(isRightOfAvatar, !isLeft, "\(tree.id): the pill is across the avatar")
                XCTAssertEqual(tree.from.x, isRightOfAvatar ? avatar.maxX : avatar.minX, accuracy: 0.001, "\(tree.id) leaves the near edge")
                XCTAssertEqual(tree.from.y, avatar.midY, accuracy: 0.001)
                XCTAssertEqual(tree.to.x, isRightOfAvatar ? pill.frame.minX : pill.frame.maxX, accuracy: 0.001, "\(tree.id) reaches the near edge")
                XCTAssertEqual(tree.to.y, pill.frame.midY, accuracy: 0.001)
            }
            for edge in layout.edges where trees.contains(where: { $0.targetId == edge.sessionId }) {
                let pill = node(layout, .session, edge.sessionId)
                let target = layout.nodes.first { $0.kind == .hub && $0.refId == edge.targetId }!
                let isTargetRight = pill.frame.midX < target.frame.midX
                XCTAssertEqual(edge.from, isTargetRight ? pill.rightAnchor : pill.leftAnchor, "\(edge.id) leaves the pill's edge facing the project")
                XCTAssertEqual(edge.to, isTargetRight ? target.leftAnchor : target.rightAnchor, "\(edge.id) reaches the project's near edge")
            }
        }
    }

    /// (c) The flag moves only pills the person never moved; a pinned pill is where it was put.
    func testTheFlagLeavesAPinnedPillWhereItWasPut() {
        let auto = fixtureLayout()
        let ids = pillIds(of: "uma", in: auto)
        let pinnedId = ids[3]
        let spot: (Double, Double) = (0.45, 900)
        var pins = pinned([LiveCanvasPositions.sessionKey(pinnedId): spot])
        pins.setMirrored(LiveCanvasPositions.personKey("uma"), true)
        let layout = fixtureLayout(pins: pins)
        let pill = pinSpace(node(layout, .session, pinnedId), in: layout)
        XCTAssertEqual(pill.midX, 0.45 * 1200, accuracy: 0.001)
        XCTAssertEqual(pill.midY, 900, accuracy: 0.001)
        let avatar = pinSpace(node(auto, .person, "uma"), in: auto)
        for id in ids where id != pinnedId {
            let before = pinSpace(node(auto, .session, id), in: auto)
            let after = pinSpace(node(layout, .session, id), in: layout)
            XCTAssertEqual(after.midX, 2 * avatar.midX - before.midX, accuracy: 0.001, "\(id) is mirrored")
        }
    }

    /// (d) A person who was dragged is mirrored about where they stand now, and their pills (which
    /// came with them) cross to the other side of that place.
    func testAMovedPersonIsMirroredAboutWhereTheyStand() {
        let movedPins = pinned([LiveCanvasPositions.personKey("uma"): (0.5, 700)])
        let moved = fixtureLayout(pins: movedPins)
        let mirrored = fixtureLayout(pins: mirroredPins("uma", base: movedPins))
        let avatar = pinSpace(node(moved, .person, "uma"), in: moved)
        XCTAssertEqual(avatar.midX, 600, accuracy: 0.001)
        XCTAssertEqual(pinSpace(node(mirrored, .person, "uma"), in: mirrored), avatar)
        for id in pillIds(of: "uma", in: moved) {
            let before = pinSpace(node(moved, .session, id), in: moved)
            let after = pinSpace(node(mirrored, .session, id), in: mirrored)
            XCTAssertEqual(after.midX, 1200 - before.midX, accuracy: 0.001)
            XCTAssertEqual(after.midY, before.midY, accuracy: 0.001)
        }
    }

    /// (e) The canvas grows to hold the pills on their new side, by the rules of a pin dropped
    /// past an edge: the corner moves to the pills' far edge less the margin, and every node and
    /// line is inside it.
    func testTheCanvasGrowsToHoldMirroredPills() {
        let auto = fixtureLayout()
        XCTAssertEqual(auto.origin, .zero)
        let left = fixtureLayout(pins: mirroredPins("uma"))
        let farthest = pillIds(of: "uma", in: left).map { pinSpace(node(left, .session, $0), in: left).minX }.min()!
        XCTAssertLessThan(farthest, 0)
        XCTAssertEqual(left.origin.x, farthest - LiveCanvasLayout.margin, accuracy: 0.001)
        XCTAssertEqual(left.size.width, auto.size.width - left.origin.x, accuracy: 0.001)
        assertNodesInside(left)
        let right = fixtureLayout(pins: mirroredPins("kim"))
        let reach = pillIds(of: "kim", in: right).map { pinSpace(node(right, .session, $0), in: right).maxX }.max()!
        XCTAssertGreaterThan(reach, 1200)
        XCTAssertEqual(right.origin.x, 0)
        XCTAssertEqual(right.size.width, reach + LiveCanvasLayout.margin, accuracy: 0.001)
        assertNodesInside(right)
        var cleared = mirroredPins("kim")
        cleared.setMirrored(LiveCanvasPositions.personKey("kim"), false)
        XCTAssertEqual(fixtureLayout(pins: cleared), auto, "unmirrored, the canvas is the automatic one again")
    }

    /// (f) A flag on someone with no pills drawn (an idle face, or nobody) changes nothing.
    func testAFlagOnSomeoneWithNoPillsChangesNothing() {
        let roster: [LiveThreadsModel.Idle] = [.init(id: "zed", name: "Zed")]
        let plain = layoutNow(model: model(fixtureThreads(), roster: roster), width: 1200)
        for person in ["zed", "nobody"] {
            let flagged = layoutNow(
                model: model(fixtureThreads(), roster: roster), width: 1200, pins: mirroredPins(person))
            XCTAssertEqual(flagged, plain, "\(person)")
        }
    }

    /// (g) Mirroring writes the flag and rewrites pinned pills' pins, reflected about the avatar
    /// with the bounds of a drag; mirroring again restores them.
    func testMirroringAPersonFlipsTheFlagAndReflectsTheirPinnedPills() {
        var pins = LiveCanvasPositions()
        pins.set("session:a", xFraction: 0.8, y: 100, at: now)
        pins.set("session:b", xFraction: 0.1, y: -50, at: now)
        pins.set("person:uma", xFraction: 0.5, y: 10, at: now)
        let later = now.addingTimeInterval(60)
        pins.mirrorPerson("person:uma", aroundX: 0.5, pills: ["session:a", "session:b", "session:unpinned"], at: later)
        XCTAssertTrue(pins.isMirrored("person:uma"))
        XCTAssertEqual(pins.pin(for: "session:a")?.xFraction ?? 9, 0.2, accuracy: 1e-12)
        XCTAssertEqual(pins.pin(for: "session:a")?.y, 100, "the height is kept")
        XCTAssertEqual(pins.pin(for: "session:b")?.xFraction ?? 9, 0.9, accuracy: 1e-12)
        XCTAssertEqual(pins.pin(for: "session:b")?.savedAt, later)
        XCTAssertNil(pins.pin(for: "session:unpinned"), "a pill never moved gets no pin: the flag carries it")
        XCTAssertEqual(pins.pin(for: "person:uma")?.xFraction, 0.5, "the avatar stays")
        pins.mirrorPerson("person:uma", aroundX: 0.5, pills: ["session:a", "session:b", "session:unpinned"], at: later)
        XCTAssertFalse(pins.isMirrored("person:uma"))
        XCTAssertEqual(pins.pin(for: "session:a")?.xFraction ?? 9, 0.8, accuracy: 1e-12)
        XCTAssertEqual(pins.pin(for: "session:b")?.xFraction ?? 9, 0.1, accuracy: 1e-12)
        var far = LiveCanvasPositions()
        far.set("session:far", xFraction: 3.5, y: 0, at: now)
        far.mirrorPerson("person:uma", aroundX: -3, pills: ["session:far"], at: now)
        XCTAssertEqual(far.pin(for: "session:far")?.xFraction, -LiveCanvasPositions.maxFraction, "held to the bounds, as a drag is")
    }

    /// (h) The flag is saved with the pins and an old record, written before it existed, still
    /// decodes; with no flag the record has no new field, so an older build reads it as before.
    func testTheMirrorFlagRoundTripsAndARecordFromBeforeItStillDecodes() throws {
        var pins = LiveCanvasPositions()
        pins.set("person:uma", xFraction: 0.25, y: 120.5, at: now)
        pins.setMirrored("person:uma", true)
        pins.setMirrored("person:bo", true)
        let data = try JSONEncoder().encode(pins)
        let decoded = try JSONDecoder().decode(LiveCanvasPositions.self, from: data)
        XCTAssertEqual(decoded, pins)
        XCTAssertEqual(decoded.mirrored, ["person:uma", "person:bo"])
        let plain = try JSONEncoder().encode(LiveCanvasPositions())
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("mirrored"), "no flag, no new field")
        let old = Data(#"{"pins":{"session:a":{"xFraction":0.25,"y":120,"savedAt":0},"person:uma":{"xFraction":0.5,"y":9,"savedAt":0}}}"#.utf8)
        let before = try JSONDecoder().decode(LiveCanvasPositions.self, from: old)
        XCTAssertEqual(before.pin(for: "session:a")?.xFraction, 0.25)
        XCTAssertEqual(before.pins.count, 2)
        XCTAssertTrue(before.mirrored.isEmpty)
        XCTAssertFalse(before.isMirrored("person:uma"))
        for odd in [#"{"pins":{},"mirrored":5}"#, #"{"pins":{},"mirrored":["person:a",3]}"#, #"{"pins":{},"mirrored":null}"#] {
            let tolerant = try JSONDecoder().decode(LiveCanvasPositions.self, from: Data(odd.utf8))
            XCTAssertTrue(tolerant.mirrored.isEmpty, odd)
        }
        let keepsPins = try JSONDecoder().decode(
            LiveCanvasPositions.self,
            from: Data(#"{"pins":{"session:a":{"xFraction":0.25,"y":120,"savedAt":0}},"mirrored":"nope"}"#.utf8))
        XCTAssertNotNil(keepsPins.pin(for: "session:a"), "a bad flag field does not cost the pins")
    }

    /// (i) The store keeps the flag under the same key as the pins, a record that holds only the
    /// flag is kept, and clearing the last of everything removes the record.
    func testTheStoreKeepsTheFlagUnderTheSameKey() {
        let suite = "org.example.hq.live-canvas-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveCanvasPositionsStore(hub: "https://hq.example/", personID: "me", defaults: defaults)
        XCTAssertTrue(store.key.hasPrefix("hq-live-canvas-positions-v1."), "the key did not change")
        var pins = LiveCanvasPositions()
        pins.setMirrored("person:uma", true)
        XCTAssertFalse(pins.isEmpty)
        store.save(pins, now: now)
        XCTAssertNotNil(defaults.data(forKey: store.key), "a flag alone is a record")
        XCTAssertTrue(store.load(now: now).isMirrored("person:uma"))
        XCTAssertTrue(store.load(now: now.addingTimeInterval(90 * 86_400)).isMirrored("person:uma"), "the flag does not age out")
        pins.setMirrored("person:uma", false)
        store.save(pins, now: now)
        XCTAssertNil(defaults.data(forKey: store.key), "nothing left, no record")
        // A record the build before this one wrote loads as it was.
        defaults.set(Data(#"{"pins":{"person:uma":{"xFraction":0.5,"y":9,"savedAt":0}}}"#.utf8), forKey: store.key)
        let loaded = store.load(now: Date(timeIntervalSince1970: 0))
        XCTAssertNotNil(loaded.pin(for: "person:uma"))
        XCTAssertTrue(loaded.mirrored.isEmpty)
    }

    /// (j) Reset Layout clears the flags with the pins, and "Put Back" on a person clears theirs.
    func testResetLayoutAndPutBackClearTheFlag() {
        var pins = LiveCanvasPositions()
        pins.set("person:uma", xFraction: 0.5, y: 9, at: now)
        pins.set("session:a", xFraction: 0.5, y: 9, at: now)
        pins.setMirrored("person:uma", true)
        pins.setMirrored("person:bo", true)
        XCTAssertTrue(pins.holds("person:bo"), "a mirrored person with no pin can still be put back")
        XCTAssertFalse(pins.contains("person:bo"))
        XCTAssertTrue(pins.holds("session:a"))
        XCTAssertFalse(pins.holds("session:zzz"))
        pins.remove("session:a")
        XCTAssertTrue(pins.isMirrored("person:uma"), "putting back a pill leaves a person's flag")
        pins.remove("person:bo")
        XCTAssertFalse(pins.isMirrored("person:bo"))
        XCTAssertTrue(pins.isMirrored("person:uma"))
        pins.remove("person:uma")
        XCTAssertNil(pins.pin(for: "person:uma"))
        XCTAssertFalse(pins.isMirrored("person:uma"), "Put Back clears the pin and the flag")
        XCTAssertTrue(pins.isEmpty)
        pins.setMirrored("person:uma", true)
        pins.set("session:a", xFraction: 0.5, y: 9, at: now)
        pins.removeAll()
        XCTAssertTrue(pins.isEmpty)
        XCTAssertFalse(pins.isMirrored("person:uma"))
        XCTAssertEqual(pins, LiveCanvasPositions(), "Reset Layout leaves nothing")
    }

    /// (k) A click mirrors on its second press, its fourth and so on: every even press of a run of
    /// quick clicks, so two double-clicks in a row flip and flip back. Press 0 (no click) and odd
    /// presses are single clicks.
    func testEveryEvenPressOfAQuickRunOfClicksMirrors() {
        XCTAssertEqual((0...6).filter { LiveCanvasLayout.isMirrorClick(clickCount: $0) }, [2, 4, 6])
    }

    // MARK: A drag bends only its own lines

    /// A drag lays nothing out until the drop: the moving nodes' lines are bent from where the drag
    /// has taken them (`lines(moving:)`) and every other line stays (`lines(excluding:)`). Together
    /// they must be exactly what the drop's layout draws, in pin space (the drop may move the
    /// canvas's corner), whether the drag stays inside the canvas or takes it past its top. Bob's
    /// pill is pinned above and left of the canvas first, so the drag's canvas does not start at zero.
    func testADragDrawsTheLinesTheDropLaysOut() {
        let shared = sharedTask()
        let threads = shared + [
            thread("s0", owner: "bo", minutesAgo: 3, projects: [("o0", "Project 0")]),
            thread("s1", owner: "bo", minutesAgo: 4, projects: [("o1", "Project 1")]),
            thread("s2", owner: "bob", minutesAgo: 3, projects: [("o0", "Project 0")]),
        ]
        let held = pinned([LiveCanvasPositions.sessionKey("s1"): (0.5, 400), LiveCanvasPositions.sessionKey("s2"): (-0.2, -200)])
        let auto = layoutNow(model: model(threads), width: 1000, pins: held)
        XCTAssertLessThan(auto.origin.x, 0)
        XCTAssertLessThan(auto.origin.y, 0)
        let bo = LiveCanvasPositions.personKey("bo")
        let moving = Set([bo]).union(auto.followers(of: [bo], pins: held))
        XCTAssertEqual(
            moving, [bo, LiveCanvasPositions.sessionKey("1"), LiveCanvasPositions.sessionKey("s0")],
            "a person carries their unpinned pills, not the pinned one")
        func pin(_ point: CGPoint, _ origin: CGPoint) -> CGPoint { CGPoint(x: point.x + origin.x, y: point.y + origin.y) }
        func assertSame(_ a: CGPoint, _ b: CGPoint, _ label: String) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.001, label)
            XCTAssertEqual(a.y, b.y, accuracy: 0.001, label)
        }
        for offset in [CGSize(width: 40, height: 60), CGSize(width: 120, height: -400)] {
            var centres: [String: CGPoint] = [:]
            for node in auto.nodes where moving.contains(node.pinKey) {
                let centre = auto.pinPoint(forDrawn: mid(node))
                centres[node.pinKey] = CGPoint(x: centre.x + offset.width, y: centre.y + offset.height)
            }
            let bent = auto.lines(moving: centres), still = auto.lines(excluding: moving)
            var pins = held
            let target = centres[bo]!
            pins.set(bo, xFraction: Double(target.x / auto.baseWidth), y: Double(target.y), at: now)
            let dropped = layoutNow(model: model(threads), width: 1000, pins: pins)
            XCTAssertFalse(bent.trees.isEmpty || bent.edges.isEmpty || bent.overlaps.isEmpty, "\(offset): every kind of line bends")
            XCTAssertFalse(still.edges.isEmpty, "\(offset): bob's lines stay")
            let drawnTrees = bent.trees.map { ($0, auto.origin) } + still.trees.map { ($0, auto.origin) }
            XCTAssertEqual(Set(drawnTrees.map(\.0.id)), Set(dropped.trees.map(\.id)))
            for tree in dropped.trees {
                guard let (drawn, origin) = drawnTrees.first(where: { $0.0.id == tree.id }) else { continue }
                assertSame(pin(drawn.from, origin), pin(tree.from, dropped.origin), "\(offset) tree \(tree.id)")
                assertSame(pin(drawn.to, origin), pin(tree.to, dropped.origin), "\(offset) tree \(tree.id)")
            }
            let drawnEdges = bent.edges + still.edges
            XCTAssertEqual(Set(drawnEdges.map(\.id)), Set(dropped.edges.map(\.id)))
            for edge in dropped.edges {
                guard let drawn = drawnEdges.first(where: { $0.id == edge.id }) else { continue }
                assertSame(pin(drawn.from, auto.origin), pin(edge.from, dropped.origin), "\(offset) edge \(edge.id)")
                assertSame(pin(drawn.to, auto.origin), pin(edge.to, dropped.origin), "\(offset) edge \(edge.id)")
            }
            let drawnArcs = bent.overlaps + still.overlaps
            XCTAssertEqual(drawnArcs.map(\.id), dropped.overlaps.map(\.id))
            for (drawn, arc) in zip(drawnArcs, dropped.overlaps) {
                for (a, b) in [(drawn.from, arc.from), (drawn.to, arc.to), (drawn.control1, arc.control1), (drawn.control2, arc.control2)] {
                    assertSame(pin(a, auto.origin), pin(b, dropped.origin), "\(offset) arc")
                }
            }
        }
    }
}

/// The Live canvas's box selection rules, pure: the box a drag draws, which cards it
/// touches, Shift adding, Shift-click toggling, a card leaving the canvas, who moves with a drag,
/// and who "Put Back" sets down. The gestures that feed them are in `LiveCanvasGestureTests`.
final class LiveCanvasSelectionTests: XCTestCase {
    private func node(_ kind: LiveCanvasLayout.Kind, _ id: String, _ frame: CGRect) -> LiveCanvasLayout.Node {
        LiveCanvasLayout.Node(kind: kind, refId: id, frame: frame, side: .center)
    }

    /// Three cards in a row, 100 wide with 20 between them, and one below.
    private var nodes: [LiveCanvasLayout.Node] {
        [
            node(.session, "a", CGRect(x: 0, y: 0, width: 100, height: 40)),
            node(.session, "b", CGRect(x: 120, y: 0, width: 100, height: 40)),
            node(.person, "uma", CGRect(x: 240, y: 0, width: 100, height: 40)),
            node(.hub, "o", CGRect(x: 0, y: 200, width: 100, height: 40)),
        ]
    }

    func testTheBoxIsTheSameWhicheverWayItIsDragged() {
        let expected = CGRect(x: 10, y: 20, width: 30, height: 40)
        for (start, end) in [
            (CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 60)), (CGPoint(x: 40, y: 60), CGPoint(x: 10, y: 20)),
            (CGPoint(x: 40, y: 20), CGPoint(x: 10, y: 60)), (CGPoint(x: 10, y: 60), CGPoint(x: 40, y: 20)),
        ] {
            XCTAssertEqual(LiveCanvasSelection.rect(from: start, to: end), expected)
        }
    }

    func testABoxTakesEveryCardItTouchesAndNoOtherAndAnEdgeCounts() {
        XCTAssertEqual(
            LiveCanvasSelection.keys(in: CGRect(x: 90, y: 10, width: 40, height: 10), nodes: nodes),
            ["session:a", "session:b"], "a box over the gap reaches both sides")
        XCTAssertEqual(
            LiveCanvasSelection.keys(in: CGRect(x: 100, y: 10, width: 20, height: 10), nodes: nodes),
            ["session:a", "session:b"], "a box that only touches the edges counts")
        XCTAssertEqual(
            LiveCanvasSelection.keys(in: CGRect(x: 105, y: 10, width: 10, height: 10), nodes: nodes), [],
            "a box inside the gap touches nothing")
        XCTAssertEqual(
            LiveCanvasSelection.keys(in: CGRect(x: -10, y: -10, width: 500, height: 500), nodes: nodes),
            Set(nodes.map(\.pinKey)), "a box over everything takes every kind of card")
    }

    func testABoxWithNoHeightFromAFlatDragStillTouches() {
        XCTAssertEqual(
            LiveCanvasSelection.keys(in: CGRect(x: 50, y: 20, width: 100, height: 0), nodes: nodes),
            ["session:a", "session:b"])
    }

    func testShiftAddsTheBoxToTheSelectionAndWithoutItTheBoxReplacesIt() {
        let current: Set<String> = ["session:a"]
        XCTAssertEqual(
            LiveCanvasSelection.boxed(["person:uma"], into: current, isAdditive: true), ["session:a", "person:uma"])
        XCTAssertEqual(LiveCanvasSelection.boxed(["person:uma"], into: current, isAdditive: false), ["person:uma"])
        XCTAssertEqual(
            LiveCanvasSelection.boxed([], into: current, isAdditive: false), [], "a box over nothing clears it")
        XCTAssertEqual(LiveCanvasSelection.boxed([], into: current, isAdditive: true), current)
    }

    func testShiftClickTogglesACard() {
        let once = LiveCanvasSelection.toggled("session:a", in: [])
        XCTAssertEqual(once, ["session:a"])
        XCTAssertEqual(LiveCanvasSelection.toggled("session:b", in: once), ["session:a", "session:b"])
        XCTAssertEqual(LiveCanvasSelection.toggled("session:a", in: once), [])
    }

    func testACardThatLeavesTheCanvasLeavesTheSelection() {
        let selection: Set<String> = ["session:a", "session:gone", "person:uma"]
        XCTAssertEqual(LiveCanvasSelection.present(selection, nodes: nodes), ["session:a", "person:uma"])
        XCTAssertEqual(LiveCanvasSelection.present([], nodes: nodes), [])
    }

    func testADragOnASelectedCardMovesTheWholeSelectionAndOnAnotherCardOnlyIt() {
        let selection: Set<String> = ["session:a", "session:b"]
        XCTAssertEqual(LiveCanvasSelection.movers(dragging: "session:b", selection: selection), selection)
        XCTAssertEqual(LiveCanvasSelection.movers(dragging: "person:uma", selection: selection), ["person:uma"])
        XCTAssertEqual(LiveCanvasSelection.movers(dragging: "person:uma", selection: []), ["person:uma"])
    }

    func testShiftAddsAnUnselectedCardToTheDraggedSelection() {
        let selection: Set<String> = ["session:a", "session:b"]
        XCTAssertEqual(
            LiveCanvasSelection.movers(dragging: "person:uma", selection: selection, isAdditive: true),
            ["session:a", "session:b", "person:uma"], "Shift-dragging an unselected card takes the selection along")
        XCTAssertEqual(
            LiveCanvasSelection.movers(dragging: "session:b", selection: selection, isAdditive: true), selection,
            "a selected card moves the selection, Shift or not")
        XCTAssertEqual(
            LiveCanvasSelection.movers(dragging: "person:uma", selection: selection, isAdditive: false), ["person:uma"])
    }

    func testAGroupStopsTogetherAtThePinBoundsAndKeepsItsSpacing() {
        let base: CGFloat = 900
        let right = CGFloat(LiveCanvasPositions.maxFraction) * base
        let origins = [CGPoint(x: 200, y: 100), CGPoint(x: 700, y: 400)]
        // Far past the right bound: the card that began further right reaches it, and the other keeps 500pt behind.
        let pushed = LiveCanvasSelection.groupOffset(CGSize(width: 9_000, height: 0), origins: origins, baseWidth: base)
        XCTAssertEqual(pushed.width, right - 700, accuracy: 0.001)
        XCTAssertEqual(origins[0].x + pushed.width, right - 500, accuracy: 0.001, "the nearer card stops 500pt short, as it began")
        // Past the left bound, the card that began further left is the one that stops them.
        let pulled = LiveCanvasSelection.groupOffset(CGSize(width: -9_000, height: 0), origins: origins, baseWidth: base)
        XCTAssertEqual(origins[0].x + pulled.width, -right, accuracy: 0.001)
        XCTAssertEqual(origins[1].x + pulled.width, -right + 500, accuracy: 0.001)
        // Vertically the same, against the 10 000pt bound.
        let dropped = LiveCanvasSelection.groupOffset(CGSize(width: 0, height: 99_999), origins: origins, baseWidth: base)
        XCTAssertEqual(origins[1].y + dropped.height, CGFloat(LiveCanvasPositions.maxY), accuracy: 0.001)
        XCTAssertEqual(origins[0].y + dropped.height, CGFloat(LiveCanvasPositions.maxY) - 300, accuracy: 0.001)
    }

    func testAMoveInsideTheBoundsIsNotHeldAndOneCardIsHeldAtItsOwnBound() {
        let base: CGFloat = 900
        let origins = [CGPoint(x: 200, y: 100), CGPoint(x: 700, y: 400)]
        XCTAssertEqual(
            LiveCanvasSelection.groupOffset(CGSize(width: 120, height: -80), origins: origins, baseWidth: base),
            CGSize(width: 120, height: -80))
        XCTAssertEqual(LiveCanvasSelection.groupOffset(CGSize(width: 5, height: 5), origins: [], baseWidth: base), CGSize(width: 5, height: 5))
        let lone = LiveCanvasSelection.groupOffset(CGSize(width: 9_000, height: 0), origins: [CGPoint(x: 200, y: 0)], baseWidth: base)
        XCTAssertEqual(200 + lone.width, CGFloat(LiveCanvasPositions.maxFraction) * base, accuracy: 0.001)
    }

    func testPutBackSetsDownEverySelectedPinnedCardInAFixedOrder() {
        let pinned: Set<String> = ["session:b", "session:a", "person:uma"]
        let selection: Set<String> = ["session:b", "session:a", "hub:o"]
        XCTAssertEqual(
            LiveCanvasSelection.putBackKeys(for: "session:a", selection: selection, isPinned: { pinned.contains($0) }),
            ["session:a", "session:b"], "the selected pinned ones; the unpinned selected card is skipped")
        XCTAssertEqual(
            LiveCanvasSelection.putBackKeys(for: "person:uma", selection: selection, isPinned: { pinned.contains($0) }),
            ["person:uma"], "a pinned card outside the selection puts back only itself")
        XCTAssertEqual(
            LiveCanvasSelection.putBackKeys(for: "session:z", selection: selection, isPinned: { pinned.contains($0) }), [],
            "an unpinned card outside the selection has nothing to put back")
    }
}

/// A fixed shuffle, so the order is the same on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

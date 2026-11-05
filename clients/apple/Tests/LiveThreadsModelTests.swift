import XCTest

#if !LISTING_HEADLESS
@testable import HQ
#endif

/// The Live list's rules: grouping, naming, folding, the cap, the
/// overlap chips, the ended filter and the age marks.
final class LiveThreadsModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func thread(
        _ id: String, owner: String = "ada", name: String? = nil, minutesAgo: Double = 1,
        title: String? = nil, intent: String = "", state: String = "idle", branch: String? = nil,
        tasks: [(String, String, String)] = [], projects: [(String, String)] = []
    ) -> CodingThread {
        var json: [String: Any] = [
            "session_id": id, "intent": intent, "state": state,
            "last_seen_at": 0.0, "last_activity_at": (now.timeIntervalSince1970 - minutesAgo * 60) * 1000,
            "owner_person_id": owner, "owner_name": name ?? owner.capitalized,
            "provider": "claude", "repo": "tmp-worktree-7",
            "tasks": tasks.map { ["id": $0.0, "ref": $0.1, "title": $0.2] },
            "projects": projects.map { ["id": $0.0, "name": $0.1] },
        ]
        if let title { json["title"] = title }
        if let branch { json["git_branch"] = branch }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(CodingThread.self, from: data)
    }

    private func model(_ threads: [CodingThread], search: String = "", removed: Set<String> = []) -> LiveThreadsModel {
        LiveThreadsModel(threads: threads, now: now, search: search, isRemoved: { removed.contains($0) })
    }

    /// The launch cache writes the sessions back out: Agents reopens from them unchanged.
    func testACachedSessionReadsBackTheSame() throws {
        let session = thread(
            "s1", title: "Cache", branch: "e3/x", tasks: [("t1", "HQ-\(1)", "Task")], projects: [("p1", "HQ")])
        XCTAssertEqual(try JSONDecoder().decode(CodingThread.self, from: JSONEncoder().encode(session)), session)
    }

    func testPeopleOrderByMostRecentActivityAndSessionsByRecency() {
        let result = model([
            thread("a1", owner: "ada", minutesAgo: 30, title: "Older"),
            thread("b1", owner: "bo", minutesAgo: 2, title: "Newest"),
            thread("a2", owner: "ada", minutesAgo: 5, title: "Newer"),
        ])
        XCTAssertEqual(result.groups.map(\.name), ["Bo", "Ada"])
        XCTAssertEqual(result.groups[1].named.map(\.id), ["a2", "a1"])
        XCTAssertEqual(result.groups[1].agentCount, 2)
    }

    func testRemovedOwnersAndSessionsPastADayNeverAppear() {
        let result = model([
            thread("keep", title: "Kept"),
            thread("gone", owner: "pat", title: "Left the company"),
            thread("ancient", owner: "kim", minutesAgo: 1441, title: "Over a day"),
        ], removed: ["pat"])
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.groups.map(\.id), ["ada"])
        XCTAssertEqual(result.groups.flatMap(\.named).map(\.id), ["keep"])
    }

    func testTheHubIsAskedForADayAndAgentsAreTheLastThreeHours() {
        XCTAssertEqual(LiveThreadsModel.windowMinutes, 1440)
        XCTAssertEqual(LiveThreadsModel.liveMinutes, 180)
    }

    func testOlderAndEndedSessionsFoldIntoEarlierNeverDropped() {
        let result = model([
            thread("live", minutesAgo: 10, title: "Live"),
            thread("edge", minutesAgo: 179, title: "Just inside"),
            thread("old", minutesAgo: 181, title: "Four hours ago"),
            thread("late", minutesAgo: 600, title: "Ten hours ago"),
            thread("done", minutesAgo: 5, title: "Ended", state: "ended"),
        ])
        let group = result.groups[0]
        XCTAssertEqual(group.named.map(\.id), ["live", "edge"])
        XCTAssertEqual(group.earlier.map(\.id), ["done", "old", "late"], "ended and older ones, most recent first")
        XCTAssertEqual(group.agentCount, 2, "agents are the last three hours")
        XCTAssertEqual(result.total, 2)
        let items = result.items(group, expanded: [])
        XCTAssertEqual(items.last, .earlier(key: LiveThreadsModel.earlierKey("ada"), count: 3))
        XCTAssertEqual(items.count, 3)
        let open = result.items(group, expanded: [LiveThreadsModel.earlierKey("ada")])
        XCTAssertEqual(open.count, 5)
        XCTAssertEqual(open.suffix(3).compactMap { if case .row(let row) = $0 { row.id } else { nil } }, ["done", "old", "late"])
    }

    func testEarlierSessionsDoNotCountAsAgentsOrFeedTheAlsoChips() {
        let shared = ("t9", "HQ-\(900)", "Ship the thing")
        let result = model([
            thread("1", owner: "ada", title: "Live", tasks: [shared]),
            thread("2", owner: "bo", minutesAgo: 400, title: "Earlier", tasks: [shared]),
        ])
        XCTAssertEqual(result.groups.first { $0.id == "ada" }?.named[0].alsoNames, [])
        XCTAssertEqual(result.groups.first { $0.id == "bo" }?.agentCount, 0)
    }

    func testAPersonWithOnlyEarlierSessionsIsAGroupAfterThoseWithAgents() {
        let result = model([
            thread("old", owner: "bo", minutesAgo: 1000, title: "Earlier"),
            thread("now", owner: "ada", minutesAgo: 90, title: "Live"),
        ])
        XCTAssertEqual(result.groups.map(\.id), ["ada", "bo"])
        XCTAssertFalse(result.groups[1].hasLive)
        XCTAssertEqual(result.groups[1].earlier.map(\.id), ["old"])
        XCTAssertEqual(result.total, 1)
    }

    func testSearchListsEarlierMatchesUnfolded() {
        let threads = [thread("a", title: "Mailer fix"), thread("b", minutesAgo: 500, title: "Mailer old"), thread("c", minutesAgo: 500, title: "Other")]
        let result = model(threads, search: "mailer")
        let items = result.items(result.groups[0], expanded: [])
        XCTAssertEqual(items.compactMap { if case .row(let row) = $0 { row.id } else { nil } }, ["a", "b"])
        XCTAssertEqual(result.groups[0].agentCount, 1)
    }

    func testIdlePeopleAreTheRosterAndEarlierOnlyOwnersWithNoAgents() {
        let roster: [LiveThreadsModel.Idle] = [.init(id: "ada", name: "Ada"), .init(id: "zed", name: "Zed"), .init(id: "yan", name: "Yan")]
        let result = LiveThreadsModel(
            threads: [thread("a", title: "Live"), thread("b", owner: "pat", minutesAgo: 500, title: "Earlier")],
            now: now, search: "", isRemoved: { _ in false }, roster: roster)
        XCTAssertEqual(result.idle.map(\.id), ["pat", "yan", "zed"], "Ada has an agent; the rest by name")
        let searching = LiveThreadsModel(
            threads: [thread("a", title: "Live")], now: now, search: "live", isRemoved: { _ in false }, roster: roster)
        XCTAssertTrue(searching.idle.isEmpty)
    }

    /// The canvas fixes sides over everyone it knows, so the roster must not change with a search.
    func testTheRosterIsEveryKnownPersonByIdAndStaysFilledWhileSearching() {
        let roster: [LiveThreadsModel.Idle] = [
            .init(id: "ada", name: "Ada"), .init(id: "zed", name: "Zed"), .init(id: "yan", name: "Yan"), .init(id: "old", name: "Old"),
        ]
        let threads = [thread("a", title: "Live"), thread("b", owner: "pat", minutesAgo: 500, title: "Earlier")]
        let plain = LiveThreadsModel(threads: threads, now: now, search: "", isRemoved: { $0 == "old" }, roster: roster)
        XCTAssertEqual(plain.roster.map(\.id), ["ada", "pat", "yan", "zed"], "the roster, every group owner, no one removed, by id")
        XCTAssertEqual(plain.roster.first { $0.id == "pat" }?.name, "Pat")
        let searching = LiveThreadsModel(threads: threads, now: now, search: "live", isRemoved: { $0 == "old" }, roster: roster)
        XCTAssertEqual(searching.groups.map(\.id), ["ada"], "the search hides Pat's rows")
        XCTAssertTrue(searching.idle.isEmpty, "idle stays empty while searching")
        XCTAssertEqual(searching.roster, plain.roster, "the roster does not follow the search")
    }

    func testNameFallbackChain() {
        let real = ("t1", "HQ-\(1223)", "Fix the importer")
        XCTAssertEqual(model([thread("1", title: "A title", intent: "An intent")]).groups[0].named[0].fullName, "A title")
        let byIntent = model([thread("2", intent: "An intent", tasks: [real])]).groups[0].named[0]
        XCTAssertEqual(byIntent.fullName, "An intent")
        XCTAssertEqual(byIntent.nameSource, .intent)
        let byTask = model([thread("3", branch: "feat/x", tasks: [real])]).groups[0].named[0]
        XCTAssertEqual(byTask.fullName, "Fix the importer")
        XCTAssertEqual(byTask.nameSource, .task)
        XCTAssertTrue(byTask.isFallbackName)
        // A branch names a session, so it does not fold under "no name or task".
        let branchGroup = model([thread("4", branch: "feat/x")]).groups[0]
        XCTAssertTrue(branchGroup.unnamed.isEmpty)
        let byBranch = branchGroup.named[0]
        XCTAssertEqual(byBranch.fullName, "feat/x")
        XCTAssertEqual(byBranch.nameSource, .branch)
        let bare = model([thread("5")]).groups[0].unnamed[0]
        XCTAssertEqual(bare.fullName, "Untitled")
    }

    func testRepoFolderNeverNamesASession() {
        let row = model([thread("1")]).groups[0].unnamed[0]
        XCTAssertFalse(row.fullName.contains("tmp-worktree"))
    }

    func testLongNamesTruncateButKeepTheFullText() {
        let long = String(repeating: "word ", count: 20)
        let row = model([thread("1", title: long)]).groups[0].named[0]
        XCTAssertEqual(row.name.count, LiveThreadsModel.nameLimit)
        XCTAssertTrue(row.name.hasSuffix("…"))
        XCTAssertEqual(row.fullName, long.trimmingCharacters(in: .whitespaces))
    }

    func testTaskLabels() {
        let real = ("t1", "HQ-\(1223)", "Fix the importer")
        let rows = model([
            thread("one", title: "One task", tasks: [real]),
            thread("none", minutesAgo: 3, title: "No task"),
        ]).groups[0].named
        XCTAssertEqual(rows.first { $0.id == "one" }?.label, .task("HQ-\(1223)"))
        XCTAssertEqual(rows.first { $0.id == "one" }?.labelText, "HQ-\(1223)")
        XCTAssertEqual(rows.first { $0.id == "none" }?.label, LiveThreadsModel.TaskLabel.none)
        XCTAssertNil(rows.first { $0.id == "none" }?.labelText)
    }

    func testSessionsWithNoNameOrTaskFold() {
        let result = model([
            thread("named", title: "Named"),
            thread("a", minutesAgo: 2),
            thread("b", minutesAgo: 3),
            thread("c", minutesAgo: 4, branch: "wip"),
        ])
        let group = result.groups[0]
        XCTAssertEqual(group.named.map(\.id), ["named", "c"])  // a branch is a name
        XCTAssertEqual(group.unnamed.map(\.id), ["a", "b"])
        XCTAssertEqual(group.agentCount, 4)
        let folded = result.items(group, expanded: [])
        XCTAssertEqual(folded.count, 3)
        XCTAssertEqual(folded.last, .folded(key: LiveThreadsModel.foldedKey("ada"), count: 2))
        let open = result.items(group, expanded: [LiveThreadsModel.foldedKey("ada")])
        XCTAssertEqual(open.count, 4)
    }

    func testPerPersonCapOfEightExpandsInPlace() {
        let threads = (0..<12).map { thread("s\($0)", minutesAgo: Double($0 + 1), title: "Task \($0)") }
        let result = model(threads)
        let group = result.groups[0]
        let capped = result.items(group, expanded: [])
        XCTAssertEqual(capped.count, 9)
        XCTAssertEqual(capped.last, .more(key: LiveThreadsModel.moreKey("ada"), count: 4))
        XCTAssertEqual(result.items(group, expanded: [LiveThreadsModel.moreKey("ada")]).count, 12)
        XCTAssertEqual(group.agentCount, 12)
    }

    func testSearchListsEveryMatchUnfolded() {
        let threads = (0..<12).map { thread("s\($0)", minutesAgo: Double($0 + 1), title: "Task \($0)") }
            + [thread("other", owner: "bo", title: "Unrelated")]
        let result = model(threads, search: "task")
        XCTAssertEqual(result.total, 12)
        XCTAssertEqual(result.items(result.groups[0], expanded: []).count, 12)
        XCTAssertEqual(model(threads, search: "bo").groups.map(\.name), ["Bo"])
        XCTAssertTrue(model(threads, search: "zzz").groups.isEmpty)
    }

    func testSharedTaskBetweenTwoOwnersShowsAnAlsoChip() {
        let shared = ("t9", "HQ-\(900)", "Ship the thing")
        let result = model([
            thread("1", owner: "ada", title: "Ada side", tasks: [shared]),
            thread("2", owner: "bo", title: "Bo side", tasks: [shared]),
            thread("3", owner: "pat", title: "Alone", tasks: [("t10", "HQ-\(901)", "Else")]),
            thread("4", owner: "ada", minutesAgo: 9, title: "Same owner twice", tasks: [shared]),
        ])
        let rows = Dictionary(uniqueKeysWithValues: result.groups.flatMap(\.named).map { ($0.id, $0) })
        XCTAssertEqual(rows["1"]?.alsoNames, ["Bo"])
        XCTAssertEqual(rows["1"]?.alsoText, "Also Bo")
        XCTAssertEqual(rows["2"]?.alsoNames, ["Ada"])
        XCTAssertEqual(rows["3"]?.alsoNames, [])
        XCTAssertEqual(rows["4"]?.alsoNames, ["Bo"])
    }

    func testAgeBucketsAndText() {
        XCTAssertEqual(LiveThreadsModel.Age.bucket(0), .fresh)
        XCTAssertEqual(LiveThreadsModel.Age.bucket(599), .fresh)
        XCTAssertEqual(LiveThreadsModel.Age.bucket(600), .recent)
        XCTAssertEqual(LiveThreadsModel.Age.bucket(3599), .recent)
        XCTAssertEqual(LiveThreadsModel.Age.bucket(3600), .stale)
        XCTAssertEqual(LiveThreadsModel.ageText(20), "now")
        XCTAssertEqual(LiveThreadsModel.ageText(4 * 60), "4m")
        XCTAssertEqual(LiveThreadsModel.ageText(59 * 60 + 59), "59m")
        XCTAssertEqual(LiveThreadsModel.ageText(133 * 60), "2h 13m")
        XCTAssertEqual(LiveThreadsModel.ageText(180 * 60), "3h")
        XCTAssertEqual(LiveThreadsModel.ageText(-30), "now")
    }

    func testRowCarriesTheAgeFromLastActivityAtOnly() {
        let row = model([thread("1", minutesAgo: 133, title: "Old")]).groups[0].named[0]
        XCTAssertEqual(row.ageText, "2h 13m")
        XCTAssertEqual(row.age, .stale)
    }

    func testAccessibilityLabelReadsNameOwnerAgeTask() {
        let row = model([thread("1", minutesAgo: 4, title: "Fix it", tasks: [("t1", "HQ-\(5)", "Five")])]).groups[0].named[0]
        XCTAssertEqual(row.accessibilityText, "Fix it, Ada, 4m ago, HQ-\(5)")
    }

    func testDecodesWithoutTheOptionalFields() throws {
        let json = #"{"session_id":"x","intent":"","state":"idle","last_seen_at":1,"owner_person_id":"p","owner_name":"P","provider":"claude","tasks":[],"projects":[]}"#
        let decoded = try JSONDecoder().decode(CodingThread.self, from: Data(json.utf8))
        XCTAssertNil(decoded.gitBranch)
    }

    // MARK: Detail agrees with the list

    func testDetailHeaderNameMatchesLiveRowName() {
        let task = [("t1", "HQ-\(9)", "Fix the mailer")]
        let cases = [
            thread("a", tasks: task),
            thread("b", branch: "ada/live-list"),
            thread("c"),
            thread("d", title: "Titled", intent: "Something else"),
            thread("e", intent: "Only an intent"),
        ]
        let rows = model(cases).groups.flatMap { $0.named + $0.unnamed }
        XCTAssertEqual(rows.count, 5)
        for t in cases {
            let row = rows.first { $0.id == t.sessionId }!
            XCTAssertEqual(LiveThreadsModel.headerName(for: t, sessionTitle: nil), row.fullName, t.sessionId)
        }
        XCTAssertEqual(LiveThreadsModel.headerName(for: cases[0], sessionTitle: nil), "Fix the mailer")
        XCTAssertEqual(LiveThreadsModel.headerName(for: cases[1], sessionTitle: " "), "ada/live-list")
        XCTAssertEqual(LiveThreadsModel.headerName(for: cases[2], sessionTitle: nil), "Untitled")
        XCTAssertEqual(LiveThreadsModel.headerName(for: cases[2], sessionTitle: "Stored title"), "Stored title")
    }

    func testDetailActivityLineUsesLiveAgeText() {
        XCTAssertEqual(LiveThreadsModel.activityLine(for: thread("a", minutesAgo: 4), now: now), "Last activity 4m ago")
        XCTAssertEqual(LiveThreadsModel.activityLine(for: thread("a", minutesAgo: 133), now: now), "Last activity 2h 13m ago")
        XCTAssertEqual(LiveThreadsModel.activityLine(for: thread("a", minutesAgo: 0), now: now), "Active now")
    }

    func testAgentCountFollowsTheRowsShownWhileSearching() {
        let all = [thread("a", title: "Mailer fix"), thread("b", title: "Other"), thread("c", title: "Else")]
        XCTAssertEqual(model(all).groups.first?.agentCount, 3)
        XCTAssertEqual(model(all, search: "mailer").groups.first?.agentCount, 1)
    }

    // MARK: Page walk

    private struct Boom: Error {}

    /// Pages of two sessions each, keyed by cursor; counts loads.
    private func loader(_ pages: [String?: (ids: [String], next: String?)], failOn: String?? = nil,
                        calls: Box = Box()) -> LiveThreadsModel.PageLoader {
        { cursor in
            calls.n += 1
            if let failOn, failOn == cursor { throw Boom() }
            let page = pages[cursor] ?? ([], nil)
            return (page.ids.map { self.thread($0) }, page.next)
        }
    }
    private final class Box { var n = 0 }

    func testWalkFollowsEveryPageUntilNullCursor() async {
        let calls = Box()
        let walk = await LiveThreadsModel.walk(pages: loader([
            nil: (["a", "b"], "b"), "b": (["c", "d"], "d"), "d": (["e"], nil),
        ], calls: calls))
        XCTAssertEqual(walk.threads.map(\.sessionId), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(calls.n, 3)
        XCTAssertNil(walk.failure)
    }

    func testWalkStopsOnARepeatedCursor() async {
        let calls = Box()
        let walk = await LiveThreadsModel.walk(pages: loader([
            nil: (["a"], "x"), "x": (["b"], "y"), "y": (["c"], "x"),
        ], calls: calls))
        XCTAssertEqual(walk.threads.map(\.sessionId), ["a", "b", "c"])
        XCTAssertEqual(calls.n, 3)
    }

    func testWalkKeepsEarlierPagesWhenAPageThrows() async {
        let walk = await LiveThreadsModel.walk(pages: loader([
            nil: (["a", "b"], "b"), "b": (["c"], "c"), "c": (["d"], nil),
        ], failOn: .some("b")))
        XCTAssertEqual(walk.threads.map(\.sessionId), ["a", "b"])
        XCTAssertNotNil(walk.failure)
    }

    func testWalkReportsAFailureOnTheFirstPage() async {
        let walk = await LiveThreadsModel.walk(pages: loader([nil: (["a"], nil)], failOn: .some(nil)))
        XCTAssertTrue(walk.threads.isEmpty)
        XCTAssertNotNil(walk.failure)
    }

    // MARK: Resolving a walk against the held list

    private func walkResult(_ ids: [String], failed: Bool) -> LiveThreadsModel.Walk {
        LiveThreadsModel.Walk(threads: ids.map { thread($0) }, failure: failed ? Boom() : nil)
    }

    func testCompleteWalkReplacesTheHeldList() {
        let held = [thread("a"), thread("b"), thread("c")]
        let out = LiveThreadsModel.resolve(walkResult(["a"], failed: false), held: held, hasLoaded: true)
        XCTAssertEqual(out.threads.map(\.sessionId), ["a"])
        XCTAssertTrue(out.hasLoaded)
        XCTAssertFalse(out.failed)
    }

    func testFailedWalkNeverShrinksAHeldList() {
        let held = [thread("a"), thread("b"), thread("c")]
        let out = LiveThreadsModel.resolve(walkResult(["a"], failed: true), held: held, hasLoaded: true)
        XCTAssertEqual(out.threads.map(\.sessionId), ["a", "b", "c"])
        XCTAssertTrue(out.failed)
    }

    func testFailedFirstWalkShowsWhatItGotAndFails() {
        let out = LiveThreadsModel.resolve(walkResult(["a", "b"], failed: true), held: [], hasLoaded: false)
        XCTAssertEqual(out.threads.map(\.sessionId), ["a", "b"])
        XCTAssertTrue(out.hasLoaded)
        XCTAssertTrue(out.failed)
    }

    func testFailedFirstWalkThatGotNothingStaysUnloaded() {
        let out = LiveThreadsModel.resolve(walkResult([], failed: true), held: [], hasLoaded: false)
        XCTAssertTrue(out.threads.isEmpty)
        XCTAssertFalse(out.hasLoaded)
        XCTAssertTrue(out.failed)
    }

    /// A quiet read leaves a fresh clock alone, but not one the minute tick stopped moving while
    /// the page was away: half an hour later, the first read shows today's ages.
    func testAQuietReadMovesOnlyAMinuteOldClock() {
        let clock = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(LiveThreadsModel.shouldMoveClock(changed: true, clock: clock, at: clock.addingTimeInterval(5)))
        XCTAssertFalse(LiveThreadsModel.shouldMoveClock(changed: false, clock: clock, at: clock.addingTimeInterval(59)))
        XCTAssertTrue(LiveThreadsModel.shouldMoveClock(changed: false, clock: clock, at: clock.addingTimeInterval(60)))
        XCTAssertTrue(LiveThreadsModel.shouldMoveClock(changed: false, clock: clock, at: clock.addingTimeInterval(30 * 60)))
    }
}

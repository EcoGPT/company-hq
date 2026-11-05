import XCTest

@testable import HQ

/// The desktop widgets' wire (`GET /v1/widgets/summary`), their links, and the names they derive.
final class WidgetSummaryTests: XCTestCase {
    func testTheSampleDecodesLikeTheServersPayload() throws {
        let summary = try XCTUnwrap(WidgetSummary.sample)
        XCTAssertEqual(summary.version, 1)
        XCTAssertEqual(summary.me.name, "Ada")
        XCTAssertNil(summary.me.avatarId)
        XCTAssertEqual(summary.work.total, 10)
        XCTAssertEqual(summary.work.doneWeek, 4)
        XCTAssertEqual(summary.work.tasks.count, 9, "the counts cover every task, the cards a few of each status")
        let first = try XCTUnwrap(summary.work.tasks.first)
        XCTAssertEqual(first.ref, "HQ-\(41)")
        XCTAssertEqual(first.projectName, "Docs site")
        XCTAssertEqual(first.commentCount, 2)
        XCTAssertTrue(first.isInProgress)
        XCTAssertTrue(try XCTUnwrap(summary.work.tasks.first { $0.id == "t33" }).isBlocked)
        let due = try XCTUnwrap(summary.work.nextDue)
        XCTAssertEqual(due.title, "Plan the autumn release")
        XCTAssertEqual(due.dueAt, WidgetDates.parse("2026-10-11T00:00:00.000Z"))
    }

    func testATaskWithNoNumberOrBoardStillDecodes() throws {
        let json = WidgetSummary.sampleJSON
            .replacingOccurrences(of: #""number": 45, "ref": "HQ-\#(45)""#, with: #""number": null, "ref": null"#)
        let summary = try WidgetSummary.decode(Data(json.utf8))
        let task = try XCTUnwrap(summary.work.tasks.first { $0.title == "Triage new bug reports" })
        XCTAssertNil(task.number)
        XCTAssertNil(task.ref)
        XCTAssertNil(task.projectName)
    }

    func testDatesWithAndWithoutMilliseconds() {
        XCTAssertNotNil(WidgetDates.parse("2026-09-28T12:15:00.000Z"))
        XCTAssertNotNil(WidgetDates.parse("2026-09-28T12:15:00Z"))
        XCTAssertNil(WidgetDates.parse("yesterday"))
    }

    func testLinksRoundTripAndRefuseAnythingElse() {
        let links: [WidgetLink] = [.task("t1"), .task("abc-123"), .task("p_9"), .mine]
        for link in links {
            XCTAssertEqual(WidgetLink(url: link.url), link)
        }
        XCTAssertNil(WidgetLink(url: URL(string: "hq://thread/s1")!))
        XCTAssertNil(WidgetLink(url: URL(string: "hq://task/")!))
        XCTAssertNil(WidgetLink(url: URL(string: "hq://task/a/b")!))
        XCTAssertNil(WidgetLink(url: URL(string: "hq://mine/extra")!))
        XCTAssertNil(WidgetLink(url: URL(string: "https://task/t1")!))
        XCTAssertNil(WidgetLink(url: URL(string: "hq://task/t1?x=1")!))
    }

    func testNamesComeFromTheBundleAndAnAppGroupNeedsATeam() {
        let bundle = Bundle.main.bundleIdentifier ?? "hq"
        XCTAssertEqual(WidgetIdentity.appBundleID, bundle)
        XCTAssertEqual(WidgetIdentity.logSubsystem, bundle)
        XCTAssertEqual(WidgetIdentity.kindPrefix, "\(bundle).widgets.")
        // The test build is the default `local` mode: no team, so no App Group, no shelf and no sync.
        XCTAssertNil(WidgetIdentity.appGroup)
        XCTAssertFalse(WidgetShelf.isAvailable)
        XCTAssertFalse(WidgetSync.isBuilt)
    }
}

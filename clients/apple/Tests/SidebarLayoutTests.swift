import XCTest

#if !SIDEBAR_LAYOUT_HEADLESS
@testable import HQ
#endif

final class SidebarLayoutTests: XCTestCase {
    func testPausedDragDoesNotSnapBeforeMouseRelease() {
        XCTAssertEqual(settle(150, isDragging: true), .wait)
        XCTAssertEqual(settle(150), .rail)
    }

    func testProgrammaticMoveCannotOverwriteRememberedListWidth() {
        XCTAssertEqual(settle(220, isMoving: true), .wait)
        XCTAssertEqual(settle(90), .rail)
        XCTAssertEqual(settle(325), .list(325))
    }

    func testWidthThresholdMatchesRenderedRail() {
        XCTAssertEqual(settle(189), .rail)
        XCTAssertEqual(settle(190), .list(190))
    }

    func testTransientCollapsedAndInvalidGeometryIsIgnored() {
        for width: CGFloat in [0, 1, 64, .nan, .infinity] {
            XCTAssertEqual(settle(width), .ignore)
        }
    }

    func testDetailsPreserveMinimumChatSpaceIncludingDivider() {
        XCTAssertEqual(settle(280, available: 960, hasDetails: true), .rail)
        XCTAssertEqual(settle(280, available: 961, hasDetails: true), .list(280))
        XCTAssertEqual(settle(280, available: 860, hasDetails: false), .list(280))
    }

    func testStoredWidthsRemainWithinSupportedBounds() {
        XCTAssertEqual(SidebarMetrics.listWidth(325), 325)
        XCTAssertEqual(SidebarMetrics.listWidth(0), 190)
        XCTAssertEqual(SidebarMetrics.listWidth(900), 380)
        XCTAssertEqual(SidebarMetrics.listWidth(.nan), 280)
        XCTAssertEqual(SidebarMetrics.listWidth(.infinity), 280)
    }

    func testDepartedShellCannotSettleAnInboxSplit() {
        var session = SidebarLayoutSession()
        session.begin()
        let queued = session.generation
        XCTAssertTrue(session.accepts(queued))
        session.end()
        XCTAssertFalse(session.accepts(queued))
    }

    func testReturningToHQDoesNotReviveOldDividerCallbacks() {
        var session = SidebarLayoutSession()
        session.begin()
        let queued = session.generation
        session.end()
        session.begin()
        XCTAssertFalse(session.accepts(queued))
        XCTAssertTrue(session.accepts(session.generation))
    }

    func testRapidTakeoverRoundTripsNeverReuseLayoutSession() {
        var session = SidebarLayoutSession()
        var queued: [UInt] = []
        for _ in 0..<100 {
            session.begin()
            XCTAssertFalse(queued.contains(where: session.accepts))
            queued.append(session.generation)
            session.end()
        }
        XCTAssertFalse(queued.contains(where: session.accepts))
    }

    // MARK: - The shortcut grid's height rule (12 cells in 3 columns, as at the default width)

    func testDefaultWindowCollapsesTheGrid() {
        // The default 1080x700 window: a list about 540pt tall, two pins, one live meeting.
        XCTAssertEqual(rows(540, pins: 2, meetings: 1), 0)
        XCTAssertTrue(collapsed(540, pins: 2, meetings: 1))
        // Collapsed to one row, the same list shows several conversations.
        XCTAssertGreaterThanOrEqual(
            SidebarGrid.conversationRows(listHeight: 540, cells: 12, columns: 3, pinCount: 2, meetingCards: 1,
                collapsed: true), 3)
    }

    func testCollapsedKeepsOneFullRowOfDestinations() {
        let all = Array(1...12)
        XCTAssertEqual(SidebarGrid.visibleCells(all, columns: 3, collapsed: true, selected: nil), [1, 2, 3])
        XCTAssertEqual(SidebarGrid.visibleCells(all, columns: 2, collapsed: true, selected: nil), [1, 2])
        XCTAssertEqual(SidebarGrid.visibleCells(all, columns: 1, collapsed: true, selected: nil), [1])
        XCTAssertEqual(SidebarGrid.visibleCells(all, columns: 3, collapsed: false, selected: 9), all)
    }

    func testSelectedDestinationBehindTheControlTakesTheLastVisibleSlot() {
        let all = Array(1...12)
        XCTAssertEqual(SidebarGrid.visibleCells(all, columns: 3, collapsed: true, selected: 7), [1, 2, 7])
        XCTAssertEqual(SidebarGrid.visibleCells(all, columns: 2, collapsed: true, selected: 12), [1, 12])
        XCTAssertEqual(SidebarGrid.visibleCells(all, columns: 1, collapsed: true, selected: 7), [7])
        // Already on the row, or nothing selected: the row is untouched.
        XCTAssertEqual(SidebarGrid.visibleCells(all, columns: 3, collapsed: true, selected: 2), [1, 2, 3])
        XCTAssertEqual(SidebarGrid.visibleCells(all, columns: 3, collapsed: true, selected: 99), [1, 2, 3])
    }

    func testTheControlCountsInBothHeights() {
        let control = SidebarGrid.controlHeight
        XCTAssertGreaterThan(control, 0)
        let expanded = SidebarGrid.fullGridHeight(cells: 12, columns: 3, collapsed: false)
        let oneRow = SidebarGrid.fullGridHeight(cells: 12, columns: 3, collapsed: true)
        XCTAssertEqual(expanded, 4 * SidebarGrid.rowHeight + SidebarGrid.chromeHeight + control)
        XCTAssertEqual(oneRow, SidebarGrid.rowHeight + SidebarGrid.chromeHeight + control)
        // A grid that fits on one row has nothing to hide, so no control.
        XCTAssertEqual(SidebarGrid.fullGridHeight(cells: 3, columns: 3, collapsed: false),
                       SidebarGrid.rowHeight + SidebarGrid.chromeHeight)
    }

    func testTheGridStaysWholeOnceSixRowsFitBelowIt() {
        let whole = SidebarGrid.fullGridHeight(cells: 12, columns: 3)
        let sixRows = whole + 6 * SidebarGrid.conversationRowHeight
        XCTAssertFalse(collapsed(sixRows))
        XCTAssertTrue(collapsed(sixRows - 1))
        XCTAssertEqual(rows(sixRows), 6)
        XCTAssertEqual(rows(sixRows - 1), 5)
    }

    func testPinsAndMeetingsCountAgainstTheRule() {
        let sixRows = SidebarGrid.fullGridHeight(cells: 12, columns: 3) + 6 * SidebarGrid.conversationRowHeight
        XCTAssertFalse(collapsed(sixRows))
        XCTAssertTrue(collapsed(sixRows, pins: 1))
        XCTAssertTrue(collapsed(sixRows, meetings: 1))
        // A third column's worth of pins is still one row of pins.
        XCTAssertEqual(rows(1000, pins: 3), rows(1000, pins: 1))
        XCTAssertLessThan(rows(1000, pins: 4), rows(1000, pins: 3))
    }

    func testAPersonsChoiceBeatsTheRuleBothWays() {
        XCTAssertFalse(collapsed(540, pins: 2, meetings: 1, choice: .expanded))
        XCTAssertTrue(collapsed(2000, choice: .collapsed))
    }

    func testUnmeasuredListAndOneRowGridAreNeverCollapsed() {
        XCTAssertFalse(collapsed(0))
        XCTAssertFalse(collapsed(.nan))
        XCTAssertFalse(SidebarGrid.isCollapsed(choice: .collapsed, listHeight: 540, cells: 3, columns: 3,
            pinCount: 0, meetingCards: 0))
        XCTAssertEqual(SidebarGrid.Choice(rawValue: 0), SidebarGrid.Choice.none)
    }

    private func rows(_ height: CGFloat, pins: Int = 0, meetings: Int = 0) -> Int {
        SidebarGrid.conversationRows(listHeight: height, cells: 12, columns: 3, pinCount: pins, meetingCards: meetings)
    }

    private func collapsed(
        _ height: CGFloat, pins: Int = 0, meetings: Int = 0, choice: SidebarGrid.Choice = .none
    ) -> Bool {
        SidebarGrid.isCollapsed(choice: choice, listHeight: height, cells: 12, columns: 3,
            pinCount: pins, meetingCards: meetings)
    }

    private func settle(
        _ width: CGFloat, available: CGFloat = 1080, hasDetails: Bool = false,
        isDragging: Bool = false, isMoving: Bool = false
    ) -> SidebarMetrics.Settlement {
        SidebarMetrics.settlement(width: width, availableWidth: available,
            hasDetails: hasDetails, isDragging: isDragging, isMovingDivider: isMoving)
    }
}

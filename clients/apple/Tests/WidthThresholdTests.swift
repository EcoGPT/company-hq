import XCTest

@testable import HQ

final class WidthThresholdTests: XCTestCase {
    /// A resize that crosses no threshold is not a change: the workspace
    /// does not redraw for it.
    func testProjectsWidthIsStableAcrossOrdinaryResizes() {
        XCTAssertEqual(ProjectsWidth(width: 1000), ProjectsWidth(width: 1001))
        XCTAssertEqual(ProjectsWidth(width: 900), ProjectsWidth(width: 1400))
    }

    func testProjectsThresholdsUnchanged() {
        XCTAssertFalse(ProjectsWidth(width: 719).isBeside)
        XCTAssertTrue(ProjectsWidth(width: 720).isBeside)
        XCTAssertEqual(ProjectsWidth(width: 600).panelWidth, 320)
        XCTAssertEqual(ProjectsWidth(width: 700).panelWidth, 350)
        XCTAssertEqual(ProjectsWidth(width: 880).panelWidth, 440)
        XCTAssertEqual(ProjectsWidth(width: 1400).panelWidth, 440)
    }
}

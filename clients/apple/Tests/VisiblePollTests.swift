import XCTest

@testable import HQ

final class VisiblePollTests: XCTestCase {
    private func wait(_ elapsed: Duration, _ interval: Duration = .seconds(30)) -> Duration {
        VisiblePoll<String>.remainingWait(elapsed: elapsed, interval: interval)
    }

    func testFreshLoopWaitsAWholeInterval() {
        XCTAssertEqual(wait(.zero), .seconds(30))
    }

    /// Last read at t=0, hidden at 29, back at 49: 49 s since the read, so
    /// read at once rather than sleeping another 30 s.
    func testReturnAfterAWholeIntervalReadsAtOnce() {
        XCTAssertEqual(wait(.seconds(49)), .zero)
        XCTAssertEqual(wait(.seconds(30)), .zero)
        XCTAssertEqual(wait(.seconds(600)), .zero)
    }

    /// Last read at t=0, back on screen at 20: only the remaining 10 s.
    func testReturnWithinTheIntervalSleepsOnlyTheRemainder() {
        XCTAssertEqual(wait(.seconds(20)), .seconds(10))
        XCTAssertEqual(wait(.milliseconds(29_900)), .milliseconds(100))
    }

    func testSubSecondIntervalsAreHonoured() {
        XCTAssertEqual(wait(.milliseconds(400), .milliseconds(500)), .milliseconds(100))
        XCTAssertEqual(wait(.milliseconds(600), .milliseconds(500)), .zero)
    }

    func testAClockStepBackwardsWaitsAWholeInterval() {
        XCTAssertEqual(wait(.seconds(-5)), .seconds(30))
    }
}

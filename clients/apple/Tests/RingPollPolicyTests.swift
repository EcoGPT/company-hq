import XCTest

@testable import HQ

final class RingPollPolicyTests: XCTestCase {
    func testALiveSocketInTheForegroundPollsLessOften() {
        XCTAssertEqual(RingPollPolicy.interval(isSocketLive: true, isAppActive: true), 10)
        XCTAssertEqual(RingPollPolicy.interval(isSocketLive: false, isAppActive: true), 3)
    }

    /// A phone in the background can hold a socket that died while it was
    /// suspended and still reads live; only polling ends that ring.
    func testABackgroundPhonePollsEveryThreeSecondsEvenWithALiveSocket() {
        XCTAssertEqual(RingPollPolicy.interval(isSocketLive: true, isAppActive: false), 3)
        XCTAssertEqual(RingPollPolicy.interval(isSocketLive: false, isAppActive: false), 3)
    }

    func testNeverSleepsPastTheDeadline() {
        let now = Date()
        XCTAssertEqual(
            RingPollPolicy.sleep(isSocketLive: true, isAppActive: true, until: now.addingTimeInterval(4), now: now), 4)
    }

    func testAnExpiredRingSleepsTheFloor() {
        let now = Date()
        XCTAssertEqual(
            RingPollPolicy.sleep(isSocketLive: false, isAppActive: false, until: now.addingTimeInterval(-1), now: now),
            0.1)
    }
}

import XCTest

/// When a live socket is asked to prove itself: after
/// more than ten seconds away (the phone in the background, the Mac asleep),
/// or at once when the Mac's network path changed under it. Hostless, like
/// `EventSocketReconnectTests`.
final class SocketProbePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testFiveSecondsAwayIsNotProbed() {
        XCTAssertFalse(EventSocketForegroundPolicy.shouldProbeLiveSocket(
            awaySince: now.addingTimeInterval(-5), now: now, force: false))
    }

    func testElevenSecondsAwayIsProbed() {
        XCTAssertTrue(EventSocketForegroundPolicy.shouldProbeLiveSocket(
            awaySince: now.addingTimeInterval(-11), now: now, force: false))
    }

    func testANetworkChangeProbesAtOnce() {
        XCTAssertTrue(EventSocketForegroundPolicy.shouldProbeLiveSocket(awaySince: now, now: now, force: true))
        XCTAssertTrue(EventSocketForegroundPolicy.shouldProbeLiveSocket(awaySince: nil, now: now, force: true))
    }

    func testNeverAwayAndNotForcedIsNotProbed() {
        XCTAssertFalse(EventSocketForegroundPolicy.shouldProbeLiveSocket(awaySince: nil, now: now, force: false))
    }
}

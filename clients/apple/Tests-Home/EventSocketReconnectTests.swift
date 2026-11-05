import XCTest

/// When the socket retries and when a failed attempt earns a refresh (a revoked device's 401 reaches
/// `refresh()` and signs out; REST data loads while the WebSocket cannot open). The policy file compiles
/// straight into the hostless HQHomeTests-Mac bundle, so these run without launching HQ.
final class EventSocketReconnectTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    /// One attempt that fails `seconds` after the test's start.
    private func fail(
        _ policy: inout EventSocketReconnectPolicy, at seconds: TimeInterval = 0, jitter: Double = 1,
        reachedServer: Bool = true
    ) -> (delay: TimeInterval, refresh: Bool) {
        policy.attemptStarted()
        return policy.dropped(at: t0.addingTimeInterval(seconds), jitter: jitter, reachedServer: reachedServer)
    }

    func testTheFirstFailureAfterLaunchRefreshesAndLaterRetriesDoNot() {
        var policy = EventSocketReconnectPolicy()
        XCTAssertTrue(fail(&policy).refresh, "a revoked device's 401 reaches refresh once")
        for n in 1...6 {
            XCTAssertFalse(fail(&policy, at: Double(n) * 30).refresh, "retry \(n) is quiet")
        }
    }

    func testAFrameEndsTheStreakAndTheNextOutageRefreshesOnceAgain() {
        var policy = EventSocketReconnectPolicy()
        XCTAssertTrue(fail(&policy).refresh)
        policy.attemptStarted()
        policy.wentLive(at: t0.addingTimeInterval(5))
        // The live socket's own drop is not a failed attempt: its reconnect's first frame refreshes.
        XCTAssertFalse(policy.dropped(at: t0.addingTimeInterval(100), jitter: 1, reachedServer: true).refresh)
        XCTAssertTrue(fail(&policy, at: 101).refresh, "first failed attempt after a live period")
        XCTAssertFalse(fail(&policy, at: 110).refresh)
    }

    func testBackoffClimbsWithoutAFrameAndCapsAtTwentySecondsBeforeJitter() {
        var policy = EventSocketReconnectPolicy()
        let delays = (0..<8).map { _ in fail(&policy).delay }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 20, 20, 20])
        XCTAssertEqual(fail(&policy, jitter: 1.5).delay, 30, "the longest wait stays the old 30 s")
    }

    func testAStableSocketStartsTheBackoffOver() {
        var policy = EventSocketReconnectPolicy()
        for _ in 0..<5 { _ = fail(&policy) }
        policy.attemptStarted()
        policy.wentLive(at: t0)
        XCTAssertEqual(policy.dropped(at: t0.addingTimeInterval(30), jitter: 1, reachedServer: true).delay, 1)
    }

    func testAShortLivedSocketKeepsAtMostOneStepSoAFlakyConnectionNeverClimbs() {
        var policy = EventSocketReconnectPolicy()
        for _ in 0..<5 { _ = fail(&policy) }
        // Five failures: the next base would be 32, capped to 20. A socket that was live 5 s keeps one step.
        policy.attemptStarted()
        policy.wentLive(at: t0)
        XCTAssertEqual(policy.dropped(at: t0.addingTimeInterval(5), jitter: 1, reachedServer: true).delay, 2)

        // Many short-lived sockets in a row (a flaky call-time connection) stay at 2 s.
        for n in 0..<10 {
            policy.attemptStarted()
            policy.wentLive(at: t0)
            let drop = policy.dropped(at: t0.addingTimeInterval(Double(n % 29) + 1), jitter: 1, reachedServer: true)
            XCTAssertEqual(drop.delay, 2)
        }
    }

    func testAShortLivedSocketAfterAFreshStartDoesNotJumpAhead() {
        var policy = EventSocketReconnectPolicy()
        policy.attemptStarted()
        policy.wentLive(at: t0)
        let drop = policy.dropped(at: t0.addingTimeInterval(1), jitter: 1, reachedServer: true)
        XCTAssertEqual(drop.delay, 1, "attempts were 0: still the first step")
    }

    func testJitterScalesTheDelay() {
        var policy = EventSocketReconnectPolicy()
        XCTAssertEqual(fail(&policy, jitter: 0.5).delay, 0.5)
    }

    // MARK: - A refresh is spent only on a failure that reached the server

    func testAFailureThatNeverReachedTheServerDoesNotSpendTheStreaksRefresh() {
        var policy = EventSocketReconnectPolicy()
        // Wi-Fi has not associated yet after a wake: "not connected", no HTTP response at all.
        for n in 0..<3 {
            XCTAssertFalse(fail(&policy, at: Double(n), reachedServer: false).refresh, "attempt \(n) was offline")
        }
        // The network is back and the hub answers the upgrade with its 401: that failure refreshes, once.
        XCTAssertTrue(fail(&policy, at: 10).refresh)
        XCTAssertFalse(fail(&policy, at: 40).refresh)
    }

    func testUpgradesThatOnlyTimeOutStillRefreshOnceAfterThirtySeconds() {
        var policy = EventSocketReconnectPolicy()
        let t0 = Date(timeIntervalSince1970: 1_000)
        // A middlebox swallows the upgrade: every attempt times out with no HTTP answer. REST may still work,
        // so after 30 s of that the streak spends its one refresh; before it, nothing.
        XCTAssertFalse(policy.dropped(at: t0, jitter: 1, reachedServer: false, timedOut: true).refresh)
        XCTAssertFalse(policy.dropped(at: t0.addingTimeInterval(29), jitter: 1, reachedServer: false, timedOut: true).refresh)
        XCTAssertTrue(policy.dropped(at: t0.addingTimeInterval(31), jitter: 1, reachedServer: false, timedOut: true).refresh)
        XCTAssertFalse(policy.dropped(at: t0.addingTimeInterval(90), jitter: 1, reachedServer: true).refresh)
    }

    func testPlainOfflineFailuresNeverSpendTheRefreshHoweverLongTheyLast() {
        var policy = EventSocketReconnectPolicy()
        let t0 = Date(timeIntervalSince1970: 1_000)
        for seconds in [0.0, 40, 120] {
            XCTAssertFalse(policy.dropped(at: t0.addingTimeInterval(seconds), jitter: 1, reachedServer: false).refresh)
        }
        // The revoked bearer's 401 still gets the streak's refresh once the network is back.
        XCTAssertTrue(policy.dropped(at: t0.addingTimeInterval(130), jitter: 1, reachedServer: true).refresh)
    }

    func testAnOfflineFailureStillClimbsTheBackoff() {
        var policy = EventSocketReconnectPolicy()
        let delays = (0..<4).map { _ in fail(&policy, reachedServer: false).delay }
        XCTAssertEqual(delays, [1, 2, 4, 8])
    }

    func testALiveSocketsDropNeverRefreshesWhetherOrNotTheServerAnswered() {
        var policy = EventSocketReconnectPolicy()
        policy.attemptStarted()
        policy.wentLive(at: t0)
        XCTAssertFalse(policy.dropped(at: t0.addingTimeInterval(100), jitter: 1, reachedServer: true).refresh)
        policy.attemptStarted()
        policy.wentLive(at: t0.addingTimeInterval(110))
        XCTAssertFalse(policy.dropped(at: t0.addingTimeInterval(200), jitter: 1, reachedServer: false).refresh)
    }

    // MARK: - Foreground check on the phone

    func testASocketInItsOwnRetryWaitIsNeverReplaced() {
        XCTAssertFalse(EventSocketForegroundPolicy.shouldReplaceSocketThatIsNotLive(
            attemptStartedAt: t0.addingTimeInterval(-300), isWaitingToRetry: true, now: t0
        ), "replacing it would reset its backoff to attempt 0")
    }

    func testASocketMidHandshakeIsLeftToFinish() {
        XCTAssertFalse(EventSocketForegroundPolicy.shouldReplaceSocketThatIsNotLive(
            attemptStartedAt: t0.addingTimeInterval(-2), isWaitingToRetry: false, now: t0
        ))
        XCTAssertFalse(EventSocketForegroundPolicy.shouldReplaceSocketThatIsNotLive(
            attemptStartedAt: t0.addingTimeInterval(-14), isWaitingToRetry: false, now: t0
        ))
    }

    func testAHandshakeThatHasHungForLongIsReplaced() {
        XCTAssertTrue(EventSocketForegroundPolicy.shouldReplaceSocketThatIsNotLive(
            attemptStartedAt: t0.addingTimeInterval(-16), isWaitingToRetry: false, now: t0
        ))
    }

    func testASocketThatNeverStartedAnAttemptIsReplaced() {
        XCTAssertTrue(EventSocketForegroundPolicy.shouldReplaceSocketThatIsNotLive(
            attemptStartedAt: nil, isWaitingToRetry: false, now: t0
        ))
    }

    func testTheProbeWindowIsTenSeconds() {
        XCTAssertEqual(EventSocketForegroundPolicy.probeWindow, 10)
    }
}

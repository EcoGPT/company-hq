import Foundation

/// When to reconnect and when a failed attempt is worth a refresh. Pure, so the streak and backoff rules
/// are tested without a socket.
struct EventSocketReconnectPolicy {
    /// How long a socket must have been live before a drop starts the backoff over instead of continuing it.
    static let stableAfter: TimeInterval = 30
    /// The base of the backoff tops out here; with 1.5x jitter the longest wait is the old 30 s.
    static let baseCap: TimeInterval = 20
    /// A streak whose upgrades only ever time out still spends its refresh after this long: a middlebox
    /// that swallows the upgrade, or a hub that hangs it, can leave REST answering, and the app should
    /// load. Plain offline failures (no route, no DNS) never count — spent offline, the refresh fails.
    static let timedOutRefreshAfter: TimeInterval = 30

    private(set) var attempts = 0
    private var liveSince: Date?
    /// A failure streak is the run of attempts that never delivered a frame, from launch or from a live
    /// socket's drop. It gets one refresh: that is how a revoked bearer's 401 reaches `refresh()` and
    /// signs the device out, and how REST-only data loads when the WebSocket cannot open. Later retries
    /// in the streak stay quiet. A frame ends the streak.
    private var hasRefreshedThisStreak = false
    private var streakStartedAt: Date?

    /// A new task is about to open.
    mutating func attemptStarted() { liveSince = nil }

    /// The first frame of the task arrived.
    mutating func wentLive(at now: Date) {
        liveSince = now
        hasRefreshedThisStreak = false
        streakStartedAt = nil
    }

    /// The task failed or dropped. `refresh` is true once per failure streak, on its first never-live failure
    /// that `reachedServer` (the upgrade got an HTTP answer, a 401 included). A failure with no answer at all
    /// (no network yet after a wake) leaves the streak's refresh for the first attempt that does reach the hub:
    /// spent offline, it would fail with a transient error that signs nobody out, and a revoked device would
    /// retry for good.
    /// `timedOut` (the upgrade got no answer within the request timeout) spends it too once the streak
    /// has lasted `timedOutRefreshAfter`.
    mutating func dropped(
        at now: Date, jitter: Double, reachedServer: Bool, timedOut: Bool = false
    ) -> (delay: TimeInterval, refresh: Bool) {
        let wasLive = liveSince != nil
        if wasLive || streakStartedAt == nil { streakStartedAt = now }
        let waitedOut = timedOut
            && now.timeIntervalSince(streakStartedAt ?? now) >= Self.timedOutRefreshAfter
        if let liveSince {
            // A socket that was live is not a failure: reset the climb so a flaky call-time connection
            // never reaches the long waits (the hub drops a call seat after 45 s away). One that held
            // 30 s starts over; one that dropped sooner keeps at most one step.
            attempts = now.timeIntervalSince(liveSince) >= Self.stableAfter ? 0 : min(attempts, 1)
        }
        liveSince = nil
        let refresh = !wasLive && !hasRefreshedThisStreak && (reachedServer || waitedOut)
        if refresh { hasRefreshedThisStreak = true }
        let delay = min(pow(2, Double(attempts)), Self.baseCap) * jitter
        attempts += 1
        return (delay, refresh)
    }
}

/// What the phone's foreground check (and the Mac's wake and network checks) do with the socket they find.
/// Pure, like the policy above.
enum EventSocketForegroundPolicy {
    /// After a long background the live socket is asked to sync; this long without anything arriving
    /// (a frame or a pong) and it is replaced. Generous on purpose: the first frame of a large replay
    /// over slow cellular can take several seconds, and tearing the socket down mid-replay runs it again.
    static let probeWindow: TimeInterval = 10
    /// A handshake younger than this is left to finish; older, it is half-dead.
    static let handshakeGrace: TimeInterval = 15

    /// Whether a socket that is not live should be replaced now. Not while it waits out its own backoff
    /// (replacing it starts the climb over at attempt 0 and undoes the jitter, so every app switch during
    /// an outage would hit the hub), and not while its handshake is still young.
    static func shouldReplaceSocketThatIsNotLive(
        attemptStartedAt: Date?, isWaitingToRetry: Bool, now: Date
    ) -> Bool {
        if isWaitingToRetry { return false }
        guard let attemptStartedAt else { return true }
        return now.timeIntervalSince(attemptStartedAt) > handshakeGrace
    }

    /// Away (the phone in the background, the Mac asleep) longer than this and a live socket is probed.
    static let probeAfterAway: TimeInterval = 10

    /// Whether a socket that reads as live should be asked to sync, and replaced if nothing comes back within
    /// `probeWindow`: after more than `probeAfterAway` away, or at once when `force` (the Mac's network path
    /// changed under it, which a half-open socket never notices).
    static func shouldProbeLiveSocket(awaySince: Date?, now: Date, force: Bool) -> Bool {
        if force { return true }
        guard let awaySince else { return false }
        return now.timeIntervalSince(awaySince) > probeAfterAway
    }
}

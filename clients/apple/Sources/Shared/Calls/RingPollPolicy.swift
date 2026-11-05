import Foundation

/// How often a ringing phone asks the hub whether the ring is over. With a live socket the
/// `call_ring_ended` frame does that job and the poll is only a backstop for a half-open socket.
/// Only a foreground app counts: a phone back from suspension can hold a socket
/// that died while suspended yet still reads live, so it keeps the 3 s poll.
enum RingPollPolicy {
    static func interval(isSocketLive: Bool, isAppActive: Bool) -> TimeInterval {
        isSocketLive && isAppActive ? 10 : 3
    }
    /// Never sleep past the ring's deadline: the deadline ends the ring on time.
    static func sleep(
        isSocketLive: Bool, isAppActive: Bool, until expiresAt: Date, now: Date = Date()
    ) -> TimeInterval {
        max(0.1, min(interval(isSocketLive: isSocketLive, isAppActive: isAppActive), expiresAt.timeIntervalSince(now)))
    }
}

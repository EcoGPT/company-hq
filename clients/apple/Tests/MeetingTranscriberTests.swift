import XCTest

@testable import HQ

// Never call start(callId:bearer:) here: it opens a real socket to the hub
// and starts the microphone.
@MainActor
final class MeetingTranscriberTests: XCTestCase {
    func testStopKeepsTheMuteSoAMutedJoinStaysMuted() {
        let transcriber = MeetingTranscriber()
        transcriber.setMuted(true)
        transcriber.stop()          // start(callId:bearer:) runs exactly this first
        XCTAssertTrue(transcriber.isMuted)
        transcriber.setMuted(false)
        transcriber.stop()
        XCTAssertFalse(transcriber.isMuted)
    }

    func testFeedSilenceLimitMatchesTheWatchdog() {
        let now = Date()
        XCTAssertFalse(MeetingTranscriber.isFeedSilent(lastReceivedAt: now.addingTimeInterval(-30), now: now))
        XCTAssertTrue(MeetingTranscriber.isFeedSilent(lastReceivedAt: now.addingTimeInterval(-41), now: now))
        XCTAssertLessThan(MeetingTranscriber.keepaliveInterval, .seconds(MeetingTranscriber.silenceLimit / 2))
    }
}

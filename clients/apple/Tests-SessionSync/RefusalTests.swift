import Foundation
import XCTest

/// A conversation the server refuses is not sent again every 15 seconds.
final class RefusalTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testOnlyTheServersNoToTheContentIsARefusal() {
    for status in [400, 413] {
      XCTAssertTrue(RefusalMemo.isRefusal(SyncTransportError.http(status)), "HTTP \(status)")
    }
    for status in [401, 403, 404, 409, 429, 500, 503] {
      XCTAssertFalse(RefusalMemo.isRefusal(SyncTransportError.http(status)), "HTTP \(status)")
    }
    XCTAssertFalse(RefusalMemo.isRefusal(SyncTransportError.network(.timedOut)))
    XCTAssertFalse(RefusalMemo.isRefusal(SyncFailure.scope))
    XCTAssertFalse(RefusalMemo.isRefusal(URLError(.cancelled)))
  }

  func testARefusedConversationIsHeldWhileItsContentIsTheSame() {
    var memo = RefusalMemo()
    XCTAssertFalse(memo.isHeld("claude/a", now: now) { "x" }, "nothing refused yet")
    memo.refuse("claude/a", fingerprint: "v1", reason: "over the limit", now: now)
    XCTAssertTrue(memo.isHeld("claude/a", now: now.addingTimeInterval(15)) { "v1" })
    XCTAssertTrue(memo.isHeld("claude/a", now: now.addingTimeInterval(3599)) { "v1" })
    XCTAssertEqual(memo.reason("claude/a"), "over the limit")
    XCTAssertFalse(memo.isHeld("claude/a", now: now.addingTimeInterval(15)) { "v2" }, "new content is tried at once")
    XCTAssertFalse(memo.isHeld("claude/b", now: now) { "v1" }, "another conversation is not held")
  }

  func testAHeldConversationIsTriedAgainAfterAnHour() {
    var memo = RefusalMemo()
    memo.refuse("claude/a", fingerprint: "v1", reason: "r", now: now)
    XCTAssertFalse(memo.isHeld("claude/a", now: now.addingTimeInterval(RefusalMemo.backoff)) { "v1" })
    memo.refuse("claude/a", fingerprint: "v1", reason: "r", now: now.addingTimeInterval(RefusalMemo.backoff))
    XCTAssertTrue(
      memo.isHeld("claude/a", now: now.addingTimeInterval(RefusalMemo.backoff + 60)) { "v1" }, "refused again, held another hour")
  }

  func testNothingIsComparedWhenNothingIsHeldAndASuccessReleases() {
    var memo = RefusalMemo()
    var asked = 0
    XCTAssertFalse(memo.isHeld("claude/a", now: now) { asked += 1; return "v1" })
    XCTAssertEqual(asked, 0, "an unheld conversation costs no fold")
    memo.refuse("claude/a", fingerprint: nil, reason: "r", now: now)
    XCTAssertTrue(memo.entries.isEmpty, "without a fingerprint there is nothing to compare, so nothing is held")
    memo.refuse("claude/a", fingerprint: "v1", reason: "r", now: now)
    memo.clear("claude/a")
    XCTAssertFalse(memo.isHeld("claude/a", now: now) { "v1" })
  }

  func testConversationsThatLeaveTheWindowAreForgotten() {
    var memo = RefusalMemo()
    memo.refuse("claude/a", fingerprint: "v1", reason: "r", now: now)
    memo.refuse("claude/b", fingerprint: "v1", reason: "r", now: now)
    memo.keep(["claude/b"])
    XCTAssertEqual(Set(memo.entries.keys), ["claude/b"])
  }
}

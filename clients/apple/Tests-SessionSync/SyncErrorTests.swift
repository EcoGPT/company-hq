import Foundation
import XCTest

/// What a failed sync says went wrong: the words a person reads in Settings.
final class SyncErrorTests: XCTestCase {
  func testStatusToReason() {
    let reasons: [(Int, String)] = [
      (401, "Sign-in expired or was revoked; open the app to sign in again"),
      (403, "The server refused this Mac's sign-in"),
      (400, "The server rejected this conversation's data"),
      (404, "The server does not support session sync"),
      (409, "Conversation changed on the server; will retry"),
      (413, "The server will not take this conversation (over its size, storage or conversation-count limit)"),
      (500, "The server is having trouble (HTTP 500); will retry"),
      (503, "The server is having trouble (HTTP 503); will retry"),
      (418, "The server answered with an unexpected status (HTTP 418); will retry"),
    ]
    for (status, reason) in reasons {
      XCTAssertEqual(SyncReason.of(SyncTransportError.http(status)), reason, "HTTP \(status)")
    }
    for code in [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost, .secureConnectionFailed] {
      XCTAssertEqual(SyncReason.of(SyncTransportError.network(code)), "Can't reach the server; will retry")
      XCTAssertEqual(SyncReason.of(URLError(code)), "Can't reach the server; will retry")
    }
  }

  func testACancelledRequestIsAPauseNotAFault() {
    XCTAssertEqual(SyncReason.of(URLError(.cancelled)), "Server unavailable; will retry")
    XCTAssertEqual(SyncReason.of(SyncTransportError.network(.cancelled)), "Server unavailable; will retry")
    XCTAssertEqual(SyncReason.of(URLError(.cancelled), fallback: "will retry"), "will retry")
    XCTAssertEqual(SyncReason.of(SyncFailure.receipt), SyncFailure.receipt.rawValue)
    XCTAssertEqual(SyncReason.of(CocoaError(.fileReadUnknown)), "Server unavailable; will retry")
  }
}

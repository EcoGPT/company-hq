import Foundation
import XCTest

/// The assertion the ported suites share.
func check(_ ok: Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
  if !ok { XCTFail(message(), file: file, line: line) }
}

/// The suites ported from a command-line harness, each run as one test.
final class PortedSuites: XCTestCase {
  func testIncrementalFold() throws { try IncrementalJSONLTests.run() }
  func testTitles() throws { try SyncTitleTests.run() }
  func testAcknowledgementMemo() throws { try AcknowledgementMemoTests.run() }
  @MainActor func testKeeper() async throws { try await SessionSyncKeeperTests.run() }
}

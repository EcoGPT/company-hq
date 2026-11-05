import XCTest

@testable import HQ

final class CommentReloadTests: XCTestCase {
    func testFirstOpenLoads() {
        XCTAssertTrue(CommentThread.needsLoad(isLoaded: false, held: 0, hubCount: 3))
    }

    /// The badge says 5 and the open card holds 4: someone else commented.
    func testANewCommentOnTheHubReloads() {
        XCTAssertTrue(CommentThread.needsLoad(isLoaded: true, held: 4, hubCount: 5))
    }

    /// Your own post was already re-read; the frame that follows it is not a
    /// second read.
    func testInStepDoesNotReload() {
        XCTAssertFalse(CommentThread.needsLoad(isLoaded: true, held: 5, hubCount: 5))
    }

    /// An older hub's board carries no count.
    func testUnknownCountDoesNotReload() {
        XCTAssertFalse(CommentThread.needsLoad(isLoaded: true, held: 5, hubCount: nil))
    }
}

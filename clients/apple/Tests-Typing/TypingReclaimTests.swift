import AppKit
import XCTest

#if !TYPING_RULE_STANDALONE
@testable import HQ
#endif

// Runs in `HQTests` and hostless in `HQTypingTests-Mac`, against real AppKit
// objects: which focused thing keeps a typed key on a page with no composer.
@MainActor
final class TypingReclaimTests: XCTestCase {
    func testFocusedTextKeepsEveryKey() {
        XCTAssertFalse(TypingReclaim.isFree(NSTextView(), characters: "a"))
        XCTAssertFalse(TypingReclaim.isFree(NSTextView(), characters: " "))
    }

    func testNothingFocusedGoesToTheComposer() {
        XCTAssertTrue(TypingReclaim.isFree(nil, characters: "a"))
        XCTAssertTrue(TypingReclaim.isFree(NSWindow(), characters: "a"))
        XCTAssertTrue(TypingReclaim.isFree(NSView(), characters: "a"))
        XCTAssertTrue(TypingReclaim.isFree(NSView(), characters: " "))
    }

    func testAControlKeepsOnlySpace() {
        for control in [NSSegmentedControl(), NSSwitch()] as [NSControl] {
            XCTAssertFalse(TypingReclaim.isFree(control, characters: " "), "\(type(of: control)) Space")
            XCTAssertTrue(TypingReclaim.isFree(control, characters: "a"), "\(type(of: control)) letter")
        }
    }

    func testAListGivesUpLettersAndSpace() {
        XCTAssertTrue(TypingReclaim.isFree(NSOutlineView(), characters: "a"))
        XCTAssertTrue(TypingReclaim.isFree(NSOutlineView(), characters: " "))
        XCTAssertTrue(TypingReclaim.isFree(NSTableView(), characters: " "))
    }
}

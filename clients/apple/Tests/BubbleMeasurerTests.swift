import AppKit
import XCTest

@testable import HQ

// The transcript asks every bubble for its size on every animation frame, at
// MORE than one width per pass (the zero-width probe from #79 before the real
// one). The measurer's memo has to hold across that alternation — a
// single-slot (text, width) memo misses on every call and re-runs the
// Markdown render plus a TextKit layout per bubble per frame, which is the
// core-burning regression the cache fixed.
final class BubbleMeasurerTests: XCTestCase {
    private func attributed(_ text: String, counting builds: inout Int) -> NSAttributedString {
        builds += 1
        return NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 15)]
        )
    }

    @MainActor
    func testAlternatingWidthProbesHitTheMemo() {
        let measurer = SelectableBubbleText.Measurer()
        var builds = 0
        let text = "hello world, a bubble of ordinary length"

        let zeroProbe = measurer.size(of: text, fitting: 0) {
            self.attributed(text, counting: &builds)
        }
        let real = measurer.size(of: text, fitting: 420) {
            self.attributed(text, counting: &builds)
        }
        // The next frame proposes the same pair again — every call must hit.
        for _ in 0..<3 {
            XCTAssertEqual(
                measurer.size(of: text, fitting: 0) {
                    self.attributed(text, counting: &builds)
                }, zeroProbe)
            XCTAssertEqual(
                measurer.size(of: text, fitting: 420) {
                    self.attributed(text, counting: &builds)
                }, real)
        }

        // One attributed build for the whole run: the string depends on the
        // text alone, so the second width reuses the first build too.
        XCTAssertEqual(builds, 1)
    }

    // The bubble measures the very string it draws, so the code face is
    // counted: monospaced "i"s are wider than proportional ones, and a fenced
    // block adds a line per line of code.
    @MainActor
    func testCodeFaceAndBlockLinesAreMeasured() {
        let measurer = SelectableBubbleText.Measurer()
        func size(_ text: String) -> CGSize {
            measurer.size(of: text, fitting: 420) {
                SelectableBubbleText.attributedString(for: text, isOwn: false, names: [])
            }
        }

        let plain = size("iiiiiiiiii")
        let inline = size("`iiiiiiiiii`")
        XCTAssertGreaterThan(inline.width, plain.width)

        let oneLine = size("```\none\n```")
        let threeLines = size("```\none\ntwo\nthree\n```")
        XCTAssertGreaterThan(threeLines.height, oneLine.height * 2)
    }

    // A block is set in by its padding on both sides, but TextKit's used rect
    // only counts the head indent: a block narrower than the bubble cap would
    // lose its right padding to the clamp that keeps the wash inside the view.
    @MainActor
    func testANarrowBlockKeepsItsRightPadding() {
        let measurer = SelectableBubbleText.Measurer()
        func size(_ text: String, fitting width: CGFloat = 420) -> CGSize {
            measurer.size(of: text, fitting: width) {
                SelectableBubbleText.attributedString(for: text, isOwn: false, names: [])
            }
        }

        let text = size("`ls -la`")
        let block = size("```\nls -la\n```")
        XCTAssertEqual(
            block.width, text.width + 2 * ChatMarkdown.CodeStyle.blockPadding, accuracy: 1.5
        )

        // Never past the width it was offered.
        XCTAssertLessThanOrEqual(size("```\n" + String(repeating: "x", count: 200) + "\n```").width, 420)
        XCTAssertLessThanOrEqual(size("```\nls -la\n```", fitting: 30).width, 30)
    }

    @MainActor
    func testCodeFontAndWashAreOnTheDrawnString() {
        let string = SelectableBubbleText.attributedString(
            for: "run `ci` ~~now~~", isOwn: false, names: []
        )
        let code = (string.string as NSString).range(of: "ci")
        let font = string.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.isFixedPitch, true)
        XCTAssertNotNil(string.attribute(.hqCodeFill, at: code.location, effectiveRange: nil))
        XCTAssertNil(string.attribute(.hqCodeBlock, at: code.location, effectiveRange: nil))

        let struck = (string.string as NSString).range(of: "now")
        XCTAssertNotNil(
            string.attribute(.strikethroughStyle, at: struck.location, effectiveRange: nil)
        )
        XCTAssertNil(string.attribute(.hqCodeFill, at: 0, effectiveRange: nil))
    }

    @MainActor
    func testTextChangeInvalidatesAndRemeasures() {
        let measurer = SelectableBubbleText.Measurer()
        var builds = 0

        let short = measurer.size(of: "hi", fitting: 420) {
            self.attributed("hi", counting: &builds)
        }
        let longer = measurer.size(of: "hi there, considerably more words", fitting: 420) {
            self.attributed("hi there, considerably more words", counting: &builds)
        }

        XCTAssertEqual(builds, 2)
        XCTAssertGreaterThan(longer.width, short.width)
    }
}

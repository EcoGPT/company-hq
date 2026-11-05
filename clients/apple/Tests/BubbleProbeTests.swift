import AppKit
import XCTest

@testable import HQ

// SwiftUI asks every Mac bubble for its size at 394, 0 and nil in each pass.
// The zero probe used to run a TextKit layout one glyph per line, and nil a
// second layout at 420 that no bubble can draw inside its padding: on a cold
// open those two were most of the measure time. All three now share the one
// layout the real proposal needs.
@MainActor
final class BubbleProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SelectableBubbleText.Memory.reset()
    }

    override func tearDown() {
        SelectableBubbleText.Memory.reset()
        super.tearDown()
    }

    private func prose(_ length: Int) -> String {
        var text = ""
        while text.utf16.count < length {
            text += "The conversion for this cohort was flat while paywall impressions went up, "
                + "so the test needs a longer window. "
        }
        return String(text.prefix(length))
    }

    private func measure(
        _ text: String, _ width: CGFloat?, with measurer: SelectableBubbleText.Measurer
    ) -> CGSize {
        SelectableBubbleText.measure(
            text: text, names: [], proposedWidth: width, measurer: measurer
        ) {
            SelectableBubbleText.attributedString(for: text, isOwn: false, names: [])
        }
    }

    func testOneLayoutServesAllThreeProbes() {
        let measurer = SelectableBubbleText.Measurer()
        let text = prose(400)
        _ = measure(text, 394, with: measurer)
        _ = measure(text, 0, with: measurer)
        _ = measure(text, nil, with: measurer)
        XCTAssertEqual(SelectableBubbleText.Memory.sizes.count, 1)
    }

    func testZeroProbeIsNarrowAndKeepsTheRealHeight() {
        let measurer = SelectableBubbleText.Measurer()
        let text = prose(400)
        let real = measure(text, 394, with: measurer)
        let zero = measure(text, 0, with: measurer)
        XCTAssertLessThanOrEqual(zero.width, 14)
        XCTAssertEqual(zero.height, real.height)
    }

    func testNilProbeEqualsTheCapAnswer() {
        let measurer = SelectableBubbleText.Measurer()
        let text = prose(400)
        let real = measure(text, 394, with: measurer)
        XCTAssertEqual(measure(text, nil, with: measurer), real)
        XCTAssertEqual(measure(text, .infinity, with: measurer), real)
    }

    func testNarrowRealProposalIsUnchanged() {
        let text = prose(400)
        let answered = measure(text, 300, with: SelectableBubbleText.Measurer())
        let direct = SelectableBubbleText.Measurer().size(of: text, fitting: 300) {
            SelectableBubbleText.attributedString(for: text, isOwn: false, names: [])
        }
        XCTAssertEqual(answered, direct)
    }

    // The measured check: a cold open of an 80-message mix, each bubble with
    // its own coordinator, probed in the order SwiftUI uses. Printed, not
    // asserted; the numbers go in the PR.
    func testColdOpenMeasureTime() {
        let lengths = Array(repeating: 40, count: 40) + Array(repeating: 100, count: 20)
            + Array(repeating: 300, count: 12) + Array(repeating: 800, count: 6)
            + Array(repeating: 2_000, count: 2)
        let texts = lengths.enumerated().map { "\($0.offset) " + prose($0.element) }
        let probes: [CGFloat?] = [394, 394, 0, 0, 394, 394, nil, nil]
        let start = CFAbsoluteTimeGetCurrent()
        for text in texts {
            let measurer = SelectableBubbleText.Measurer()
            for width in probes { _ = measure(text, width, with: measurer) }
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000
        print("BubbleProbeTests cold open, 80 messages: \(String(format: "%.1f", elapsed)) ms")
    }
}

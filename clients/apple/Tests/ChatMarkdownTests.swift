import Foundation
import XCTest
@testable import HQ

final class ChatMarkdownTests: XCTestCase {
    private var previousServer: String?

    override func setUp() {
        previousServer = HQConfig.savedServer
        HQConfig.savedServer = "https://hq.example.com"
    }

    override func tearDown() {
        HQConfig.savedServer = previousServer
    }

    func testLocalizesOnlyParsedLinksAndPreservesCodeAndStyledLinkBoundaries() {
        let url = "https://hq.example.com/admin#timestamp=1788669000&style=date-time"
        let source = "`[literal](\(url))` [**styled** label](\(url)) **after**"
        let rendered = ChatMarkdown.render(source, timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(rendered.text, "[literal](\(url)) Sep 6, 12:30 AM EDT after")
        XCTAssertTrue(rendered.spans.contains {
            $0.isBold && $0.range == (rendered.text as NSString).range(of: "after")
        })
    }

    func testRendersBulletsWithoutRawMarkdownMarkers() {
        let rendered = ChatMarkdown.render("- first\n- **second**")

        XCTAssertEqual(rendered.text, "• first\n• second")
    }

    func testMarksBoldText() {
        let rendered = ChatMarkdown.render("hello **bold**")

        XCTAssertEqual(rendered.text, "hello bold")
        XCTAssertTrue(
            rendered.spans.contains {
                $0.range == NSRange(location: 6, length: 4) && $0.isBold
            }
        )
    }

    func testPreservesOrdinaryLineBreaks() {
        let rendered = ChatMarkdown.render("first line\nsecond line\n\nlast paragraph")

        XCTAssertEqual(rendered.text, "first line\nsecond line\n\nlast paragraph")
    }

    func testRejectsUnsafeMarkdownLinksAndKeepsHTTPSLinks() {
        let rendered = ChatMarkdown.render(
            "[unsafe](javascript:alert(1)) [safe](https://example.com)"
        )

        XCTAssertNil(rendered.spans.first { $0.range.location == 0 }?.link)
        XCTAssertEqual(rendered.spans.compactMap(\.link), [URL(string: "https://example.com")!])
    }

    func testFormatsRichTimestampLinksInViewerTimeZone() {
        let source = "[server label](https://hq.example.com/admin#timestamp=1788669000&style=date-time) **after**"
        guard let newYork = TimeZone(identifier: "America/New_York"),
              let losAngeles = TimeZone(identifier: "America/Los_Angeles")
        else {
            return XCTFail("Test time zones must exist")
        }

        let newYorkRendered = ChatMarkdown.render(source, timeZone: newYork)
        let losAngelesRendered = ChatMarkdown.render(source, timeZone: losAngeles)

        XCTAssertEqual(newYorkRendered.text, "Sep 6, 12:30 AM EDT after")
        XCTAssertEqual(losAngelesRendered.text, "Sep 5, 9:30 PM PDT after")
        XCTAssertTrue(
            newYorkRendered.spans.contains {
                $0.isBold && $0.range == (newYorkRendered.text as NSString).range(of: "after")
            }
        )
        XCTAssertTrue(newYorkRendered.spans.allSatisfy { $0.link == nil })
        XCTAssertTrue(losAngelesRendered.spans.allSatisfy { $0.link == nil })
    }

    func testFormatsTimeOnlyAndTimeZoneTimestampLinks() {
        let source = [
            "[time](https://hq.example.com/admin#timestamp=1788669000&style=time)",
            "[zone](https://hq.example.com/admin#timestamp=1788669000&style=time-zone)",
        ].joined(separator: " ")
        guard let newYork = TimeZone(identifier: "America/New_York") else {
            return XCTFail("Test time zone must exist")
        }
        let rendered = ChatMarkdown.render(source, timeZone: newYork)

        XCTAssertEqual(rendered.text, "12:30 AM 12:30 AM EDT")
        XCTAssertTrue(rendered.spans.allSatisfy { $0.link == nil })
    }

    func testFormatsAtomicRichTimestampRangeInViewerTimeZone() {
        let source = "[server range](https://hq.example.com/admin#timestamp=1788700740&end=1788701340&style=range)"
        guard let newYork = TimeZone(identifier: "America/New_York"),
              let losAngeles = TimeZone(identifier: "America/Los_Angeles")
        else {
            return XCTFail("Test time zones must exist")
        }

        XCTAssertEqual(
            ChatMarkdown.render(source, timeZone: newYork).text,
            "9:19-9:29am EDT"
        )
        XCTAssertEqual(
            ChatMarkdown.render(source, timeZone: losAngeles).text,
            "6:19-6:29am PDT"
        )
        XCTAssertTrue(ChatMarkdown.render(source, timeZone: newYork).spans.allSatisfy { $0.link == nil })
    }

    func testFormatsRichTimestampRangesAcrossNoonMidnightAndDST() {
        guard let newYork = TimeZone(identifier: "America/New_York") else {
            return XCTFail("Test time zone must exist")
        }

        let noon = ChatMarkdown.render(
            rangeLink(start: 1788708600, end: 1788712200), timeZone: newYork
        )
        let midnight = ChatMarkdown.render(
            rangeLink(start: 1788665400, end: 1788669000), timeZone: newYork
        )
        let daylightSaving = ChatMarkdown.render(
            rangeLink(start: 1772951400, end: 1772955000), timeZone: newYork
        )

        XCTAssertEqual(noon.text, "11:30am-12:30pm EDT")
        XCTAssertEqual(midnight.text, "Sep 5, 11:30pm-Sep 6, 12:30am EDT")
        XCTAssertEqual(daylightSaving.text, "1:30am EST-3:30am EDT")
        XCTAssertTrue(noon.spans.allSatisfy { $0.link == nil })
        XCTAssertTrue(midnight.spans.allSatisfy { $0.link == nil })
        XCTAssertTrue(daylightSaving.spans.allSatisfy { $0.link == nil })
    }

    func testRejectsMalformedRichTimestampRanges() {
        let source = [
            "[extra](https://hq.example.com/admin#timestamp=1788700740&end=1788701340&style=range&extra=x)",
            "[backwards](https://hq.example.com/admin#timestamp=1788701340&end=1788700740&style=range)",
            "[negative](https://hq.example.com/admin#timestamp=-1&end=1788700740&style=range)",
            "[too late](https://hq.example.com/admin#timestamp=1788700740&end=253402300800&style=range)",
        ].joined(separator: " ")

        let rendered = ChatMarkdown.render(source)

        XCTAssertEqual(rendered.text, "extra backwards negative too late")
        XCTAssertEqual(rendered.spans.compactMap(\.link).count, 4)
    }

    func testLeavesMalformedOrNonHQTimestampLinksAsRegularLinks() {
        let source = [
            "[wrong host](https://evil.example/admin#timestamp=1788669000&style=date-time)",
            "[wrong path](https://hq.example.com/other#timestamp=1788669000&style=date-time)",
            "[wrong scheme](http://hq.example.com/admin#timestamp=1788669000&style=date-time)",
            "[extra key](https://hq.example.com/admin#timestamp=1788669000&style=date-time&extra=x)",
            "[bad timestamp](https://hq.example.com/admin#timestamp=nope&style=date-time)",
            "[out of range](https://hq.example.com/admin#timestamp=9223372036854775807&style=date-time)",
        ].joined(separator: " ")

        let rendered = ChatMarkdown.render(source)

        XCTAssertEqual(
            rendered.text,
            "wrong host wrong path wrong scheme extra key bad timestamp out of range"
        )
        XCTAssertEqual(rendered.spans.compactMap(\.link).count, 6)
    }

    // MARK: - Code and strikethrough

    private func substring(_ rendered: ChatMarkdown.Rendered, _ span: ChatMarkdown.Span) -> String {
        (rendered.text as NSString).substring(with: span.range)
    }

    func testInlineCodeIsMarkedAndLosesItsBackticks() {
        let rendered = ChatMarkdown.render("run `bun test` now")

        XCTAssertEqual(rendered.text, "run bun test now")
        let code = rendered.spans.filter(\.isCode)
        XCTAssertEqual(code.map { substring(rendered, $0) }, ["bun test"])
        XCTAssertFalse(code.first?.isCodeBlock ?? true)
    }

    func testFencedBlockKeepsItsLineBreaksAndIndentation() {
        let rendered = ChatMarkdown.render(
            "before\n```swift\nlet a = 1\n  let b = **2**\n```\nafter"
        )

        XCTAssertEqual(rendered.text, "before\nlet a = 1\n  let b = **2**\nafter")
        let blocks = rendered.spans.filter(\.isCodeBlock)
        XCTAssertEqual(blocks.map { substring(rendered, $0) }, ["let a = 1\n  let b = **2**"])
        XCTAssertTrue(blocks.first?.isCode ?? false)
        XCTAssertFalse(blocks.first?.isBold ?? true)
    }

    func testFencedBlockAtTheStartAndAnUnclosedFence() {
        let first = ChatMarkdown.render("```\nbun ci\n```\nthen ship")
        XCTAssertEqual(first.text, "bun ci\nthen ship")
        XCTAssertEqual(first.spans.filter(\.isCodeBlock).map { substring(first, $0) }, ["bun ci"])

        // A streamed answer can stop mid-fence: the rest is still code.
        let open = ChatMarkdown.render("try:\n```\nbun ci\nbun test")
        XCTAssertEqual(open.text, "try:\nbun ci\nbun test")
        XCTAssertEqual(open.spans.filter(\.isCodeBlock).map { substring(open, $0) }, ["bun ci\nbun test"])
    }

    func testMarkdownAroundAFenceStillRenders() {
        let rendered = ChatMarkdown.render("**bold** first\n```\ncode\n```\nthen *soft*")

        XCTAssertEqual(rendered.text, "bold first\ncode\nthen soft")
        XCTAssertTrue(rendered.spans.contains {
            $0.isBold && substring(rendered, $0) == "bold"
        })
        XCTAssertTrue(rendered.spans.contains {
            $0.isItalic && substring(rendered, $0) == "soft"
        })
    }

    func testMarksStrikethrough() {
        let rendered = ChatMarkdown.render("~~old~~ new")

        XCTAssertEqual(rendered.text, "old new")
        XCTAssertEqual(
            rendered.spans.filter(\.isStrikethrough).map { substring(rendered, $0) }, ["old"]
        )
    }

    func testCodeInsideBoldKeepsBothMarks() {
        let rendered = ChatMarkdown.render("**`HQ_UI_OPAQUE=1`** works")

        XCTAssertEqual(rendered.text, "HQ_UI_OPAQUE=1 works")
        XCTAssertTrue(rendered.spans.contains { $0.isCode && $0.isBold })
    }

    func testBoldItalicLinksAndMentionsStillParse() {
        let rendered = ChatMarkdown.render(
            "**b** *i* [l](https://example.com) @turner https://example.com",
            names: ["Turner"]
        )

        XCTAssertEqual(rendered.text, "b i l Turner https://example.com")
        XCTAssertTrue(rendered.spans.contains { $0.isBold && substring(rendered, $0) == "b" })
        XCTAssertTrue(rendered.spans.contains { $0.isItalic && substring(rendered, $0) == "i" })
        XCTAssertEqual(
            rendered.spans.compactMap(\.link),
            [URL(string: "https://example.com")!, URL(string: "https://example.com")!]
        )
        XCTAssertTrue(rendered.spans.contains { $0.isMention && substring(rendered, $0) == "Turner" })
        XCTAssertFalse(rendered.spans.contains { $0.isCode || $0.isStrikethrough })
    }

    func testNothingInsideCodeBecomesATagOrALink() {
        let rendered = ChatMarkdown.render(
            "`@turner https://example.com`\n```\n@turner https://example.com\n```",
            names: ["Turner"]
        )

        XCTAssertEqual(rendered.text, "@turner https://example.com\n@turner https://example.com")
        XCTAssertFalse(rendered.spans.contains { $0.isMention })
        XCTAssertTrue(rendered.spans.allSatisfy { $0.link == nil })
    }

    func testCodeAfterATagFollowsTheTextThatShrank() {
        let rendered = ChatMarkdown.render("@turner run `ci`", names: ["Turner"])

        XCTAssertEqual(rendered.text, "Turner run ci")
        XCTAssertEqual(rendered.spans.filter(\.isCode).map { substring(rendered, $0) }, ["ci"])
    }

    // MARK: - What counts as a fence

    func testAFenceWordedOnOneLineIsInlineCodeNotAFence() {
        let rendered = ChatMarkdown.render("```bun run ci``` then ship it\nand tell me")

        XCTAssertEqual(rendered.text, "bun run ci then ship it\nand tell me")
        XCTAssertFalse(rendered.spans.contains(where: \.isCodeBlock))
        XCTAssertEqual(rendered.spans.filter(\.isCode).map { substring(rendered, $0) }, ["bun run ci"])
    }

    func testAMessageThatIsOnlyAFenceLineKeepsItsText() {
        XCTAssertEqual(ChatMarkdown.render("```").text, "```")
        XCTAssertEqual(ChatMarkdown.render("```swift").text, "```swift")
        XCTAssertEqual(ChatMarkdown.render("```\n```").text, "```\n```")
        XCTAssertEqual(MentionText.plain("```bun ci```", names: []), "bun ci")
        XCTAssertEqual(MentionText.plain("```", names: []), "```")
    }

    func testCRLFSourceKeepsAFencedBlock() {
        let rendered = ChatMarkdown.render("```\r\nlet x = 1\r\n```\r\nmore words")

        XCTAssertEqual(rendered.text, "let x = 1\nmore words")
        XCTAssertEqual(
            rendered.spans.filter(\.isCodeBlock).map { substring(rendered, $0) }, ["let x = 1"]
        )
    }

    func testTextAfterAClosingFenceIsCodeNotDeleted() {
        // CommonMark: a closing fence is backticks and spaces only, so this
        // line is still inside the block — and nothing is lost.
        let rendered = ChatMarkdown.render("```\ncode\n``` trailing words\nmore")

        XCTAssertEqual(rendered.text, "code\n``` trailing words\nmore")
        XCTAssertEqual(rendered.spans.filter(\.isCodeBlock).count, 1)
    }

    func testAnInfoLineInsideAnOpenBlockDoesNotCloseIt() {
        let rendered = ChatMarkdown.render("```\nfirst\n```swift\nsecond\n```\nafter")

        XCTAssertEqual(rendered.text, "first\n```swift\nsecond\nafter")
        XCTAssertEqual(
            rendered.spans.filter(\.isCodeBlock).map { substring(rendered, $0) },
            ["first\n```swift\nsecond"]
        )
    }

    func testABlankLineInsideABlockStaysInsideIt() {
        let rendered = ChatMarkdown.render("```\none\n\ntwo\n```")

        XCTAssertEqual(rendered.text, "one\n\ntwo")
        XCTAssertEqual(rendered.spans.filter(\.isCodeBlock).map(\.range), [NSRange(location: 0, length: 8)])
    }

    func testInfoStringsAndTrailingSpacesOnFencesAreAccepted() {
        let rendered = ChatMarkdown.render("```swift \nlet a = 1\n```  \nok")

        XCTAssertEqual(rendered.text, "let a = 1\nok")
        XCTAssertEqual(rendered.spans.filter(\.isCodeBlock).count, 1)
    }

    func testABlockHoldingOnlyBlankLinesKeepsItsFenceText() {
        XCTAssertEqual(ChatMarkdown.render("```\n\n```").text, "```\n\n```")
        XCTAssertEqual(MentionText.plain("```\n\n```", names: []), "```\n\n```")
        XCTAssertEqual(ChatMarkdown.render("```\n  \n```").text, "```\n  \n```")
    }

    func testAFenceLineEndingInABackslashKeepsIt() {
        XCTAssertEqual(ChatMarkdown.render("```\\\n```").text, "```\\\n```")
        XCTAssertEqual(ChatMarkdown.render("```c:\\dir\\\n```").text, "```c:\\dir\\\n```")
    }

    /// White code text on your own (blue) bubble must clear 4.5:1 through the
    /// code wash in both appearances. The bubble colours mirror
    /// `Tokens.Palette.messageOutgoing` (light 0x0062ED, dark 0x0A84FF).
    func testCodeOnYourOwnBubbleKeepsReadableContrast() {
        for (isDark, bubble) in [(false, 0x0062ED), (true, 0x0A84FF)] {
            let wash = ChatMarkdown.CodeStyle.fill(isOwn: true, isDark: isDark)
            let channels = [(bubble >> 16) & 0xFF, (bubble >> 8) & 0xFF, bubble & 0xFF].map { Double($0) / 255 }
            let washed = channels.map { $0 * (1 - wash.opacity) + wash.white * wash.opacity }
            let ratio = 1.05 / (Self.luminance(washed) + 0.05)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "code on the own bubble, \(isDark ? "dark" : "light")")
        }
    }

    private static func luminance(_ rgb: [Double]) -> Double {
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private func rangeLink(start: Int64, end: Int64) -> String {
        "[range](https://hq.example.com/admin#timestamp=\(start)&end=\(end)&style=range)"
    }
}

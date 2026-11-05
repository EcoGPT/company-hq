import Foundation
import XCTest
@testable import HQ

/// The hinge between what a tag IS on the wire (`@Turner`) and what it LOOKS
/// like (Turner, tinted). Everything the composers and the bubbles do rests
/// on these two directions agreeing.
final class MentionTextTests: XCTestCase {
    private let roster = ["Turner", "Bo", "Scout", "Bo Turner", "Ada", "Samantha"]

    // MARK: - Finding tags

    func testMatchesATagAndTakesTheRosterSpelling() {
        let matches = MentionText.matches(in: "hey @turner look", names: roster)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.name, "Turner")
    }

    func testPrefersTheLongerName() {
        let matches = MentionText.matches(in: "@Bo Turner ships it", names: roster)

        XCTAssertEqual(matches.map(\.name), ["Bo Turner"])
    }

    func testIgnoresAnAtInsideAWord() {
        XCTAssertTrue(MentionText.matches(in: "mail me@turner.com", names: roster).isEmpty)
    }

    func testIgnoresANameThatRunsOnIntoMore() {
        XCTAssertTrue(MentionText.matches(in: "@turnerism", names: roster).isEmpty)
    }

    func testIgnoresNamesNobodyHas() {
        XCTAssertTrue(MentionText.matches(in: "@lunch at noon", names: roster).isEmpty)
    }

    func testFindsEveryTagInALine() {
        let matches = MentionText.matches(in: "@Bo and @Scout, plus @Turner", names: roster)

        XCTAssertEqual(matches.map(\.name), ["Bo", "Scout", "Turner"])
    }

    // MARK: - Wire and display

    func testDisplayDropsTheAtAndReportsWhereTheTagLands() {
        let display = MentionText.display(from: "hey @turner look", names: roster)

        XCTAssertEqual(display.text, "hey Turner look")
        XCTAssertEqual(display.runs, [NSRange(location: 4, length: 6)])
    }

    func testDisplayLeavesAHalfTypedTokenAlone() {
        let display = MentionText.display(from: "hey @turne", names: roster)

        XCTAssertEqual(display.text, "hey @turne")
        XCTAssertTrue(display.runs.isEmpty)
    }

    func testWireRestoresTheAt() {
        let display = MentionText.display(from: "hey @Turner and @Scout", names: roster)
        let wire = MentionText.wire(fromDisplay: display.text, runs: display.runs)

        XCTAssertEqual(wire, "hey @Turner and @Scout")
    }

    func testRoundTripCanonicalisesTheSpelling() {
        let display = MentionText.display(from: "@turner @SCOUT", names: roster)

        XCTAssertEqual(
            MentionText.wire(fromDisplay: display.text, runs: display.runs),
            "@Turner @Scout"
        )
    }

    func testWireIgnoresRunsThatFellOutOfTheString() {
        let wire = MentionText.wire(
            fromDisplay: "Turner", runs: [NSRange(location: 0, length: 99)]
        )

        XCTAssertEqual(wire, "Turner")
    }

    func testTextWithNoTagsSurvivesUntouched() {
        let source = "no tags here at all"
        let display = MentionText.display(from: source, names: roster)

        XCTAssertEqual(display.text, source)
        XCTAssertEqual(MentionText.wire(fromDisplay: display.text, runs: display.runs), source)
    }

    // MARK: - Committing

    func testAnExactNameWinsOverALongerOneStartingTheSameWay() {
        XCTAssertEqual(MentionText.commitName(for: "ada", names: roster), "Ada")
    }

    func testASolePrefixCommits() {
        XCTAssertEqual(MentionText.commitName(for: "turn", names: roster), "Turner")
    }

    func testAnAmbiguousPrefixCommitsToNobody() {
        XCTAssertNil(MentionText.commitName(for: "b", names: ["Bea", "Bo"]))
    }

    func testAnEmptyTokenCommitsToNobody() {
        XCTAssertNil(MentionText.commitName(for: "", names: roster))
    }

    // MARK: - The token under the caret

    func testTheTrailingTokenIsWhatIsBeingTyped() {
        let found = MentionText.trailingToken(before: "hey @turne")

        XCTAssertEqual(found?.token, "turne")
    }

    func testAFinishedWordIsNotAToken() {
        XCTAssertNil(MentionText.trailingToken(before: "hey @turner "))
    }

    func testAnAddressIsNotAToken() {
        XCTAssertNil(MentionText.trailingToken(before: "mail me@turner"))
    }

    func testOnlyALiveTokenIsWorthTinting() {
        XCTAssertTrue(MentionText.isLiveToken("tur", names: roster))
        XCTAssertFalse(MentionText.isLiveToken("zzz", names: roster))
        XCTAssertFalse(MentionText.isLiveToken("", names: roster))
    }

    // MARK: - Addressing the room

    func testABroadcastKeepsItsAt() {
        let display = MentionText.display(from: "ship it @everyone", names: roster)

        XCTAssertEqual(display.text, "ship it @everyone")
        XCTAssertEqual(display.runs, [NSRange(location: 8, length: 9)])
    }

    func testABroadcastTakesItsCanonicalSpelling() {
        XCTAssertEqual(MentionText.plain("@EVERYONE ship it", names: roster), "@everyone ship it")
        XCTAssertEqual(MentionText.plain("@Here now", names: roster), "@here now")
    }

    func testPlainSurfacesRenderMarkdownAndKeepResolvedMentions() {
        let source = "**Done: [release notes](https://hq.example.com/notes#part=abc)**\n\nPlain evidence.\n\n@Turner"

        XCTAssertEqual(
            MentionText.plain(source, names: roster),
            "Done: release notes\n\nPlain evidence.\n\nTurner"
        )
    }

    func testABroadcastResolvesWithNoRosterLoaded() {
        XCTAssertEqual(MentionText.matches(in: "@here now", names: []).map(\.name), ["@here"])
    }

    func testABroadcastRunsOnIntoMoreIsNotATag() {
        XCTAssertTrue(MentionText.matches(in: "@everyones lunch", names: roster).isEmpty)
        XCTAssertTrue(MentionText.matches(in: "mail me@here.com", names: roster).isEmpty)
    }

    func testARosterNameBeatsABroadcastOfTheSameLength() {
        let matches = MentionText.matches(in: "@here", names: ["Here"])

        XCTAssertEqual(matches.map(\.name), ["Here"])
        XCTAssertNil(matches.first?.broadcast)
    }

    func testABroadcastSurvivesTheRoundTripWithoutGrowingASecondAt() {
        let display = MentionText.display(from: "@here and @Turner", names: roster)

        XCTAssertEqual(
            MentionText.wire(fromDisplay: display.text, runs: display.runs),
            "@here and @Turner"
        )
    }

    func testABroadcastCommitsToItsOwnSpelling() {
        XCTAssertEqual(MentionText.commitName(for: "here", names: roster), "@here")
        XCTAssertEqual(MentionText.commitName(for: "every", names: roster), "@everyone")
        XCTAssertTrue(MentionText.isLiveToken("ever", names: []))
    }

    func testOnlyEveryoneBreaksThroughHiddenAlerts() {
        XCTAssertTrue(MentionText.mentionsEveryone("ship it @everyone"))
        XCTAssertTrue(MentionText.mentionsEveryone("@Everyone"))
        XCTAssertFalse(MentionText.mentionsEveryone("@here"))
        XCTAssertFalse(MentionText.mentionsEveryone("everyone should ship"))
        XCTAssertFalse(MentionText.mentionsEveryone("mail me@everyone.com"))
        XCTAssertFalse(MentionText.mentionsEveryone("@everyones lunch"))
    }

    // MARK: - Bubbles

    func testABubbleDrawsTheTagWithoutItsAt() {
        let rendered = ChatMarkdown.render("hey @turner look", names: roster)

        XCTAssertEqual(rendered.text, "hey Turner look")
        XCTAssertTrue(
            rendered.spans.contains {
                $0.isMention && $0.range == NSRange(location: 4, length: 6)
            }
        )
    }

    func testABubbleWithoutARosterIsUnchanged() {
        let rendered = ChatMarkdown.render("hey @turner look")

        XCTAssertEqual(rendered.text, "hey @turner look")
        XCTAssertFalse(rendered.spans.contains(where: \.isMention))
    }

    func testEmphasisAfterATagFollowsTheTextThatShrank() {
        let rendered = ChatMarkdown.render("@turner said **yes**", names: roster)

        XCTAssertEqual(rendered.text, "Turner said yes")
        XCTAssertTrue(
            rendered.spans.contains {
                $0.isBold && $0.range == NSRange(location: 12, length: 3)
            }
        )
    }

    func testABubbleTintsABroadcastWithoutShorteningIt() {
        let rendered = ChatMarkdown.render("ship it @everyone", names: roster)

        XCTAssertEqual(rendered.text, "ship it @everyone")
        XCTAssertTrue(
            rendered.spans.contains {
                $0.isMention && $0.range == NSRange(location: 8, length: 9)
            }
        )
    }

    func testALinkAfterATagStillPointsAtTheLink() {
        let rendered = ChatMarkdown.render("@Scout see https://example.com", names: roster)

        XCTAssertEqual(rendered.text, "Scout see https://example.com")
        let link = rendered.spans.first { $0.link != nil }
        XCTAssertEqual(
            link.map { (rendered.text as NSString).substring(with: $0.range) },
            "https://example.com"
        )
    }
}

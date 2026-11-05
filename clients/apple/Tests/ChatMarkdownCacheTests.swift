import AppKit
import XCTest

@testable import HQ

// `ChatMarkdown.render` is memoised process-wide: the same message is rendered
// by its bubble, by every size probe, by a sidebar preview and by each reply
// that quotes it, and again from empty on every chat switch. The memo must be
// invisible — the cached answer is the very value an uncached render builds —
// and a repeat call must come from the cache.
final class ChatMarkdownCacheTests: XCTestCase {
    private var previousServer: String?

    override func setUp() {
        previousServer = HQConfig.savedServer
        HQConfig.savedServer = "https://hq.example.com"
    }

    override func tearDown() {
        HQConfig.savedServer = previousServer
    }

    private let roster = ["Bo", "Bo Turner", "Scout", "Turner"]
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private var inputs: [String] {
        [
            "plain words",
            "**bold** and *italic* and ~~gone~~",
            "run `bun test` now",
            "try:\n```swift\nlet x = 1\n```\nthen ship",
            "```\nopen fence still streaming",
            "see https://example.com/docs and mail me@work.com",
            "[the docs](https://example.com) are here",
            "@turner and @Bo Turner and @everyone, not me@turner.com",
            "- first\n- **second**\n- third",
            "[label](https://hq.example.com/admin#timestamp=1788669000&style=date-time) **after**",
            "",
        ]
    }

    /// The cache and its counters are process-wide and the test host is the
    /// running app, so nothing here asserts an absolute count or empties the
    /// cache: each test uses sources of its own (a fresh id in the text) and
    /// reads the counters before and after.
    private func uniqueSource(_ text: String) -> String { "\(text) \(UUID().uuidString)" }

    func testCachedRenderEqualsUncachedRender() {
        for source in inputs {
            for names in [[], roster] {
                for zone in [newYork, losAngeles] {
                    let uncached = ChatMarkdown.renderUncached(source, names: names, timeZone: zone)
                    let first = ChatMarkdown.render(source, names: names, timeZone: zone)
                    let second = ChatMarkdown.render(source, names: names, timeZone: zone)
                    XCTAssertEqual(first, uncached, "first render of \(source.debugDescription)")
                    XCTAssertEqual(second, uncached, "cached render of \(source.debugDescription)")
                }
            }
        }
    }

    func testSecondCallComesFromTheCache() {
        let source = uniqueSource("run `bun test` for @turner at https://example.com")
        let start = ChatMarkdown.RenderCache.stats
        _ = ChatMarkdown.render(source, names: roster, timeZone: newYork)
        let afterFirst = ChatMarkdown.RenderCache.stats
        XCTAssertEqual(afterFirst.misses - start.misses, 1)
        XCTAssertEqual(afterFirst.hits - start.hits, 0)

        _ = ChatMarkdown.render(source, names: roster, timeZone: newYork)
        // A different array with the same names is the same roster.
        _ = ChatMarkdown.render(source, names: roster.map { String($0) }, timeZone: newYork)
        let afterRepeat = ChatMarkdown.RenderCache.stats
        XCTAssertEqual(afterRepeat.misses - afterFirst.misses, 0, "no further render ran")
        XCTAssertEqual(afterRepeat.hits - afterFirst.hits, 2)
    }

    func testRosterZoneAndSourceAreEachPartOfTheKey() {
        let source = uniqueSource(
            "@turner ships [at](https://hq.example.com/admin#timestamp=1788669000&style=date-time)")
        let start = ChatMarkdown.RenderCache.stats
        let withRoster = ChatMarkdown.render(source, names: roster, timeZone: newYork)
        let withoutRoster = ChatMarkdown.render(source, names: [], timeZone: newYork)
        let otherZone = ChatMarkdown.render(source, names: roster, timeZone: losAngeles)
        let otherRoster = ChatMarkdown.render(source, names: ["Turner"], timeZone: newYork)
        XCTAssertEqual(
            ChatMarkdown.RenderCache.stats.misses - start.misses, 4,
            "four distinct keys, four renders")

        // The roster decides whether the tag is drawn as a mention.
        XCTAssertNotEqual(withRoster, withoutRoster)
        XCTAssertTrue(withRoster.spans.contains(where: \.isMention))
        XCTAssertFalse(withoutRoster.spans.contains(where: \.isMention))
        // The zone decides how the timestamp reads.
        XCTAssertNotEqual(withRoster.text, otherZone.text)
        XCTAssertEqual(otherRoster.text, withRoster.text)
    }

    func testVeryLongSourceIsRenderedButNotKept() {
        let source = uniqueSource(
            String(repeating: "word ", count: ChatMarkdown.RenderCache.maxSourceLength / 4))
        let start = ChatMarkdown.RenderCache.stats
        let first = ChatMarkdown.render(source)
        let second = ChatMarkdown.render(source)
        XCTAssertEqual(first, second)
        XCTAssertEqual(ChatMarkdown.RenderCache.stats.hits - start.hits, 0)
    }

    func testPlainTextStillAgreesWithTheBubble() {
        // MentionText.plain, the sidebar preview and the reply quote, rides
        // the same cache and must read the way the bubble does.
        let source = "@turner said **yes** to `ci`"
        XCTAssertEqual(
            MentionText.plain(source, names: roster),
            ChatMarkdown.renderUncached(source, names: roster).text
        )
    }

    // MARK: Roster identity

    func testRosterIDIsContentKeyed() {
        XCTAssertEqual(MentionText.rosterID([]), 0)
        let a = MentionText.rosterID(roster)
        XCTAssertNotEqual(a, 0)
        XCTAssertEqual(MentionText.rosterID(roster), a)
        XCTAssertEqual(MentionText.rosterID(roster.map { String($0) }), a, "same names, new array")
        let b = MentionText.rosterID(roster + ["Zed"])
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(MentionText.rosterID(roster), a, "going back to a roster finds its id again")
    }

    func testMatchesAreUnchangedByTheCandidateMemo() {
        // Warm the memo with one roster, then ask with another and with none:
        // each answer is its own roster's.
        _ = MentionText.matches(in: "hi @turner", names: roster)
        XCTAssertTrue(MentionText.matches(in: "hi @turner", names: []).isEmpty)
        XCTAssertEqual(MentionText.matches(in: "hi @turner", names: ["Turner"]).map(\.name), ["Turner"])
        XCTAssertEqual(
            MentionText.matches(in: "hi @bo turner", names: roster).map(\.name), ["Bo Turner"]
        )
        XCTAssertEqual(MentionText.matches(in: "no tags here", names: roster).count, 0)
    }

    // MARK: Bubble memory

    /// Each attribute run as "location,length: keys | font", colours left out
    /// (see the test below): enough to tell a different styling from the same.
    private static func styleRuns(_ string: NSAttributedString) -> [String] {
        var runs: [String] = []
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, range, _ in
            let keys = attributes.keys.map(\.rawValue).sorted().joined(separator: ",")
            let font = (attributes[.font] as? NSFont).map { "\($0.fontName) \($0.pointSize)" } ?? "-"
            runs.append("\(range.location),\(range.length): \(keys) | \(font)")
        }
        return runs
    }

    @MainActor
    func testBubbleMemoryReturnsTheSameStringAndSizeForARepeat() {
        SelectableBubbleText.Memory.reset()
        let text = "@turner see `code` and https://example.com"
        let first = SelectableBubbleText.Memory.attributed(text: text, isOwn: false, names: roster)
        let second = SelectableBubbleText.Memory.attributed(text: text, isOwn: false, names: roster)
        XCTAssertTrue(first === second, "a repeat is the cached string, not a rebuild")
        // Same text and the same styling run for run. Not `==` on the strings:
        // the bubble ink is a dynamic NSColor made fresh on every build, and
        // two such colours never compare equal even when they draw the same.
        let fresh = SelectableBubbleText.attributedString(for: text, isOwn: false, names: roster)
        XCTAssertEqual(first.string, fresh.string)
        XCTAssertEqual(Self.styleRuns(first), Self.styleRuns(fresh))
        // The bubble side is part of the key: colours differ.
        let own = SelectableBubbleText.Memory.attributed(text: text, isOwn: true, names: roster)
        XCTAssertFalse(own === first)

        XCTAssertNil(SelectableBubbleText.Memory.size(text: text, names: roster, width: 420))
        SelectableBubbleText.Memory.remember(
            CGSize(width: 200, height: 40), text: text, names: roster, width: 420)
        XCTAssertEqual(
            SelectableBubbleText.Memory.size(text: text, names: roster, width: 420),
            CGSize(width: 200, height: 40))
        XCTAssertNil(SelectableBubbleText.Memory.size(text: text, names: roster, width: 0))
        XCTAssertNil(SelectableBubbleText.Memory.size(text: text, names: [], width: 420))
    }

    func testBoundedMemoryForgetsTheOldestFirst() {
        var memory = SelectableBubbleText.Memory.Bounded<Int, String>(limit: 3)
        for index in 0..<5 { memory.insert("v\(index)", for: index) }
        XCTAssertEqual(memory.count, 3)
        XCTAssertNil(memory[0])
        XCTAssertNil(memory[1])
        XCTAssertEqual(memory[2], "v2")
        XCTAssertEqual(memory[4], "v4")
        // Re-inserting a present key does not grow the queue or evict anything.
        memory.insert("v2b", for: 2)
        XCTAssertEqual(memory.count, 3)
        XCTAssertEqual(memory[2], "v2b")
    }
}

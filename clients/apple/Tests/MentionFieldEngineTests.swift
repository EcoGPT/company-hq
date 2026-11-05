import AppKit
import XCTest
@testable import HQ

/// The rules the composer's storage obeys, driven directly: a tag arrives on
/// a space, leaves whole on a delete, and dissolves when typed into.
final class MentionFieldEngineTests: XCTestCase {
    private func engine(_ names: [String] = ["Turner", "Bo", "Scout"]) -> MentionFieldEngine {
        let engine = MentionFieldEngine(
            baseFont: .systemFont(ofSize: 15), baseColor: .labelColor, accent: .systemBlue
        )
        engine.names = names
        return engine
    }

    private func storage(_ engine: MentionFieldEngine, wire: String) -> NSTextStorage {
        let storage = NSTextStorage()
        storage.setAttributedString(engine.attributed(forWire: wire))
        return storage
    }

    // MARK: - Arriving

    func testASpaceCommitsAHalfTypedToken() {
        let engine = engine()
        let storage = storage(engine, wire: "hey @tur")

        let commit = engine.commit(in: storage, caret: storage.length, typed: " ")

        XCTAssertEqual(commit?.0, NSRange(location: 4, length: 4))
        XCTAssertEqual(commit?.1.string, "Turner ")
    }

    func testATabCommitsTheSameWay() {
        let engine = engine()
        let storage = storage(engine, wire: "@b")

        XCTAssertEqual(engine.commit(in: storage, caret: 2, typed: "\t")?.1.string, "Bo ")
    }

    /// A draft restored from outside — the picker, or a saved one — arrives
    /// already resolved, because a whole name is a whole name however it got
    /// there. Only what is being typed waits for its space.
    func testARestoredDraftArrivesAlreadyTagged() {
        let engine = engine()
        let storage = storage(engine, wire: "@bo")

        XCTAssertEqual(storage.string, "Bo")
        XCTAssertEqual(engine.wire(from: storage), "@Bo")
    }

    /// The one tag that arrives WITH its `@`. It has to survive a round trip
    /// through the storage without collecting a second one — the display form
    /// and the wire form of `@everyone` are the same string, and only the run
    /// says it is a tag at all.
    func testABroadcastCommitsWithItsAtAndSurvivesTheRoundTrip() {
        let engine = engine()
        let storage = storage(engine, wire: "ship it @every")

        let commit = engine.commit(in: storage, caret: storage.length, typed: " ")

        XCTAssertEqual(commit?.0, NSRange(location: 8, length: 6))
        XCTAssertEqual(commit?.1.string, "@everyone ")

        let settled = self.storage(engine, wire: "ship it @everyone")
        XCTAssertEqual(settled.string, "ship it @everyone")
        XCTAssertEqual(engine.wire(from: settled), "ship it @everyone")
    }

    /// The broadcasts are `MentionText`'s own, not the roster's: a composer
    /// in a room whose people have not loaded still tints and commits them.
    func testABroadcastNeedsNoRoster() {
        let engine = engine([])
        let storage = storage(engine, wire: "@here")

        XCTAssertEqual(storage.string, "@here")
        XCTAssertNotNil(engine.liveTokenRange(in: "@her", caret: 4))
    }

    func testAnOrdinaryLetterCommitsNothing() {
        let engine = engine()
        let storage = storage(engine, wire: "hey @tur")

        XCTAssertNil(engine.commit(in: storage, caret: storage.length, typed: "n"))
    }

    func testASpaceAfterANameNobodyHasCommitsNothing() {
        let engine = engine()
        let storage = storage(engine, wire: "hey @lunch")

        XCTAssertNil(engine.commit(in: storage, caret: storage.length, typed: " "))
    }

    func testTheCommittedRunCarriesItsTag() {
        let engine = engine()
        let storage = storage(engine, wire: "@tur")
        guard let (range, replacement) = engine.commit(in: storage, caret: 4, typed: " ") else {
            return XCTFail("expected a commit")
        }
        storage.replaceCharacters(in: range, with: replacement)

        XCTAssertEqual(storage.string, "Turner ")
        XCTAssertEqual(engine.wire(from: storage), "@Turner ")
    }

    // MARK: - The storage as the wire sees it

    func testWireTextBecomesTaggedDisplayText() {
        let engine = engine()
        let storage = storage(engine, wire: "hey @Turner and @Scout")

        XCTAssertEqual(storage.string, "hey Turner and Scout")
        XCTAssertEqual(engine.wire(from: storage), "hey @Turner and @Scout")
    }

    func testTwoTagsSideBySideStaySeparate() {
        let engine = engine()
        let storage = storage(engine, wire: "@Scout @Scout")

        XCTAssertEqual(storage.string, "Scout Scout")
        XCTAssertEqual(engine.wire(from: storage), "@Scout @Scout")
    }

    func testAHalfTypedTokenIsNotYetATag() {
        let engine = engine()
        let storage = storage(engine, wire: "hey @turne")

        XCTAssertEqual(storage.string, "hey @turne")
        XCTAssertEqual(engine.wire(from: storage), "hey @turne")
    }

    // MARK: - Leaving

    func testBackspaceAtTheEndOfATagTakesTheWholeTag() {
        let engine = engine()
        let storage = storage(engine, wire: "hey @Turner")
        // The last character of "Turner", which is what a backspace proposes.
        let proposed = NSRange(location: storage.length - 1, length: 1)

        XCTAssertEqual(
            engine.deletionRange(in: storage, range: proposed),
            NSRange(location: 4, length: 6)
        )
    }

    func testADeleteThatMissesEveryTagIsLeftAlone() {
        let engine = engine()
        let storage = storage(engine, wire: "hey @Turner ok")
        let proposed = NSRange(location: storage.length - 1, length: 1)

        XCTAssertEqual(engine.deletionRange(in: storage, range: proposed), proposed)
    }

    func testTypingInsideATagDissolvesIt() {
        let engine = engine()
        let storage = storage(engine, wire: "hey @Turner")

        engine.breakMentions(in: storage, editing: NSRange(location: 7, length: 0))

        XCTAssertEqual(engine.wire(from: storage), "hey Turner")
    }

    func testTypingRightAfterATagLeavesItAlone() {
        let engine = engine()
        let storage = storage(engine, wire: "hey @Turner")

        engine.breakMentions(in: storage, editing: NSRange(location: storage.length, length: 0))

        XCTAssertEqual(engine.wire(from: storage), "hey @Turner")
    }

    // MARK: - Tinting

    func testTheTokenUnderTheCaretIsLive() {
        let engine = engine()
        let storage = storage(engine, wire: "hey @tur")

        XCTAssertEqual(
            engine.liveTokenRange(in: storage.string, caret: 8),
            NSRange(location: 4, length: 4)
        )
    }

    func testACommittedTagIsNoLongerALiveToken() {
        let engine = engine()
        let storage = storage(engine, wire: "hey @Turner ")

        XCTAssertNil(engine.liveTokenRange(in: storage.string, caret: storage.length))
    }

    func testATokenNobodyAnswersToIsNotLive() {
        let engine = engine()
        let storage = storage(engine, wire: "hey @zzz")

        XCTAssertNil(engine.liveTokenRange(in: storage.string, caret: storage.length))
    }

    @MainActor
    func testComposerDocumentTracksTheViewportAcrossAResize() {
        let scroll = MentionComposerScrollView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 44)
        )
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 44))
        scroll.documentView = view

        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.frame.width, scroll.contentView.bounds.width, accuracy: 0.5)
        XCTAssertEqual(view.frame.height, 44)

        scroll.setFrameSize(NSSize(width: 320, height: 44))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.frame.width, scroll.contentView.bounds.width, accuracy: 0.5)
        XCTAssertEqual(view.frame.height, 44)
    }
}

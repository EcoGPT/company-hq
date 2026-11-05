import AppKit
import XCTest

@testable import HQ

// Every keystroke restyles the composer's draft twice (the selection change,
// then the text change). Repainting the whole draft each time invalidated its
// whole layout, so typing slowed with the draft's length. The restyle now
// rewrites only the runs that are wrong; these pin that its end state is
// exactly the full repaint's, and that a settled draft is not edited at all.
final class MentionRestyleTests: XCTestCase {
    private let names = ["Turner", "Bo", "Scout", "Kate"]
    private let baseFont = NSFont.systemFont(ofSize: 15)
    private let accent = NSColor.systemBlue

    private func engine() -> MentionFieldEngine {
        let engine = MentionFieldEngine(baseFont: baseFont, baseColor: .labelColor, accent: accent)
        engine.names = names
        return engine
    }

    private func storage(_ engine: MentionFieldEngine, wire: String) -> NSTextStorage {
        let storage = NSTextStorage()
        storage.setAttributedString(engine.attributed(forWire: wire))
        return storage
    }

    /// The full-range restyle as it was, kept as the reference.
    private func referenceRestyle(_ engine: MentionFieldEngine, _ storage: NSTextStorage, caret: Int) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        var tags: [(NSRange, MentionTag)] = []
        storage.enumerateAttribute(.hqMention, in: full) { value, range, _ in
            if let tag = value as? MentionTag { tags.append((range, tag)) }
        }
        let mentionFont = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
        storage.beginEditing()
        storage.setAttributes(engine.baseAttributes, range: full)
        for (range, tag) in tags {
            storage.addAttributes(
                [.font: mentionFont, .foregroundColor: accent, .hqMention: tag], range: range
            )
        }
        if let token = engine.liveTokenRange(in: storage.string, caret: caret) {
            storage.addAttribute(.foregroundColor, value: accent, range: token)
        }
        storage.endEditing()
    }

    private func assertMatchesReference(
        _ engine: MentionFieldEngine, _ original: NSTextStorage, caret: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = NSTextStorage(attributedString: original)
        let actual = NSTextStorage(attributedString: original)
        referenceRestyle(engine, expected, caret: caret)
        engine.restyle(actual, caret: caret)
        XCTAssertTrue(actual.isEqual(to: expected), "\(actual) != \(expected)", file: file, line: line)
    }

    // MARK: - The end state is the full repaint's

    func testPlainText() {
        let engine = engine()
        let storage = storage(engine, wire: "nothing tagged in here")
        assertMatchesReference(engine, storage, caret: storage.length)
    }

    func testTwoAdjacentTags() {
        let engine = engine()
        let storage = storage(engine, wire: "@Turner @Bo can you look")
        assertMatchesReference(engine, storage, caret: storage.length)
        assertMatchesReference(engine, storage, caret: 3)
    }

    func testALiveTokenAtTheCaret() {
        let engine = engine()
        let storage = storage(engine, wire: "@Turner and @Ka")
        XCTAssertNotNil(engine.liveTokenRange(in: storage.string, caret: storage.length))
        assertMatchesReference(engine, storage, caret: storage.length)
    }

    func testACaretOutsideAToken() {
        let engine = engine()
        let storage = storage(engine, wire: "hello @Ka there")
        assertMatchesReference(engine, storage, caret: 0)
    }

    func testAStrayPastedAttributeIsRepainted() {
        let engine = engine()
        let storage = storage(engine, wire: "@Turner pasted some red text")
        storage.addAttributes(
            [.foregroundColor: NSColor.systemRed, .underlineStyle: NSUnderlineStyle.single.rawValue],
            range: NSRange(location: 2, length: 15)
        )
        assertMatchesReference(engine, storage, caret: storage.length)
    }

    func testAHiddenPopRangeIsRepainted() {
        let engine = engine()
        let storage = storage(engine, wire: "hi @Bo ")
        engine.hide(NSRange(location: 3, length: 5), in: storage)
        assertMatchesReference(engine, storage, caret: storage.length)
    }

    // MARK: - A settled draft is not edited

    private final class EditRecorder: NSObject, NSTextStorageDelegate {
        var edits: [NSRange] = []
        func textStorage(
            _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange, changeInLength delta: Int
        ) {
            edits.append(editedRange)
        }
    }

    private func longWire(_ length: Int) -> String {
        var wire = ""
        var turn = 0
        while wire.utf16.count < length {
            wire += turn % 3 == 0 ? "@Turner " : "the numbers moved again this week, "
            turn += 1
        }
        return wire
    }

    func testARestyleOfASettledDraftEditsNothing() {
        let engine = engine()
        let storage = storage(engine, wire: longWire(3_000))
        engine.restyle(storage, caret: storage.length)

        let recorder = EditRecorder()
        storage.delegate = recorder
        engine.restyle(storage, caret: storage.length)
        XCTAssertEqual(recorder.edits, [])

        storage.append(NSAttributedString(string: "x", attributes: engine.baseAttributes))
        recorder.edits = []
        engine.restyle(storage, caret: storage.length)
        XCTAssertTrue(
            recorder.edits.allSatisfy { $0.length < 10 },
            "restyle after one keystroke edited \(recorder.edits)"
        )
        storage.delegate = nil
    }

    // The measured check: one simulated keystroke on a live text view (append,
    // the two restyles, layout). Printed, not asserted; the numbers go in the PR.
    @MainActor
    func testKeystrokeCost() {
        for length in [3_000, 12_000] {
            let engine = engine()
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            guard let storage = view.textStorage, let layout = view.layoutManager,
                  let container = view.textContainer else { return XCTFail("no TextKit 1 stack") }
            storage.setAttributedString(engine.attributed(forWire: longWire(length)))
            engine.restyle(storage, caret: storage.length)
            layout.ensureLayout(for: container)
            let keystrokes = 40
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<keystrokes {
                storage.append(NSAttributedString(string: "x", attributes: engine.baseAttributes))
                engine.restyle(storage, caret: storage.length)
                engine.restyle(storage, caret: storage.length)
                layout.ensureLayout(for: container)
            }
            let mean = (CFAbsoluteTimeGetCurrent() - start) * 1_000 / Double(keystrokes)
            print("MentionRestyleTests keystroke at \(length) chars: \(String(format: "%.2f", mean)) ms")
        }
    }
}

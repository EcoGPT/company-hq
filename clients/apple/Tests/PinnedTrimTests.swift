import XCTest
@testable import HQ

/// The open chat is trimmed too: while its transcript is pinned to
/// the newest message, rows past the window plus a page go a turn later, and
/// no trim drops rows from under a transcript on screen. Hosted, on the chat
/// fixture like `OwnEchoTests`.
@MainActor
final class PinnedTrimTests: XCTestCase {
    private var previousScenario: String?

    override func setUp() async throws {
        previousScenario = ProcessInfo.processInfo.environment["HQ_UI_SCENARIO"]
        setenv("HQ_UI_SCENARIO", "chat", 1)
        HQFixtureProtocol.contentMode = "ready"
    }

    override func tearDown() async throws {
        HQFixtureProtocol.contentMode = "ready"
        if let previousScenario {
            setenv("HQ_UI_SCENARIO", previousScenario, 1)
        } else {
            unsetenv("HQ_UI_SCENARIO")
        }
    }

    /// The "studio" chat open with its history marked exhausted, then the
    /// fixture offline: `rows` more confirmed messages arrive and one send
    /// fails and stays pending.
    private func loadedStore(rows: Int) async -> AppStore {
        precondition(HQSimulatorFixture.isEnabled)
        let store = AppStore()
        store.start()
        store.openConversation("studio")
        await store.loadMessages("studio")
        // The fixture answers every older page with nothing.
        await store.loadOlder(in: "studio")
        XCTAssertTrue(store.exhaustedHistory.contains("studio"))
        HQFixtureProtocol.contentMode = "error"
        for index in 0..<rows {
            store.handle(.message(Message(
                id: String(format: "zz-%04d", index), conversationId: "studio",
                senderPersonId: "bo", senderName: "bo", content: "row \(index)",
                createdAt: "2026-10-29T12:00:00Z"
            )))
        }
        store.send("still sending", in: "studio")
        await settle()
        return store
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func confirmed(_ store: AppStore, _ id: String = "studio") -> [Message] {
        store.messages(in: id).filter { !$0.id.hasPrefix("pending-") }
    }

    private func pending(_ store: AppStore, _ id: String = "studio") -> [String] {
        store.messages(in: id).filter { $0.id.hasPrefix("pending-") }.map(\.id)
    }

    func testAPinnedChatOverTheLimitKeepsTheWindowAndItsPendingRowsATurnLater() async {
        let store = await loadedStore(rows: 140)
        let outgoing = pending(store)
        XCTAssertEqual(outgoing.count, 1)
        let before = store.messages(in: "studio").count
        XCTAssertGreaterThan(before, StateCache.messagesKept + AppStore.pinnedTrimSlack)
        store.trimPinnedTranscript("studio") { true }
        XCTAssertEqual(store.messages(in: "studio").count, before, "never inside the caller's update")
        await settle()
        XCTAssertEqual(confirmed(store).count, StateCache.messagesKept)
        XCTAssertEqual(confirmed(store).last?.id, "zz-0139", "the newest rows stay")
        XCTAssertEqual(pending(store), outgoing)
        XCTAssertFalse(store.exhaustedHistory.contains("studio"))
    }

    func testAChatScrolledUpKeepsEveryRow() async {
        let store = await loadedStore(rows: 140)
        let before = store.messages(in: "studio").count
        store.trimPinnedTranscript("studio") { false }
        await settle()
        XCTAssertEqual(store.messages(in: "studio").count, before)
    }

    func testAChatWithinAPageOfTheWindowKeepsEveryRow() async {
        let store = await loadedStore(rows: 40)
        let before = store.messages(in: "studio").count
        XCTAssertLessThanOrEqual(before, StateCache.messagesKept + AppStore.pinnedTrimSlack)
        store.trimPinnedTranscript("studio") { true }
        await settle()
        XCTAssertEqual(store.messages(in: "studio").count, before)
    }

    func testAChatASecondTranscriptShowsKeepsEveryRow() async {
        let store = await loadedStore(rows: 140)
        let before = store.messages(in: "studio").count
        store.transcriptAppeared("studio")
        store.transcriptAppeared("studio")
        store.trimPinnedTranscript("studio") { true }
        await settle()
        XCTAssertEqual(store.messages(in: "studio").count, before)
    }

    /// A side panel can show a chat that is not selected: live traffic
    /// used to trim it under the reader.
    func testLiveTrafficLeavesAVisibleUnselectedChatWhole() async {
        let store = await loadedStore(rows: 140)
        store.transcriptAppeared("studio")
        store.openConversation("bo-dm")
        await settle()
        let before = store.messages(in: "studio").count
        store.handle(.message(Message(
            id: "zz-9999", conversationId: "studio", senderPersonId: "bo",
            senderName: "bo", content: "one more", createdAt: "2026-10-29T12:00:00Z"
        )))
        await settle()
        XCTAssertEqual(store.messages(in: "studio").count, before + 1)
        store.transcriptDisappeared("studio")
        store.handle(.message(Message(
            id: "zz-9998", conversationId: "studio", senderPersonId: "bo",
            senderName: "bo", content: "and another", createdAt: "2026-10-29T12:00:00Z"
        )))
        XCTAssertEqual(confirmed(store).count, StateCache.messagesKept, "off screen, it is trimmed again")
    }

    /// On the phone the transcript can leave the screen after `destination`'s
    /// trim ran and skipped it; its leaving trims it instead.
    func testAChatIsTrimmedATurnAfterItsLastTranscriptLeaves() async {
        let store = await loadedStore(rows: 140)
        store.transcriptAppeared("studio")
        store.openConversation("bo-dm")
        await settle()
        XCTAssertGreaterThan(confirmed(store).count, StateCache.messagesKept, "still on screen")
        store.transcriptDisappeared("studio")
        await settle()
        XCTAssertEqual(confirmed(store).count, StateCache.messagesKept)
    }

    /// The window closing while an older page loads trims the chat under the
    /// request, so the page is dropped. The fixture answers with nothing,
    /// which used to end the trimmed chat's history; a real page landed
    /// above a gap.
    func testAnOlderPageThatLandsAfterATrimIsDropped() async {
        let store = await loadedStore(rows: 140)
        store.trimClosedWindowHistory()
        XCTAssertFalse(store.exhaustedHistory.contains("studio"))
        for index in 0..<100 {
            store.handle(.message(Message(
                id: String(format: "zz-1%03d", index), conversationId: "studio",
                senderPersonId: "bo", senderName: "bo", content: "later \(index)",
                createdAt: "2026-10-29T12:00:00Z"
            )))
        }
        HQFixtureProtocol.contentMode = "ready"
        let load = Task { await store.loadOlder(in: "studio") }
        await Task.yield()
        XCTAssertTrue(store.isLoadingOlder, "the page is in flight")
        store.trimClosedWindowHistory()
        await load.value
        XCTAssertFalse(store.exhaustedHistory.contains("studio"), "the history above the window is still there")
        XCTAssertEqual(confirmed(store).count, StateCache.messagesKept)
    }

    func testClosingTheMainWindowTrimsTheSelectedChat() async {
        let store = await loadedStore(rows: 140)
        let outgoing = pending(store)
        store.trimClosedWindowHistory()
        XCTAssertEqual(confirmed(store).count, StateCache.messagesKept)
        XCTAssertEqual(pending(store), outgoing)
    }
}

import XCTest
@testable import HQ

@MainActor
final class DesktopRecoveryTests: XCTestCase {
    private var previousScenario: String?

    override func setUp() async throws {
        previousScenario = ProcessInfo.processInfo.environment["HQ_UI_SCENARIO"]
        setenv("HQ_UI_SCENARIO", "history", 1)
        HQFixtureProtocol.contentMode = "ready"
    }

    override func tearDown() async throws {
        if let previousScenario { setenv("HQ_UI_SCENARIO", previousScenario, 1) }
        else { unsetenv("HQ_UI_SCENARIO") }
        HQFixtureProtocol.contentMode = "ready"
    }

    private func fixtureStore() -> AppStore {
        precondition(HQSimulatorFixture.isEnabled)
        let store = AppStore()
        store.start()
        return store
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the offline request")
    }

    func testFailedSendRetainsPayloadAndRetryPreservesNewDraft() async {
        let store = fixtureStore()
        store.showFixtureScenario("composer")
        let original = store.textDrafts["studio"]!
        HQFixtureProtocol.contentMode = "error"
        store.send(original, in: "studio")
        store.textDrafts["studio"] = "A newer draft"
        await waitUntil { !store.failedOutgoingMessages.isEmpty }
        guard let failed = store.failedOutgoingMessages.values.first else { return }
        XCTAssertEqual(failed.content, original)
        XCTAssertEqual(failed.attachments.map(\.id), ["composer-file"])
        XCTAssertEqual(failed.replyTo?.id, "m1")
        XCTAssertTrue(store.messagesByConversation["studio"]!.contains { $0.id == failed.id })
        HQFixtureProtocol.contentMode = "ready"
        store.retrySend(failed)
        store.retrySend(failed)
        await waitUntil { store.messagesByConversation["studio"]!.contains { $0.id.hasPrefix("sent-") } }
        let sent = store.messagesByConversation["studio"]!.filter { $0.id.hasPrefix("sent-") }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.id, "sent-" + failed.id.dropFirst("pending-".count))
        XCTAssertEqual(sent.first?.attachments.map(\.id), ["composer-file"])
        XCTAssertEqual(store.textDrafts["studio"], "A newer draft")
        XCTAssertTrue(store.failedOutgoingMessages.isEmpty)
        XCTAssertFalse(store.messagesByConversation["studio"]!.contains { $0.id == failed.id })
    }

    func testFailedHistoryRequestDoesNotExhaustHistory() async {
        let store = fixtureStore()
        HQFixtureProtocol.contentMode = "error"
        await store.loadOlder(in: "studio")
        XCTAssertFalse(store.exhaustedHistory.contains("studio"))
        XCTAssertNotNil(store.historyLoadErrors["studio"])
        HQFixtureProtocol.contentMode = "ready"
        await store.loadOlder(in: "studio")
        XCTAssertTrue(store.exhaustedHistory.contains("studio"))
        XCTAssertNil(store.historyLoadErrors["studio"])
    }

    func testSyncPreservesTheOrderOfMultipleUnsentMessages() {
        func message(_ id: String) -> Message {
            Message(id: id, conversationId: "studio", senderPersonId: "ada", senderName: "Ada",
                    content: id, createdAt: "2026-09-14T02:00:00Z")
        }
        let first = message("pending-z")
        let second = message("pending-a")
        let merged = AppStore.mergingMessages([message("002")], into: [message("001"), first, second])
        XCTAssertEqual(merged.map(\.id), ["001", "002", "pending-z", "pending-a"])
        let repeated = AppStore.mergingMessages([message("003"), second], into: merged)
        XCTAssertEqual(repeated.map(\.id), ["001", "002", "003", "pending-z", "pending-a"])
    }

    func testKeyboardNavigationIncludesEmptyPinsInDisplayedOrder() {
        let store = fixtureStore()
        store.openConversation("bo-dm")
        store.selectAdjacentConversation(1, pinnedIDs: ["bo-dm", "scout-dm"])
        XCTAssertEqual(store.selectedConversationId, "scout-dm")
        store.selectAdjacentConversation(-1, pinnedIDs: ["bo-dm", "scout-dm"])
        XCTAssertEqual(store.selectedConversationId, "bo-dm")
        store.selectAdjacentConversation(-1, pinnedIDs: ["bo-dm", "scout-dm"])
        XCTAssertEqual(store.selectedConversationId, "bo-dm")
    }
}

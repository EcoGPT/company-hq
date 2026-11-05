import XCTest
@testable import HQ

/// My own message's live echo replaces its pending bubble: the hub broadcasts the stored message to the sender's sockets
/// before it answers the POST, so the message used to show twice for a
/// round trip. Hosted, on the chat fixture; the assertions run before the
/// fixture's POST reply lands.
@MainActor
final class OwnEchoTests: XCTestCase {
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

    private func fixtureStore() -> AppStore {
        precondition(HQSimulatorFixture.isEnabled)
        let store = AppStore()
        store.start()
        return store
    }

    private func echo(_ id: String, _ content: String, from sender: String, via: String? = nil) -> Message {
        Message(
            id: id, conversationId: "studio", senderPersonId: sender, senderName: sender,
            content: content, createdAt: "2026-10-15T12:00:00Z", via: via
        )
    }

    func testMyEchoReplacesItsPendingRow() throws {
        let store = fixtureStore()
        let meId = try XCTUnwrap(store.me?.id)
        store.send("echo test", in: "studio")
        store.handle(.message(echo("zz-echo", "echo test", from: meId)))
        let rows = store.messages(in: "studio").filter { $0.content == "echo test" }
        XCTAssertEqual(rows.map(\.id), ["zz-echo"])
    }

    func testOneEchoReplacesOnlyTheOldestOfTwoIdenticalSends() throws {
        let store = fixtureStore()
        let meId = try XCTUnwrap(store.me?.id)
        store.send("ok", in: "studio")
        store.send("ok", in: "studio")
        let pending = store.messages(in: "studio").filter { $0.isPending && $0.content == "ok" }.map(\.id)
        XCTAssertEqual(pending.count, 2)
        store.handle(.message(echo("zz-ok", "ok", from: meId)))
        let rows = store.messages(in: "studio").filter { $0.content == "ok" && ($0.isPending || $0.id == "zz-ok") }
        XCTAssertEqual(rows.map(\.id), ["zz-ok", pending[1]])
    }

    func testATeammatesIdenticalMessageLeavesMyPendingRow() {
        let store = fixtureStore()
        store.send("same words", in: "studio")
        store.handle(.message(echo("zz-bo", "same words", from: "bo")))
        let rows = store.messages(in: "studio").filter { $0.content == "same words" }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.filter(\.isPending).count, 1)
    }

    // MARK: - Another send of mine with the same words (round 3)

    func testAClaudePostAsMeLeavesMyPendingRow() throws {
        // One of my Claude sessions posts the same words as me through MCP:
        // that is not this device's send.
        let store = fixtureStore()
        let meId = try XCTUnwrap(store.me?.id)
        store.send("same as claude", in: "studio")
        store.handle(.message(echo("zz-mcp", "same as claude", from: meId, via: "mcp")))
        let rows = store.messages(in: "studio").filter { $0.content == "same as claude" }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.filter(\.isPending).count, 1)
    }

    func testARefusedSendIsMarkedNotSentEvenAfterAnEchoMatchedIt() async throws {
        // My phone sends "ok" while this device's "ok" is in flight; this
        // device's POST then fails without reaching the hub.
        let store = fixtureStore()
        let meId = try XCTUnwrap(store.me?.id)
        HQFixtureProtocol.contentMode = "error"
        store.send("lost ok", in: "studio")
        let pendingId = try XCTUnwrap(store.messages(in: "studio").last { $0.isPending && $0.content == "lost ok" }?.id)
        store.handle(.message(echo("zz-phone", "lost ok", from: meId)))
        let deadline = Date().addingTimeInterval(2)
        while store.failedOutgoingMessages[pendingId] == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(store.failedOutgoingMessages[pendingId])
        let rows = store.messages(in: "studio").filter { $0.content == "lost ok" }.map(\.id)
        XCTAssertEqual(rows, ["zz-phone", pendingId])
    }

    func testOnlyALostReplyOrAHubFailureCountsAsMaybeStored() {
        XCTAssertTrue(AppStore.isSendPossiblyStored(after: URLError(.timedOut)))
        XCTAssertTrue(AppStore.isSendPossiblyStored(after: URLError(.networkConnectionLost)))
        XCTAssertFalse(AppStore.isSendPossiblyStored(after: URLError(.notConnectedToInternet)))
        XCTAssertFalse(AppStore.isSendPossiblyStored(after: URLError(.cannotConnectToHost)))
        XCTAssertFalse(AppStore.isSendPossiblyStored(after: APIError(status: 403, code: "forbidden")))
        // The hub broadcasts the echo before it answers the POST, so an echo
        // then a 5xx most likely means this send was stored.
        XCTAssertTrue(AppStore.isSendPossiblyStored(after: APIError(status: 500, code: "internal")))
        XCTAssertTrue(AppStore.isSendPossiblyStored(after: APIError(status: 503, code: "unavailable")))
    }
}

import XCTest
@testable import HQ

/// What a reconnect catches up: the `sync` goes out the
/// moment the socket opens, carrying the cursor from before any live frame,
/// so the messages missed while it was down are replayed. Hosted, on the
/// chat fixture like `StoreSyncPersistenceTests`; the fixture has no socket,
/// so the tests hand the store their own `send`.
@MainActor
final class ReconnectCatchUpTests: XCTestCase {
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

    private func message(_ id: String, in conversationId: String, from sender: String = "bo") -> Message {
        Message(
            id: id, conversationId: conversationId, senderPersonId: sender, senderName: sender,
            content: "hello \(id)", createdAt: "2026-10-14T12:00:00Z"
        )
    }

    // MARK: - The connect sync

    func testTheConnectSyncCarriesTheCursorFromBeforeAnyLiveFrame() {
        let store = fixtureStore()
        store.handle(.syncBatch([message("zz-100", in: "studio")]))
        var sent: [[String: Any]] = []
        store.socketDidConnect(isLive: true) { sent.append($0) }
        // A live frame the hub broadcasts right after `hello`, before the
        // refresh's round trips come back: it must not move the cursor the
        // catch-up already asked from.
        store.handle(.message(message("zz-200", in: "studio")))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["type"] as? String, "sync")
        XCTAssertEqual(sent.first?["since_message_id"] as? String, "zz-100")
    }

    func testANotLiveConnectSendsNothing() {
        let store = fixtureStore()
        store.handle(.syncBatch([message("zz-100", in: "studio")]))
        var sent: [[String: Any]] = []
        store.socketDidConnect(isLive: false) { sent.append($0) }
        XCTAssertTrue(sent.isEmpty)
    }

    func testNoCursorSendsNothingAtConnect() {
        // The fixture seeds no cursor: the refresh's own sync seeds it.
        let store = fixtureStore()
        var sent: [[String: Any]] = []
        store.socketDidConnect(isLive: true) { sent.append($0) }
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - The open chat's re-read

    func testAReconnectRereadsTheOpenChatsNewestPage() async throws {
        let store = fixtureStore()
        // Selected without `openConversation`, whose own read would race the
        // one under test.
        store.selectedConversationId = "studio"
        guard let original = store.messages(in: "studio").last else { return XCTFail("no fixture rows") }
        // An update this device holds and the hub does not (the reverse of a
        // `message_updated` missed while down): same timestamps, so the hub's
        // copy wins the merge when the page is read again.
        store.handle(.messageUpdated(Message(
            id: original.id, conversationId: original.conversationId,
            senderPersonId: original.senderPersonId, senderName: original.senderName,
            content: "stale while the socket was down", createdAt: original.createdAt,
            editedAt: original.editedAt, deletedAt: original.deletedAt,
            replyTo: original.replyTo, reactions: original.reactions, attachments: original.attachments,
            kind: original.kind
        )))
        XCTAssertEqual(store.messages(in: "studio").last?.content, "stale while the socket was down")
        store.socketDidConnect(isLive: true) { _ in }
        let deadline = Date().addingTimeInterval(2)
        while store.messages(in: "studio").last?.content != original.content, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.messages(in: "studio").last?.content, original.content)
    }

    // MARK: - The refresh retry

    func testAFailedRefreshIsRetriedTwiceThenLeftToTheNextReconnect() {
        XCTAssertEqual((1...3).map { AppStore.refreshRetryDelay(afterFailures: $0) }, [5, 30, nil])
    }

    func testARetryAfterALaterSuccessDoesNothing() async throws {
        // A hub deploy: this refresh fails and schedules its retry, then the
        // reconnect's refresh succeeds before the retry's wait is over. The
        // retry must not repeat the whole refresh on every device at once.
        let store = fixtureStore()
        let deviceId = try XCTUnwrap(store.session?.deviceId)
        await store.refresh()
        HQFixtureProtocol.contentMode = "error"
        await store.refresh()
        HQFixtureProtocol.contentMode = "ready"
        await store.refresh()
        let ran = await store.didRunRefreshRetry(deviceId: deviceId)
        XCTAssertFalse(ran)
    }

    func testARetryWithNoLaterSuccessRefreshes() async throws {
        let store = fixtureStore()
        let deviceId = try XCTUnwrap(store.session?.deviceId)
        await store.refresh()
        HQFixtureProtocol.contentMode = "error"
        await store.refresh()
        HQFixtureProtocol.contentMode = "ready"
        let ran = await store.didRunRefreshRetry(deviceId: deviceId)
        XCTAssertTrue(ran)
    }

    func testAPushRefreshDoesNotCancelAFailedFullRefreshsRetry() async throws {
        // A push refresh never starts the tail loads, so the badge reads the
        // failed full refresh skipped are still owed to its retry.
        let store = fixtureStore()
        let deviceId = try XCTUnwrap(store.session?.deviceId)
        await store.refresh()
        HQFixtureProtocol.contentMode = "error"
        await store.refresh()
        HQFixtureProtocol.contentMode = "ready"
        await store.refresh(scope: .push)
        let ran = await store.didRunRefreshRetry(deviceId: deviceId)
        XCTAssertTrue(ran)
    }

    // MARK: - The reconnect's tail loads

    func testATasksFrameCountsAsAFreshReadOfTheBoard() {
        let store = fixtureStore()
        let before = store.tailLoadedAt[.tasks]
        store.handle(.tasks(store.tasks))
        guard let after = store.tailLoadedAt[.tasks] else { return XCTFail("the frame did not mark the board loaded") }
        if let before { XCTAssertGreaterThan(after, before) }
    }

    func testATailLoadAlreadyWaitingIsNotStartedAgain() {
        // A connect refresh then a pull-to-refresh, or a socket flapping
        // every second or two: the first pass's loads are still inside their
        // spread when the next pass looks, and the board alone is ~0.9 MB.
        let store = fixtureStore()
        let first = store.startStaleTailLoads()
        let second = store.startStaleTailLoads()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(second, [])
    }

    func testSigningOutFreesTheTailsStillWaiting() {
        // A tail still waiting for the old session must not hold its slot:
        // the next session's first full refresh would skip it. Through the
        // reset signOut runs, not signOut itself, which also clears the
        // widget shelf in the App Group the installed app shares.
        let store = fixtureStore()
        let first = store.startStaleTailLoads()
        store.forgetRefreshState()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(store.startStaleTailLoads(), first)
    }

    func testTheTailLoadsAreSpreadOverEightSeconds() {
        XCTAssertEqual(AppStore.tailStartDelay(random: 0), 0)
        XCTAssertEqual(AppStore.tailStartDelay(random: 0.5), 4)
        XCTAssertEqual(AppStore.tailStartDelay(random: 1), 8)
    }
}

import Observation
import XCTest
@testable import HQ

/// The store's network, sync and persistence paths:
/// a sync batch is one merge and one bump per conversation, a read is posted
/// once, a save waits for quiet, an unchanged cache is not rewritten, and a
/// second `refresh()` or `loadMessages` joins the one in flight. The pure
/// rules are tested directly; the hosted ones drive the store through its own
/// frame handler, like `StoreObservationTests`.
@MainActor
final class StoreSyncPersistenceTests: XCTestCase {
    private var previousScenario: String?

    override func setUp() async throws {
        previousScenario = ProcessInfo.processInfo.environment["HQ_UI_SCENARIO"]
        setenv("HQ_UI_SCENARIO", "chat", 1)
        HQFixtureProtocol.contentMode = "ready"
    }

    override func tearDown() async throws {
        if let previousScenario { setenv("HQ_UI_SCENARIO", previousScenario, 1) }
        else { unsetenv("HQ_UI_SCENARIO") }
    }

    private func fixtureStore() -> AppStore {
        precondition(HQSimulatorFixture.isEnabled)
        let store = AppStore()
        store.start()
        return store
    }

    func testSigningOutAfterFixtureScopeEndsDoesNotEnterPersistentWebKitCleanup() async throws {
        let store = fixtureStore()
        unsetenv("HQ_UI_SCENARIO")
        defer { setenv("HQ_UI_SCENARIO", "chat", 1) }
        store.signOut()
        XCTAssertNil(store.session)
        // The old cleanup dispatched WebKit's persistent-store enumeration
        // asynchronously, crashing the host after the next test had started.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(store.session)
    }

    private func message(
        _ id: String, in conversationId: String, from sender: String = "bo",
        kind: String? = nil
    ) -> Message {
        Message(
            id: id, conversationId: conversationId, senderPersonId: sender, senderName: sender,
            content: "hello \(id)", createdAt: "2026-10-14T12:00:00Z",
            kind: kind
        )
    }

    // MARK: - Batch grouping

    func testABatchIsGroupedByConversationKeepingArrivalOrder() {
        let batch = [
            message("m1", in: "a"), message("m2", in: "b"), message("m3", in: "a"),
            message("m4", in: "c"), message("m5", in: "b"),
        ]
        let groups = AppStore.groupedByConversation(batch)
        // Ordered by where each conversation's newest message sits, so bumping
        // them in turn leaves the conversation of the last message on top.
        XCTAssertEqual(groups.map(\.conversationId), ["a", "c", "b"])
        XCTAssertEqual(groups[0].messages.map(\.id), ["m1", "m3"])
        XCTAssertEqual(groups[1].messages.map(\.id), ["m4"])
        XCTAssertEqual(groups[2].messages.map(\.id), ["m2", "m5"])
    }

    func testAnEmptyBatchHasNoGroups() {
        XCTAssertTrue(AppStore.groupedByConversation([]).isEmpty)
    }

    // MARK: - Unread

    func testReplayedMessagesAtOrBelowTheRefreshedLastMessageAddNoUnread() {
        // The hub's count already included m1...m6 (the refreshed row's last
        // message is m6); only m7 is new to this device.
        let batch = ["m5", "m6", "m7"].map { message($0, in: "a") }
        let unread = AppStore.unreadAfter(
            existing: 3, messages: batch, meId: "me", isBeingRead: false,
            arrival: .replay(lastKnownId: "m6")
        )
        XCTAssertEqual(unread, 4)
    }

    func testLiveMessagesAlwaysCount() {
        let batch = ["m5", "m6"].map { message($0, in: "a") }
        let unread = AppStore.unreadAfter(
            existing: 0, messages: batch, meId: "me", isBeingRead: false,
            arrival: .live
        )
        XCTAssertEqual(unread, 2)
    }

    func testMyOwnMessageClearsTheCountAndLaterOnesStartItAgain() {
        let batch = [
            message("m1", in: "a"), message("m2", in: "a", from: "me"), message("m3", in: "a"),
        ]
        let unread = AppStore.unreadAfter(
            existing: 4, messages: batch, meId: "me", isBeingRead: false,
            arrival: .live
        )
        XCTAssertEqual(unread, 1)
    }

    func testAThreadBeingReadStaysAtZero() {
        let unread = AppStore.unreadAfter(
            existing: 2, messages: [message("m1", in: "a")], meId: "me", isBeingRead: true,
            arrival: .live
        )
        XCTAssertEqual(unread, 0)
    }

    func testGroupEventsAddNothing() {
        let batch = [
            message("m1", in: "a", kind: "member_added"),
        ]
        let unread = AppStore.unreadAfter(
            existing: 1, messages: batch, meId: "me", isBeingRead: false,
            arrival: .live
        )
        XCTAssertEqual(unread, 1)
    }

    func testASyncBatchBumpsEachConversationOnceWithTheNewestMessage() {
        let store = fixtureStore()
        let updatesBefore = store.conversation("updates")?.unreadCount ?? 0
        let dmBefore = store.conversation("bo-dm")?.unreadCount ?? 0
        store.handle(.syncBatch([
            message("zz-1", in: "updates"), message("zz-2", in: "bo-dm"),
            message("zz-3", in: "updates"), message("zz-4", in: "bo-dm"),
            message("zz-5", in: "updates"),
        ]))
        XCTAssertEqual(store.conversation("updates")?.lastMessage?.id, "zz-5")
        XCTAssertEqual(store.conversation("bo-dm")?.lastMessage?.id, "zz-4")
        XCTAssertEqual(store.conversation("updates")?.unreadCount, updatesBefore + 3)
        XCTAssertEqual(store.conversation("bo-dm")?.unreadCount, dmBefore + 2)
        // updates holds the batch's newest message, so it ends on top.
        XCTAssertEqual(store.conversations.first?.id, "updates")
        XCTAssertEqual(store.conversations.dropFirst().first?.id, "bo-dm")
        XCTAssertEqual(store.messages(in: "updates").suffix(3).map(\.id), ["zz-1", "zz-3", "zz-5"])
    }

    func testASyncBatchOfTwentyReachesTheChatItLandsIn() {
        let store = fixtureStore()
        let flag = Flag()
        _ = withObservationTracking { store.messages(in: "studio") } onChange: { flag.fired += 1 }
        store.handle(.syncBatch((0..<20).map { message("zy-\($0 + 10)", in: "studio") }))
        XCTAssertEqual(flag.fired, 1)
        XCTAssertEqual(store.messages(in: "studio").filter { $0.id.hasPrefix("zy-") }.count, 20)
    }

    func testReplayBelowTheRefreshedLastMessageNeitherCountsNorMovesTheRow() {
        let store = fixtureStore()
        store.handle(.syncBatch([message("m-seed", in: "bo-dm"), message("m-seed2", in: "bo-dm")]))
        guard let last = store.conversation("bo-dm")?.lastMessage else { return XCTFail("no last message") }
        let before = store.conversation("bo-dm")?.unreadCount ?? 0
        let orderBefore = store.conversations.map(\.id)
        // "!" sorts before every id: an old message the refresh already counted.
        store.handle(.syncBatch([message("!old", in: "bo-dm")]))
        XCTAssertEqual(store.conversation("bo-dm")?.unreadCount, before)
        XCTAssertEqual(store.conversation("bo-dm")?.lastMessage?.id, last.id)
        XCTAssertEqual(store.conversations.map(\.id), orderBefore)
    }

    // MARK: - Read posts

    func testAReadIsPostedOnceAndRepeatsAreSkipped() {
        XCTAssertTrue(AppStore.shouldPostRead(latestId: "m5", alreadyPosted: nil, unreadCount: 0))
        XCTAssertFalse(AppStore.shouldPostRead(latestId: "m5", alreadyPosted: "m5", unreadCount: 0))
        XCTAssertFalse(AppStore.shouldPostRead(latestId: "m5", alreadyPosted: "m9", unreadCount: 0))
    }

    func testANewerMessageIsPosted() {
        XCTAssertTrue(AppStore.shouldPostRead(latestId: "m6", alreadyPosted: "m5", unreadCount: 0))
    }

    func testAChatMarkedUnreadStillPosts() {
        XCTAssertTrue(AppStore.shouldPostRead(latestId: "m5", alreadyPosted: "m5", unreadCount: 2))
    }

    // MARK: - Save cadence

    func testASaveWaitsForTheDebounceWhenChangesJustStarted() {
        let now = Date()
        XCTAssertEqual(SaveSchedule.delay(firstRequestedAt: now, now: now), SaveSchedule.debounce)
        XCTAssertEqual(SaveSchedule.debounce, 5)
        XCTAssertEqual(SaveSchedule.maxWait, 30)
    }

    func testASteadyStreamStillSavesWithinTheMaxWait() {
        let first = Date()
        // 28 s after the first unsaved change, only 2 s of the 30 s cap remain.
        let delay = SaveSchedule.delay(firstRequestedAt: first, now: first.addingTimeInterval(28))
        XCTAssertEqual(delay, 2, accuracy: 0.001)
        // Past the cap it writes now.
        XCTAssertEqual(
            SaveSchedule.delay(firstRequestedAt: first, now: first.addingTimeInterval(45)), 0
        )
    }

    private func snapshot(lastSeen: String?) -> StateSnapshot {
        StateSnapshot(
            schemaVersion: StateCache.schemaVersion, people: [:], conversations: [],
            messagesByConversation: [:], lastSeenMessageId: lastSeen
        )
    }

    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hq-state-cache-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state-cache.json")
    }

    func testAnUnchangedSnapshotIsNotWrittenAgain() throws {
        let url = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = StateCacheWriter(url: url)
        XCTAssertEqual(writer.save(snapshot(lastSeen: "m1"), sequence: 1), .wrote)
        let written = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        // Identical content: nothing is written, so the removed file stays removed.
        XCTAssertEqual(writer.save(snapshot(lastSeen: "m1"), sequence: 2), .unchanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(writer.save(snapshot(lastSeen: "m2"), sequence: 3), .wrote)
        XCTAssertNotEqual(try Data(contentsOf: url), written)
    }

    /// The Agents list's cached wire body is dropped when it no longer reads, never the chats.
    func testAnAgentsEntryThatNoLongerReadsKeepsTheRestOfTheCache() throws {
        let json = #"""
            {"schemaVersion":2,"people":{},"conversations":[],"messagesByConversation":{},"lastSeenMessageId":"m9",
             "agentSessions":[{"session_id":1}]}
            """#
        let decoded = try JSONDecoder().decode(StateSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.lastSeenMessageId, "m9")
        XCTAssertNil(decoded.agentSessions)
    }

    func testAnOlderSnapshotNeverOverwritesANewerOne() throws {
        let url = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = StateCacheWriter(url: url)
        XCTAssertEqual(writer.save(snapshot(lastSeen: "new"), sequence: 5), .wrote)
        XCTAssertEqual(writer.save(snapshot(lastSeen: "old"), sequence: 4), .stale)
        let decoded = try JSONDecoder().decode(StateSnapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.lastSeenMessageId, "new")
    }

    func testClearingTheCacheLetsTheSameSnapshotBeWrittenAgain() throws {
        let url = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = StateCacheWriter(url: url)
        XCTAssertEqual(writer.save(snapshot(lastSeen: "m1"), sequence: 1), .wrote)
        writer.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(writer.save(snapshot(lastSeen: "m1"), sequence: 1), .wrote)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Single flight

    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private final class Flag: @unchecked Sendable {
        var fired = 0
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testASecondLoadOfTheSameChatJoinsTheFirst() async {
        let flight = SingleFlight<String>()
        let gate = Gate()
        var runs: [String] = []
        let first = Task { @MainActor in
            await flight.run("studio") { runs.append("studio"); await gate.wait() }
        }
        await settle()
        let second = Task { @MainActor in
            await flight.run("studio") { runs.append("studio") }
        }
        let other = Task { @MainActor in
            await flight.run("updates") { runs.append("updates") }
        }
        await settle()
        XCTAssertEqual(runs.sorted(), ["studio", "updates"], "the second studio load started its own request")
        gate.open()
        await first.value
        await second.value
        await other.value
        XCTAssertFalse(flight.isRunning("studio"))
        // Once the first has finished, a later load is a new request.
        await flight.run("studio") { runs.append("studio") }
        XCTAssertEqual(runs.filter { $0 == "studio" }.count, 2)
    }

    func testARefreshInFlightQueuesAtMostOneMoreAtTheWidestScope() async {
        var performed: [AppStore.RefreshScope] = []
        let gate = Gate()
        let runner = CoalescedRunner<AppStore.RefreshScope>(
            combine: { AppStore.RefreshScope.wider($0, $1) },
            perform: { scope in
                performed.append(scope)
                if performed.count == 1 { await gate.wait() }
            }
        )
        let first = Task { @MainActor in await runner.run(.push) }
        await settle()
        let second = Task { @MainActor in await runner.run(.push) }
        let third = Task { @MainActor in await runner.run(.full) }
        let fourth = Task { @MainActor in await runner.run(.push) }
        await settle()
        XCTAssertEqual(performed, [.push], "a second refresh ran beside the first")
        gate.open()
        await first.value
        await second.value
        await third.value
        await fourth.value
        XCTAssertEqual(performed, [.push, .full], "three queued requests became more than one rerun")
        XCTAssertFalse(runner.isRunning)
    }

    func testAFinishedRefreshLetsTheNextOneRun() async {
        var count = 0
        let runner = CoalescedRunner<AppStore.RefreshScope>(
            combine: { AppStore.RefreshScope.wider($0, $1) },
            perform: { _ in count += 1 }
        )
        await runner.run(.full)
        await runner.run(.full)
        XCTAssertEqual(count, 2)
    }

    // MARK: - Tail loads

    func testTailLoadsRunOnlyWhenTheirLastSuccessIsOld() {
        let now = Date()
        XCTAssertTrue(AppStore.isTailStale(lastLoadedAt: nil, now: now))
        XCTAssertFalse(AppStore.isTailStale(lastLoadedAt: now.addingTimeInterval(-30), now: now))
        XCTAssertTrue(AppStore.isTailStale(lastLoadedAt: now.addingTimeInterval(-61), now: now))
    }

    // MARK: - Read marks

    func testATeammatesReceiptDoesNotRewriteTheConversationList() {
        let store = fixtureStore()
        let flag = Flag()
        _ = withObservationTracking { store.conversations } onChange: { flag.fired += 1 }
        store.handle(.read(conversationId: "studio", personId: "bo", lastReadMessageId: "zz-9"))
        XCTAssertEqual(flag.fired, 0, "a read receipt woke the readers of the whole list")
        XCTAssertTrue(store.readMarks(in: "studio").contains {
            $0.personId == "bo" && $0.lastReadMessageId == "zz-9"
        })
    }

    func testAReceiptWakesOnlyThatChatsReadMarks() {
        let store = fixtureStore()
        let other = Flag()
        _ = withObservationTracking { store.readMarks(in: "bo-dm") } onChange: { other.fired += 1 }
        let same = Flag()
        _ = withObservationTracking { store.readMarks(in: "studio") } onChange: { same.fired += 1 }
        store.handle(.read(conversationId: "studio", personId: "bo", lastReadMessageId: "zz-8"))
        XCTAssertEqual(other.fired, 0)
        XCTAssertEqual(same.fired, 1)
        // The echo of the same mark is a no-op.
        let again = Flag()
        _ = withObservationTracking { store.readMarks(in: "studio") } onChange: { again.fired += 1 }
        store.handle(.read(conversationId: "studio", personId: "bo", lastReadMessageId: "zz-8"))
        XCTAssertEqual(again.fired, 0)
    }

    func testTheReadLineReadsTheLiveMark() {
        let store = fixtureStore()
        guard let mine = store.messages(in: "studio").last else { return XCTFail("no message") }
        store.handle(.read(conversationId: "studio", personId: "bo", lastReadMessageId: mine.id))
        XCTAssertTrue(store.readers(of: mine).contains { $0.id == "bo" })
    }

    private func restated(
        _ row: Conversation, unreadCount: Int, marks: [ReadMark]
    ) -> Conversation {
        Conversation(
            id: row.id, kind: row.kind, title: row.title, memberIds: row.memberIds, createdAt: row.createdAt,
            lastMessage: row.lastMessage, unreadCount: unreadCount, readMarks: marks,
            roomSlug: row.roomSlug, avatarId: row.avatarId
        )
    }

    func testAHubRestatementMovesAMarkBackEvenWhenAnotherFieldChangedWithIt() {
        let store = fixtureStore()
        guard let row = store.conversation("studio") else { return XCTFail("no studio row") }
        let five = [ReadMark(personId: "bo", lastReadMessageId: "zz-5")]
        // The array's copy and the slot both say bo read zz-5.
        store.handle(.conversationUpdated(restated(row, unreadCount: row.unreadCount + 1, marks: five)))
        // A receipt moves the slot past the array's copy.
        store.handle(.read(conversationId: "studio", personId: "bo", lastReadMessageId: "zz-9"))
        XCTAssertEqual(store.readMarks(in: "studio").first { $0.personId == "bo" }?.lastReadMessageId, "zz-9")
        // Bo marks the chat unread; the hub restates the mark back at zz-5 in a write that also changes the
        // unread count. The old rule saw "array marks == restated marks" and kept zz-9.
        store.handle(.conversationUpdated(restated(row, unreadCount: row.unreadCount + 2, marks: five)))
        XCTAssertEqual(store.readMarks(in: "studio").first { $0.personId == "bo" }?.lastReadMessageId, "zz-5")
        XCTAssertEqual(store.conversation("studio")?.unreadCount, row.unreadCount + 2)
    }

    func testAMarksOnlyRestatementStillLandsInTheSlotAndLeavesTheListAlone() {
        let store = fixtureStore()
        guard let row = store.conversation("studio") else { return XCTFail("no studio row") }
        let flag = Flag()
        _ = withObservationTracking { store.conversations } onChange: { flag.fired += 1 }
        let marks = [ReadMark(personId: "bo", lastReadMessageId: "zz-7")]
        store.handle(.conversationUpdated(restated(row, unreadCount: row.unreadCount, marks: marks)))
        XCTAssertEqual(flag.fired, 0)
        XCTAssertEqual(store.readMarks(in: "studio"), marks)
    }

    func testALocalBumpCarriesTheLiveMarksIntoTheRow() {
        let store = fixtureStore()
        store.handle(.read(conversationId: "studio", personId: "bo", lastReadMessageId: "zz-9"))
        store.handle(.syncBatch([message("zz-20", in: "studio")]))
        XCTAssertEqual(store.conversation("studio")?.lastMessage?.id, "zz-20")
        XCTAssertTrue(store.readMarks(in: "studio").contains {
            $0.personId == "bo" && $0.lastReadMessageId == "zz-9"
        }, "the bump wrote the row's old marks over the receipt")
        XCTAssertTrue(store.conversation("studio")?.readMarks.contains {
            $0.personId == "bo" && $0.lastReadMessageId == "zz-9"
        } == true)
    }

    // MARK: - Remote push

    // MARK: - Projects reload

    func testTheProjectsWaitIsASecondAndShrinksToAFiveSecondCap() {
        XCTAssertEqual(AppStore.projectsReloadWait(sinceFirstUnservedFrame: 0), 1)
        XCTAssertEqual(AppStore.projectsReloadWait(sinceFirstUnservedFrame: 3.9), 1)
        XCTAssertEqual(AppStore.projectsReloadWait(sinceFirstUnservedFrame: 4.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AppStore.projectsReloadWait(sinceFirstUnservedFrame: 5), 0)
        XCTAssertEqual(AppStore.projectsReloadWait(sinceFirstUnservedFrame: 60), 0)
    }

    func testAStreamOfFramesIsServedWithinFiveSecondsOfTheFirst() {
        // A frame every 0.4 s for a minute: whichever frame owns the wait, it fires no later than
        // five seconds after the first unserved frame (or at once once that has passed).
        for elapsed in stride(from: 0.0, through: 60.0, by: 0.4) {
            let fires = elapsed + AppStore.projectsReloadWait(sinceFirstUnservedFrame: elapsed)
            XCTAssertLessThanOrEqual(fires, max(5.0, elapsed) + 0.0001)
        }
    }

    // MARK: - Launch cache

    func testTheLaunchCacheIsTakenSynchronouslyWhenItAlreadyLanded() {
        let box = OneShotBox<String?>()
        box.fill("cached")
        guard case .landed(let value) = box.poll() else { return XCTFail("a filled box answered pending") }
        XCTAssertEqual(value, "cached")
    }

    func testAnEmptyCacheIsStillALandedAnswer() {
        let box = OneShotBox<String?>()
        box.fill(nil)
        guard case .landed(let value) = box.poll() else { return XCTFail("nil cache answered pending") }
        XCTAssertNil(value)
    }

    func testAStillRunningDecodeIsPendingAfterTheBoundedWait() {
        let box = OneShotBox<String?>()
        let started = Date()
        guard case .pending = box.poll(waitingUpTo: AppStore.launchCacheWait) else {
            return XCTFail("an unfilled box answered landed")
        }
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, AppStore.launchCacheWait - 0.005)
        XCTAssertLessThan(waited, AppStore.launchCacheWait + 0.5)
    }

    func testADecodeThatFinishesDuringTheWaitIsTakenWithoutWaitingOutTheRest() {
        let box = OneShotBox<String?>()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { box.fill("late") }
        let started = Date()
        guard case .landed(let value) = box.poll(waitingUpTo: 2) else { return XCTFail("the fill was missed") }
        XCTAssertEqual(value, "late")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testOnlyTheFirstFillCounts() {
        let box = OneShotBox<String?>()
        box.fill("first")
        box.fill("second")
        guard case .landed(let value) = box.poll() else { return XCTFail("pending") }
        XCTAssertEqual(value, "first")
    }

    // MARK: - Planning

    func testAProjectPatchAnswerIsAppliedLocally() throws {
        let store = fixtureStore()
        guard let project = store.projects.first else { return XCTFail("no fixture project") }
        let renamed = Project(
            id: project.id, name: "Renamed in the panel", body: project.body,
            ownerPersonId: project.ownerPersonId, ownerName: project.ownerName,
            status: project.status, openTasks: project.openTasks,
            createdAt: project.createdAt, closedAt: project.closedAt
        )
        let notified = Flag()
        _ = withObservationTracking { store.projects } onChange: { notified.fired += 1 }
        store.applyPlanningProject(renamed)
        XCTAssertEqual(notified.fired, 1)
        XCTAssertEqual(store.projects.first { $0.id == project.id }?.name, "Renamed in the panel")
        // The same answer again changes nothing, so nothing re-renders.
        let again = Flag()
        _ = withObservationTracking { store.projects } onChange: { again.fired += 1 }
        store.applyPlanningProject(renamed)
        XCTAssertEqual(again.fired, 0)
    }
}

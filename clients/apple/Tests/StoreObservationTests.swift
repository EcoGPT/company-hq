import Observation
import XCTest
@testable import HQ

/// The store's per-conversation observation: a view that reads
/// one chat's messages, row or draft is woken by writes to THAT chat and by
/// nothing else. Each test installs a `withObservationTracking` reader on one
/// accessor, performs a write through the store's own entry points (a socket
/// frame, a draft keystroke) and asserts whether the reader was notified —
/// the same mechanism SwiftUI's body tracking uses.
@MainActor
final class StoreObservationTests: XCTestCase {
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

    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    /// Installs `read` as a tracked reader, runs `write`, and reports whether
    /// the reader was notified. One-shot, like a SwiftUI body: it must be
    /// re-armed for each write.
    private func isNotified<T>(by write: () -> Void, reading read: () -> T) -> Bool {
        let flag = Flag()
        _ = withObservationTracking { read() } onChange: { flag.fired = true }
        write()
        return flag.fired
    }

    private func message(
        _ id: String, in conversationId: String, content: String = "hello",
        reactions: [Reaction] = [], createdAt: String = "2026-10-14T12:00:00Z"
    ) -> Message {
        Message(
            id: id, conversationId: conversationId, senderPersonId: "bo", senderName: "Bo",
            content: content, createdAt: createdAt, reactions: reactions
        )
    }

    // MARK: - Messages

    func testMessageInAnotherChatDoesNotNotifyThisChatsReader() {
        let store = fixtureStore()
        XCTAssertFalse(store.messages(in: "studio").isEmpty)
        let quiet = isNotified(
            by: { store.handle(.syncBatch([message("z-1", in: "bo-dm")])) },
            reading: { store.messages(in: "studio") }
        )
        XCTAssertFalse(quiet, "a message in another chat woke this chat's reader")
        XCTAssertTrue(store.messages(in: "bo-dm").contains { $0.id == "z-1" })
    }

    func testMessageInThisChatNotifiesItsReader() {
        let store = fixtureStore()
        let notified = isNotified(
            by: { store.handle(.syncBatch([message("z-2", in: "studio")])) },
            reading: { store.messages(in: "studio") }
        )
        XCTAssertTrue(notified)
        XCTAssertTrue(store.messages(in: "studio").contains { $0.id == "z-2" })
    }

    func testAnAgentStepInAnotherChatDoesNotNotifyThisChat() {
        let store = fixtureStore()
        store.handle(.syncBatch([message("seed-dm", in: "bo-dm")]))
        guard let target = store.messages(in: "bo-dm").first else { return XCTFail("no fixture message") }
        let step = message(target.id, in: "bo-dm", content: target.content + "\nstep", createdAt: target.createdAt)
        let quiet = isNotified(
            by: { store.handle(.messageUpdated(step)) },
            reading: { store.messages(in: "studio") }
        )
        XCTAssertFalse(quiet)
        XCTAssertTrue(store.messages(in: "bo-dm").contains { $0.content.hasSuffix("\nstep") })
    }

    func testRewritingAnIdenticalMessageNotifiesNobody() {
        let store = fixtureStore()
        guard let same = store.messages(in: "studio").first else { return XCTFail("no fixture message") }
        let notified = isNotified(
            by: { store.handle(.messageUpdated(same)) },
            reading: { store.messages(in: "studio") }
        )
        XCTAssertFalse(notified, "an identical write must not wake the transcript")
    }

    func testMessagesMovedOutOfAChatOnlyNotifiesThatChat() {
        let store = fixtureStore()
        store.handle(.syncBatch([message("seed-dm", in: "bo-dm")]))
        guard let moved = store.messages(in: "bo-dm").first else { return XCTFail("no fixture message") }
        let quiet = isNotified(
            by: { store.handle(.messagesMoved(fromConversationId: "bo-dm", messageIds: [moved.id])) },
            reading: { store.messages(in: "studio") }
        )
        XCTAssertFalse(quiet)
        XCTAssertFalse(store.messages(in: "bo-dm").contains { $0.id == moved.id })
        // Dropping an id that is not there changes nothing, so nobody hears.
        let noop = isNotified(
            by: { store.handle(.messagesMoved(fromConversationId: "bo-dm", messageIds: ["nope"])) },
            reading: { store.messages(in: "bo-dm") }
        )
        XCTAssertFalse(noop)
    }

    func testPersistedSnapshotStillSeesEveryChat() {
        let store = fixtureStore()
        store.handle(.syncBatch([message("z-3", in: "bo-dm")]))
        // The plain read the cache and tests use is fed by the same slots.
        XCTAssertTrue(store.messagesByConversation["bo-dm"]?.contains { $0.id == "z-3" } == true)
        XCTAssertNotNil(store.messagesByConversation["studio"])
    }

    // MARK: - Conversation rows

    func testATeammatesReadReceiptInAnotherChatDoesNotNotifyThisRow() {
        let store = fixtureStore()
        XCTAssertNotNil(store.conversation("studio"))
        let quiet = isNotified(
            by: { store.handle(.read(conversationId: "bo-dm", personId: "bo", lastReadMessageId: "z-9")) },
            reading: { store.conversation("studio") }
        )
        XCTAssertFalse(quiet, "a receipt in bo-dm woke the studio row")
        XCTAssertTrue(store.readMarks(in: "bo-dm").contains { $0.personId == "bo" })
    }

    func testAReadReceiptInThisChatLeavesItsRowAloneAndNotifiesItsMarksOnce() {
        let store = fixtureStore()
        // A mark is drawn by the "Read" line alone; the row (the sidebar, the
        // phone's list, the detail panel) has no use for it.
        let rowNotified = isNotified(
            by: { store.handle(.read(conversationId: "studio", personId: "bo", lastReadMessageId: "z-9")) },
            reading: { store.conversation("studio") }
        )
        XCTAssertFalse(rowNotified)
        XCTAssertTrue(store.readMarks(in: "studio").contains { $0.lastReadMessageId == "z-9" })
        let marksNotified = isNotified(
            by: { store.handle(.read(conversationId: "studio", personId: "bo", lastReadMessageId: "z-10")) },
            reading: { store.readMarks(in: "studio") }
        )
        XCTAssertTrue(marksNotified)
        // The hub echoes the same receipt to every member; the repeat is a no-op.
        let repeated = isNotified(
            by: { store.handle(.read(conversationId: "studio", personId: "bo", lastReadMessageId: "z-10")) },
            reading: { store.readMarks(in: "studio") }
        )
        XCTAssertFalse(repeated)
    }

    func testAMessageInAnotherChatDoesNotNotifyThisRowButBumpsTheirs() {
        let store = fixtureStore()
        let quiet = isNotified(
            by: { store.handle(.syncBatch([message("z-4", in: "bo-dm")])) },
            reading: { store.conversation("studio") }
        )
        XCTAssertFalse(quiet)
        XCTAssertEqual(store.conversation("bo-dm")?.lastMessage?.id, "z-4")
        XCTAssertEqual(store.conversations.first?.id, "bo-dm", "the bump still moves the chat to the top")
    }

    func testAWorkStepThatLeavesThePreviewAloneDoesNotRewriteTheRow() {
        let store = fixtureStore()
        guard let last = store.conversation("studio")?.lastMessage else { return XCTFail("no last message") }
        // Same words, a new tapback: the row shows nothing of it.
        let reacted = Message(
            id: last.id, conversationId: last.conversationId, senderPersonId: last.senderPersonId,
            senderName: last.senderName, content: last.content, createdAt: last.createdAt,
            reactions: [Reaction(emoji: "👍", personIds: ["bo"])]
        )
        let rowNotified = isNotified(
            by: { store.handle(.messageUpdated(reacted)) },
            reading: { store.conversation("studio") }
        )
        XCTAssertFalse(rowNotified)
        XCTAssertTrue(
            store.messages(in: "studio").contains { $0.id == last.id && !$0.reactions.isEmpty },
            "the transcript itself does take the update"
        )
    }

    // MARK: - Drafts

    func testAKeystrokeDoesNotNotifyTheDraftSetUnlessTheDraftFlips() {
        let store = fixtureStore()
        XCTAssertFalse(store.draftConversationIDs.contains("studio"))
        let flipsOn = isNotified(
            by: { store.setDraftText("h", for: "studio") },
            reading: { store.draftConversationIDs }
        )
        XCTAssertTrue(flipsOn)
        XCTAssertTrue(store.draftConversationIDs.contains("studio"))

        let keystroke = isNotified(
            by: { store.setDraftText("hello", for: "studio") },
            reading: { store.draftConversationIDs }
        )
        XCTAssertFalse(keystroke, "a keystroke reached the list's draft set")

        let flipsOff = isNotified(
            by: { store.setDraftText("", for: "studio") },
            reading: { store.draftConversationIDs }
        )
        XCTAssertTrue(flipsOff)
        XCTAssertFalse(store.draftConversationIDs.contains("studio"))
    }

    func testWhitespaceAloneIsNotADraft() {
        let store = fixtureStore()
        let notified = isNotified(
            by: { store.setDraftText("  \n ", for: "studio") },
            reading: { store.draftConversationIDs }
        )
        XCTAssertFalse(notified)
        XCTAssertFalse(store.draftConversationIDs.contains("studio"))
    }

    func testADraftKeystrokeWakesOnlyThatChatsDraftReader() {
        let store = fixtureStore()
        let otherChat = isNotified(
            by: { store.setDraftText("typing", for: "studio") },
            reading: { store.draftText(for: "bo-dm") }
        )
        XCTAssertFalse(otherChat)
        let sameChat = isNotified(
            by: { store.setDraftText("typing more", for: "studio") },
            reading: { store.draftText(for: "studio") }
        )
        XCTAssertTrue(sameChat)
        XCTAssertEqual(store.textDrafts["studio"], "typing more")
    }

    func testAttachmentDraftsFlipMembershipToo() {
        let store = fixtureStore()
        // The composer fixture stages one file on design.
        store.showFixtureScenario("composer")
        XCTAssertTrue(store.draftConversationIDs.contains("studio"))
        guard let file = store.drafts(in: "studio").first else { return XCTFail("no staged file") }
        store.setDraftText("", for: "studio")
        XCTAssertTrue(store.draftConversationIDs.contains("studio"), "an attachment alone is a draft")
        store.removeDraft(file, in: "studio")
        XCTAssertFalse(store.draftConversationIDs.contains("studio"))
    }

    // MARK: - Roster

    func testAnAvatarChangeLeavesTheMentionNamesAlone() {
        let store = fixtureStore()
        guard let bo = store.people["bo"] else { return XCTFail("no fixture person") }
        let versionBefore = store.rosterVersion
        let withNewAvatar = Person(
            id: bo.id, name: bo.name, kind: bo.kind, isAdmin: bo.isAdmin,
            avatarId: "new-picture", removedAt: bo.removedAt
        )
        let quiet = isNotified(
            by: { store.handle(.personUpdated(withNewAvatar)) },
            reading: { (store.mentionNames, store.rosterVersion) }
        )
        XCTAssertFalse(quiet)
        XCTAssertEqual(store.rosterVersion, versionBefore)

        let renamed = Person(
            id: bo.id, name: "Beatrice", kind: bo.kind, isAdmin: bo.isAdmin,
            avatarId: "new-picture", removedAt: bo.removedAt
        )
        let notified = isNotified(
            by: { store.handle(.personUpdated(renamed)) },
            reading: { (store.mentionNames, store.rosterVersion) }
        )
        XCTAssertTrue(notified)
        XCTAssertTrue(store.mentionNames.contains("Beatrice"))
        XCTAssertEqual(store.mentionNames, store.mentionNames.sorted())
        XCTAssertGreaterThan(store.rosterVersion, versionBefore)
    }

    func testPlainTextIsMemoizedButFollowsTheRoster() {
        let store = fixtureStore()
        guard let bo = store.people["bo"] else { return XCTFail("no fixture person") }
        let first = store.plainText("**hi** @Bo")
        XCTAssertEqual(store.plainText("**hi** @Bo"), first)
        let renamed = Person(
            id: bo.id, name: "Beatrice", kind: bo.kind, isAdmin: bo.isAdmin,
            avatarId: bo.avatarId, removedAt: bo.removedAt
        )
        store.handle(.personUpdated(renamed))
        XCTAssertEqual(
            store.plainText("**hi** @Bo"), MentionText.plain("**hi** @Bo", names: store.mentionNames),
            "a roster change must not serve the old roster's text"
        )
    }
}

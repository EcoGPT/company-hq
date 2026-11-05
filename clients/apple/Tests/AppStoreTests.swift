import XCTest
import UserNotifications

@testable import HQ

final class AppStoreTests: XCTestCase {
    func testACacheFromAnotherSchemaIsDroppedAndTheCurrentOneKept() {
        let note = Message(id: "1", conversationId: "updates", senderPersonId: "scout",
                           senderName: "Scout", content: "Hello", createdAt: "2026-09-07T00:00:00Z")
        var snapshot = StateSnapshot(schemaVersion: StateCache.schemaVersion + 1, people: [:], conversations: [],
                                     messagesByConversation: ["updates": [note]])
        XCTAssertNil(StateCache.upgraded(snapshot))
        snapshot.schemaVersion = StateCache.schemaVersion
        XCTAssertEqual(StateCache.upgraded(snapshot)?.messagesByConversation["updates"], [note])
    }

    /// One typing frame every few seconds, inside the hub's five-second
    /// expiry so steady typing never flickers for the reader.
    func testTypingIsAnnouncedEveryFewSecondsNotPerKeystroke() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(AppStore.shouldSendTyping(lastSentAt: nil, now: start))
        XCTAssertFalse(AppStore.shouldSendTyping(lastSentAt: start, now: start.addingTimeInterval(0.2)))
        XCTAssertFalse(AppStore.shouldSendTyping(lastSentAt: start, now: start.addingTimeInterval(2.9)))
        XCTAssertTrue(AppStore.shouldSendTyping(lastSentAt: start, now: start.addingTimeInterval(3)))
        XCTAssertLessThan(AppStore.typingInterval, 5)
    }

    /// The roster answers "who is here": no bots, no machines, and nobody who
    /// has been removed. The other two lists exist so the removed stay
    /// undoable and the machines stay visible — each in its own place.
    @MainActor
    func testRosterIsOnlyPeopleWhoAreStillHere() {
        let people = [
            person(id: "b", name: "Bo"),
            person(id: "e", name: "Scout", kind: "bot"),
            person(id: "a", name: "Ada"),
            person(id: "g", name: "GitHub Actions", kind: "service"),
            person(id: "d", name: "Dana", removedAt: "2026-08-30T12:00:00Z"),
        ]

        XCTAssertEqual(AppStore.roster(from: people).map(\.name), ["Ada", "Bo"])
        XCTAssertEqual(AppStore.removedMembers(from: people).map(\.name), ["Dana"])
        XCTAssertEqual(AppStore.serviceAccounts(from: people).map(\.name), ["GitHub Actions"])
    }

    @MainActor
    func testGroupMembersFollowRemovalAndRestorationWithoutChangingHistory() {
        let active = person(id: "a", name: "Ada")
        let removed = person(id: "d", name: "Dana", removedAt: "2026-08-30T12:00:00Z")
        let service = person(id: "g", name: "GitHub Actions", kind: "service")
        var people = [active.id: active, removed.id: removed, service.id: service]
        let group = Conversation(
            id: "updates", kind: "group", title: "Updates",
            memberIds: [active.id, removed.id, service.id, "unknown"],
            createdAt: "2026-08-30T00:00:00Z", lastMessage: nil,
            unreadCount: 0, readMarks: [], roomSlug: "updates"
        )

        XCTAssertEqual(AppStore.conversationMembers(of: group, people: people).map(\.id), [active.id])
        XCTAssertEqual(people[removed.id], removed)
        XCTAssertEqual(group.memberIds, [active.id, removed.id, service.id, "unknown"])

        people[removed.id] = person(id: removed.id, name: removed.name)
        XCTAssertEqual(AppStore.conversationMembers(of: group, people: people).map(\.id), [active.id, removed.id])
        people[active.id] = person(id: active.id, name: active.name, removedAt: "2026-09-18T00:00:00Z")
        XCTAssertEqual(AppStore.conversationMembers(of: group, people: people).map(\.id), [removed.id])
    }

    @MainActor
    func testDirectMessagesKeepRemovedPartnersAndEcoIdentifiable() {
        let removed = person(id: "d", name: "Dana", removedAt: "2026-08-30T12:00:00Z")
        let scout = person(id: "scout", name: "Scout", kind: "bot")
        let people = [removed.id: removed, scout.id: scout]
        for partner in [removed, scout] {
            let dm = Conversation(
                id: partner.id, kind: "dm", title: nil, memberIds: [partner.id],
                createdAt: "2026-08-30T00:00:00Z", lastMessage: nil,
                unreadCount: 0, readMarks: []
            )
            XCTAssertEqual(AppStore.conversationMembers(of: dm, people: people), [partner])
        }
    }

    private func person(
        id: String, name: String, kind: String = "person", removedAt: String? = nil
    ) -> Person {
        Person(id: id, name: name, kind: kind, isAdmin: false, avatarId: nil, removedAt: removedAt)
    }

    @MainActor
    func testSelectedConversationIsReadOnlyWhileActiveAndVisible() {
        XCTAssertTrue(
            AppStore.shouldMarkRead(
                "chat", selectedConversationId: "chat",
                isAppActive: true, isConversationVisible: true
            )
        )
        XCTAssertFalse(
            AppStore.shouldMarkRead(
                "chat", selectedConversationId: "chat",
                isAppActive: false, isConversationVisible: true
            )
        )
        XCTAssertFalse(
            AppStore.shouldMarkRead(
                "chat", selectedConversationId: "chat",
                isAppActive: true, isConversationVisible: false
            )
        )
        XCTAssertFalse(
            AppStore.shouldMarkRead(
                "chat", selectedConversationId: "other",
                isAppActive: true, isConversationVisible: true
            )
        )
    }

    @MainActor
    func testReadCursorClearsOnlyReadMessageNotifications() {
        let old = notification(
            identifier: "old", conversationId: "chat", messageId: "01"
        )
        let latest = notification(
            identifier: "latest", conversationId: "chat", messageId: "02"
        )
        let newer = notification(
            identifier: "newer", conversationId: "chat", messageId: "03"
        )
        let other = notification(
            identifier: "other", conversationId: "other", messageId: "01"
        )
        let call = notification(
            identifier: "call", conversationId: "chat", messageId: "01", callId: "ring"
        )

        XCTAssertEqual(
            NotificationManager.messageNotificationIdentifiers(
                in: [old, latest, newer, other, call], readThrough: ["chat": "02"]
            ),
            ["old", "latest"]
        )
    }

    @MainActor
    func testSearchResultOpensItsConversationAndKeepsItsMessageId() async {
        let store = AppStore()
        store.searchQuery = "needle"

        await store.openSearchResult(conversationId: "chat", messageId: "message")

        XCTAssertEqual(store.searchQuery, "")
        XCTAssertEqual(store.selectedConversationId, "chat")
        XCTAssertEqual(
            store.messageJump,
            AppStore.MessageJump(conversationId: "chat", messageId: "message")
        )
    }

    @MainActor
    func testUnknownOldEditDoesNotReplaceLatestConversationMessage() {
        let original = message(id: "01", content: "old alert")
        let latest = message(id: "02", content: "today's completion")
        let edited = message(id: "01", content: "updated alert", editedAt: "2026-08-31T00:00:00Z")

        let outsideLoadedWindow = AppStore.applyingMessageUpdate(edited, to: [latest])
        let insideLoadedWindow = AppStore.applyingMessageUpdate(edited, to: [original, latest])

        XCTAssertEqual(outsideLoadedWindow, [latest])
        XCTAssertEqual(insideLoadedWindow, [edited, latest])
        XCTAssertEqual(insideLoadedWindow.last, latest)
    }

    @MainActor
    func testRefreshReplacesCachedLinksAndKeepsOlderHistory() {
        let older = message(id: "01", content: "older history")
        let cached = message(id: "02", content: "https://example.com/team")
        let edited = message(id: "02", content: "https://example.com/team#notes", editedAt: "2026-09-06T18:00:00Z")
        let newest = message(id: "03", content: "new message")

        XCTAssertEqual(
            AppStore.mergingMessages([newest, edited], into: [older, cached]),
            [older, edited, newest]
        )
    }

    @MainActor
    func testStaleHistoryResponseDoesNotUndoNewerLiveEdit() {
        let stale = message(id: "01", content: "old URL")
        let edited = message(id: "01", content: "new URL", editedAt: "2026-09-06T18:00:00.000Z")
        XCTAssertEqual(AppStore.mergingMessages([stale], into: [edited]), [edited])
    }

    private func message(id: String, content: String, editedAt: String? = nil) -> Message {
        Message(
            id: id,
            conversationId: "updates",
            senderPersonId: "scout",
            senderName: "Scout",
            content: content,
            createdAt: "2026-08-28T03:00:00Z",
            editedAt: editedAt
        )
    }

    private func notification(
        identifier: String, conversationId: String, messageId: String, callId: String? = nil
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.userInfo = [
            "conversation_id": conversationId,
            "message_id": messageId,
        ]
        if let callId { content.userInfo["call_id"] = callId }
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}

// MARK: - Removed teammates in live lists

extension AppStoreTests {
    private func removable(_ id: String, _ name: String, removed: Bool) -> Person {
        Person(
            id: id, name: name, kind: "person", isAdmin: false, avatarId: nil,
            removedAt: removed ? "2026-08-30T12:00:00Z" : nil
        )
    }

    private func thread(_ id: String, _ kind: String, _ members: [String]) -> Conversation {
        Conversation(
            id: id, kind: kind, title: nil, memberIds: members,
            createdAt: "2026-08-30T00:00:00Z", lastMessage: nil,
            unreadCount: 0, readMarks: [], roomSlug: nil
        )
    }

    @MainActor
    func testDMWithRemovedPartnerIsHiddenAndReturnsOnRestore() {
        let dm = thread("dm", "dm", ["me", "d"])
        var people = ["me": removable("me", "Me", removed: false), "d": removable("d", "Dana", removed: true)]
        XCTAssertTrue(AppStore.isRemovedPartnerDM(dm, meId: "me", people: people))
        people["d"] = removable("d", "Dana", removed: false)
        XCTAssertFalse(AppStore.isRemovedPartnerDM(dm, meId: "me", people: people))
    }

    @MainActor
    func testGroupWithRemovedMemberStaysListedWithoutThem() {
        let people = [
            "me": removable("me", "Me", removed: false),
            "a": removable("a", "Ada", removed: false),
            "d": removable("d", "Dana", removed: true),
        ]
        let group = thread("g", "group", ["me", "a", "d"])
        XCTAssertFalse(AppStore.isRemovedPartnerDM(group, meId: "me", people: people))
        XCTAssertEqual(AppStore.conversationMembers(of: group, people: people).map(\.id), ["me", "a"])
    }

    @MainActor
    func testRecommendedRecipientsSkipRemovedPeople() {
        let people = [
            "me": removable("me", "Me", removed: false),
            "a": removable("a", "Ada", removed: false),
            "d": removable("d", "Dana", removed: true),
            "z": removable("z", "Zed", removed: false),
        ]
        let recents = [thread("g", "group", ["me", "d", "z"]), thread("dm", "dm", ["me", "d"])]
        let ordered = AppStore.recommendedRecipients(conversations: recents, people: people, meId: "me")
        XCTAssertEqual(ordered.map(\.id), ["z", "a"])
    }

    @MainActor
    func testOwnerDefaultFallsBackToMeWhenLeadIsRemoved() {
        let people = [
            "me": removable("me", "Me", removed: false),
            "a": removable("a", "Ada", removed: false),
            "d": removable("d", "Dana", removed: true),
        ]
        XCTAssertEqual(AppStore.defaultOwner(lead: "a", meId: "me", people: people), "a")
        XCTAssertEqual(AppStore.defaultOwner(lead: "d", meId: "me", people: people), "me")
        XCTAssertEqual(AppStore.defaultOwner(lead: nil, meId: "me", people: people), "me")
    }

    @MainActor
    func testMentionSuggestionsExcludeRemovedMember() {
        let people = ["a": removable("a", "Ada", removed: false), "d": removable("d", "Dana", removed: true)]
        XCTAssertEqual(
            AppStore.mentionMembers(memberIds: ["a", "d", "me"], meId: "me", people: people).map(\.id), ["a"])
    }

    @MainActor
    func testFacepileDropsRemovedBeforeCountingOverflow() {
        let people = [
            "a": removable("a", "Ada", removed: false),
            "d": removable("d", "Dana", removed: true),
            "z": removable("z", "Zed", removed: false),
        ]
        XCTAssertEqual(InviteeFacepile.livePeople(["d", "a", "x", "z"], people: people).map(\.id), ["a", "z"])
        XCTAssertTrue(InviteeFacepile.livePeople(["d"], people: people).isEmpty)
    }

    @MainActor
    func testGroupWithOnlyRemovedOthersIsNotNamedAfterMe() {
        let people = ["me": removable("me", "Me", removed: false), "d": removable("d", "Dana", removed: true)]
        let stale = thread("g", "group", ["me", "d"])
        let fresh = thread("g", "group", ["me"])
        for group in [stale, fresh] {
            XCTAssertEqual(AppStore.nameWithNoOthers(group, meId: "me", meName: "Me", people: people), "Conversation")
        }
        let selfDM = thread("s", "dm", ["me"])
        XCTAssertEqual(AppStore.nameWithNoOthers(selfDM, meId: "me", meName: "Me", people: people), "Me")
        let withAda = thread("g2", "group", ["me", "a"])
        let both = people.merging(["a": removable("a", "Ada", removed: false)]) { $1 }
        XCTAssertNil(AppStore.nameWithNoOthers(withAda, meId: "me", meName: "Me", people: both))
    }
}

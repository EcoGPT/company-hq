import XCTest

@testable import HQ

/// `ServerFrame.decode` parses each frame once (a `type` peek and the payload
/// share one decoder) and runs off the main actor. Every frame type must still
/// come out exactly as the old two-pass decode produced it, and each payload
/// here is compared against the model decoded straight from its own sub-object,
/// which is the value the old payload struct wrapped.
final class ServerFrameDecodeTests: XCTestCase {
    private let stamp = "2026-10-14T12:00:00.000Z"

    private var personJSON: String {
        #"{"id":"p1","name":"Bo","kind":"human","is_admin":true,"can_hire":true}"#
    }

    private var messageJSON: String {
        """
        {"id":"m1","conversation_id":"c1","sender_person_id":"p1","sender_name":"Bo",
         "content":"hello","created_at":"\(stamp)","reactions":[{"emoji":"+1","person_ids":["p2"]}],
         "attachments":[],"kind":"work","via":"mcp"}
        """
    }

    private var conversationJSON: String {
        """
        {"id":"c1","kind":"group","title":"Eng","member_ids":["p1","p2"],"created_at":"\(stamp)",
         "last_message":\(messageJSON),"unread_count":3,"read_marks":[{"person_id":"p2","last_read_message_id":"m0"}],
         "room_slug":"eng"}
        """
    }

    private var callJSON: String {
        """
        {"id":"call1","conversation_id":"c1","kind":"call","started_by_person_id":"p1",
         "started_at":"\(stamp)","participants":[{"device_id":"d1","person_id":"p1","is_muted":false,
         "is_camera_on":true,"is_screen_sharing":false,"is_hand_raised":false,"joined_at":"\(stamp)"}],
         "tracks":[]}
        """
    }

    private var meetingJSON: String {
        #"{"id":"mt1","title":"Standup","created_by_person_id":"p1","created_at":"\#(stamp)","invitee_person_ids":["p1"]}"#
    }

    private var taskJSON: String {
        """
        {"id":"t1","title":"Ship it","status":"open","owner_person_id":"p1","owner_name":"Bo",
         "created_by_person_id":"p1","created_at":"\(stamp)","number":412}
        """
    }

    private func decode(_ json: String) -> ServerFrame {
        ServerFrame.decode(Data(json.utf8))
    }

    private func model<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Every frame type

    func testHello() {
        guard case let .hello(deviceId, personId, online) = decode(
            #"{"type":"hello","device_id":"d1","person_id":"p1","online_person_ids":["p1","p2"]}"#
        ) else { return XCTFail("not hello") }
        XCTAssertEqual(deviceId, "d1")
        XCTAssertEqual(personId, "p1")
        XCTAssertEqual(online, ["p1", "p2"])
    }

    func testMessageAndMessageUpdated() throws {
        let expected = try model(Message.self, messageJSON)
        guard case let .message(created) = decode(#"{"type":"message","message":\#(messageJSON)}"#)
        else { return XCTFail("not message") }
        XCTAssertEqual(created, expected)
        guard case let .messageUpdated(updated) = decode(#"{"type":"message_updated","message":\#(messageJSON)}"#)
        else { return XCTFail("not message_updated") }
        XCTAssertEqual(updated, expected)
    }

    func testConversationUpdatedAndRemoved() throws {
        guard case let .conversationUpdated(conversation) = decode(
            #"{"type":"conversation_updated","conversation":\#(conversationJSON)}"#
        ) else { return XCTFail("not conversation_updated") }
        XCTAssertEqual(conversation, try model(Conversation.self, conversationJSON))
        guard case let .conversationRemoved(id) = decode(#"{"type":"conversation_removed","conversation_id":"c1"}"#)
        else { return XCTFail("not conversation_removed") }
        XCTAssertEqual(id, "c1")
    }

    func testPersonUpdated() throws {
        guard case let .personUpdated(person) = decode(#"{"type":"person_updated","person":\#(personJSON)}"#)
        else { return XCTFail("not person_updated") }
        XCTAssertEqual(person, try model(Person.self, personJSON))
    }

    func testPresenceTypingBotStateRead() {
        guard case let .presence(presenceId, online) = decode(
            #"{"type":"presence","person_id":"p1","is_online":true}"#
        ) else { return XCTFail("not presence") }
        XCTAssertEqual(presenceId, "p1")
        XCTAssertTrue(online)

        guard case let .typing(typingConversation, typingPerson, typingExpires) = decode(
            #"{"type":"typing","conversation_id":"c1","person_id":"p2","expires_at":"\#(stamp)"}"#
        ) else { return XCTFail("not typing") }
        XCTAssertEqual([typingConversation, typingPerson, typingExpires], ["c1", "p2", stamp])

        guard case let .botState(botConversation, botPerson, label, botExpires) = decode(
            #"{"type":"bot_state","conversation_id":"c1","person_id":"scout","label":"Reading","expires_at":"\#(stamp)"}"#
        ) else { return XCTFail("not bot_state") }
        XCTAssertEqual([botConversation, botPerson, botExpires], ["c1", "scout", stamp])
        XCTAssertEqual(label, "Reading")

        // A cleared bot state carries a null label.
        guard case let .botState(_, _, cleared, _) = decode(
            #"{"type":"bot_state","conversation_id":"c1","person_id":"scout","label":null,"expires_at":"\#(stamp)"}"#
        ) else { return XCTFail("not bot_state") }
        XCTAssertNil(cleared)

        guard case let .read(readConversation, readPerson, last) = decode(
            #"{"type":"read","conversation_id":"c1","person_id":"p1","last_read_message_id":"m9"}"#
        ) else { return XCTFail("not read") }
        XCTAssertEqual([readConversation, readPerson, last], ["c1", "p1", "m9"])
    }

    func testSyncBatchSyncCompleteAndError() throws {
        let expected = try model(Message.self, messageJSON)
        guard case let .syncBatch(messages) = decode(
            #"{"type":"sync_batch","messages":[\#(messageJSON),\#(messageJSON)]}"#
        ) else { return XCTFail("not sync_batch") }
        XCTAssertEqual(messages, [expected, expected])

        guard case let .syncComplete(partial) = decode(#"{"type":"sync_complete","is_partial":true}"#)
        else { return XCTFail("not sync_complete") }
        XCTAssertTrue(partial)

        guard case let .serverError(code) = decode(#"{"type":"error","code":"rate_limited"}"#)
        else { return XCTFail("not error") }
        XCTAssertEqual(code, "rate_limited")
    }

    func testCallFrames() throws {
        guard case let .callState(call) = decode(#"{"type":"call_state","call":\#(callJSON)}"#)
        else { return XCTFail("not call_state") }
        XCTAssertEqual(call, try model(Call.self, callJSON))

        guard case let .callEnded(endedId, endedAt) = decode(
            #"{"type":"call_ended","call_id":"call1","ended_at":"\#(stamp)"}"#
        ) else { return XCTFail("not call_ended") }
        XCTAssertEqual([endedId, endedAt], ["call1", stamp])

        // call_ring is the IncomingCall itself, its fields beside `type`.
        let ringJSON = #"{"call":\#(callJSON),"caller_name":"Bo","conversation_title":"Eng","expires_at":"\#(stamp)"}"#
        guard case let .callRing(ring) = decode(
            #"{"type":"call_ring","call":\#(callJSON),"caller_name":"Bo","conversation_title":"Eng","expires_at":"\#(stamp)"}"#
        ) else { return XCTFail("not call_ring") }
        XCTAssertEqual(ring, try model(IncomingCall.self, ringJSON))

        guard case let .callRingEnded(ringId) = decode(#"{"type":"call_ring_ended","call_id":"call1"}"#)
        else { return XCTFail("not call_ring_ended") }
        XCTAssertEqual(ringId, "call1")
    }

    func testMeetingsAndReminder() throws {
        let expected = try model(Meeting.self, meetingJSON)
        guard case let .meetings(list) = decode(#"{"type":"meetings","meetings":[\#(meetingJSON)]}"#)
        else { return XCTFail("not meetings") }
        XCTAssertEqual(list, [expected])

        guard case let .meetingReminder(meeting, minutes) = decode(
            #"{"type":"meeting_reminder","meeting":\#(meetingJSON),"minutes_until":4}"#
        ) else { return XCTFail("not meeting_reminder") }
        XCTAssertEqual(meeting, expected)
        XCTAssertEqual(minutes, 4)
    }

    func testTasks() throws {
        let expected = try model(TeamTask.self, taskJSON)
        guard case let .tasks(list) = decode(#"{"type":"tasks","tasks":[\#(taskJSON),\#(taskJSON)]}"#)
        else { return XCTFail("not tasks") }
        XCTAssertEqual(list, [expected, expected])
        XCTAssertEqual(list.first?.ref, "HQ-\(412)")
    }

    func testMessagesMovedAndFramesForOtherFeaturesAreIgnored() {
        // Frames this client has no feature for are ignored, never an error.
        for type in ["extra_one", "extra_two", "extra_three", "extra_four"] {
            guard case .unknown = decode(#"{"type":"\#(type)"}"#) else { return XCTFail("\(type) is not ignored") }
        }
        guard case let .messagesMoved(from, ids) = decode(
            #"{"type":"messages_moved","from_conversation_id":"c1","message_ids":["m1","m2"]}"#
        ) else { return XCTFail("not messages_moved") }
        XCTAssertEqual(from, "c1")
        XCTAssertEqual(ids, ["m1", "m2"])
    }

    // MARK: - What stays ignored

    func testUnknownTypeIsUnknown() {
        guard case .unknown = decode(#"{"type":"from_the_future","anything":1}"#) else { return XCTFail() }
    }

    func testAPayloadThatDoesNotDecodeIsIgnored() {
        guard case .unknown = decode(#"{"type":"presence","person_id":"p1"}"#) else { return XCTFail() }
        guard case .unknown = decode(#"{"type":"message","message":{"id":"m1"}}"#) else { return XCTFail() }
    }

    func testGarbageAndMissingTypeAreUnknown() {
        guard case .unknown = decode("pong") else { return XCTFail() }
        guard case .unknown = decode("") else { return XCTFail() }
        guard case .unknown = decode(#"{"person_id":"p1","is_online":true}"#) else { return XCTFail() }
        guard case .unknown = decode(#"{"type":7}"#) else { return XCTFail() }
        guard case .unknown = decode(#"[{"type":"user_messages"}]"#) else { return XCTFail() }
    }

    // MARK: - One parse, key order free

    func testTypeMayFollowThePayloadAndNestedTypesAreIgnored() throws {
        // `type` last, and a nested object carrying its own `type` key: the
        // wrapper must read the top-level one only.
        let decoy = #"{"id":"m1","conversation_id":"c1","sender_person_id":"p1","sender_name":"Bo","content":"x","created_at":"\#(stamp)","reactions":[],"attachments":[],"type":"presence"}"#
        guard case let .message(message) = decode(#"{"message":\#(decoy),"type":"message"}"#)
        else { return XCTFail("not message") }
        XCTAssertEqual(message.id, "m1")
    }

    func testDecodeRunsOffTheMainActor() async {
        // Pure and nonisolated: callable from a detached task, as the socket's
        // receive callback does.
        let json = #"{"type":"sync_complete","is_partial":false}"#
        let frame = await Task.detached { ServerFrame.decode(Data(json.utf8)) }.value
        guard case let .syncComplete(partial) = frame else { return XCTFail("not sync_complete") }
        XCTAssertFalse(partial)
    }
}

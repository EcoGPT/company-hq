import AppKit
import XCTest

@testable import HQ

/// The app's real networking against a real HQ Community server: `HQClient`,
/// `EventSocket` and `AppStore`, no fixtures and no mocks. The server tests
/// compare its JSON with a key list taken from this app, and every other test
/// here runs on fixtures; this is the one place the two meet.
///
/// Skipped unless all three are set (pass them through `TEST_RUNNER_`, which
/// `xcodebuild` strips before handing them to the test host):
///
///     HQ_LIVE_SERVER   the server's address, e.g. http://127.0.0.1:18790
///     HQ_LIVE_KEY_A    an invite key for an admin named Ada
///     HQ_LIVE_KEY_B    an invite key for a member named Bo
///
/// Run against a throwaway database: the tests create rooms, messages, keys and
/// one new person per run. Nothing is ever deleted from the server.
///
/// The test host is the real app, so `AppStore.enroll` writes the host's own
/// Keychain item and server default. The tests that touch them put back what
/// was there.
@MainActor
final class LiveServerTests: XCTestCase {
    // MARK: - Setup

    private struct Live {
        let server: String
        let keyA: String
        let keyB: String
    }

    /// A person signed in on one device.
    private struct Who {
        let response: HQClient.EnrollResponse
        var client: HQClient { HQClient(bearer: response.bearer) }
        var person: Person { response.person }
        var id: String { response.person.id }
    }

    private struct Timeout: Error, CustomStringConvertible {
        let description: String
    }

    private var live: Live!
    private var previousServer: String?
    private var sockets: [EventSocket] = []
    private var logs: [FrameLog] = []
    private static var signedIn: (ada: Who, bo: Who)?

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        func value(_ name: String) -> String? {
            let text = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        guard let server = value("HQ_LIVE_SERVER"), let keyA = value("HQ_LIVE_KEY_A"),
              let keyB = value("HQ_LIVE_KEY_B")
        else { throw XCTSkip("HQ_LIVE_SERVER, HQ_LIVE_KEY_A and HQ_LIVE_KEY_B are not all set") }
        XCTAssertFalse(HQSimulatorFixture.isEnabled, "a live run must not be a fixture run")
        guard case .success(let normalized) = HQConfig.normalizedServer(server) else {
            throw XCTSkip("HQ_LIVE_SERVER is not a usable server address")
        }
        live = Live(server: normalized, keyA: keyA, keyB: keyB)
        previousServer = HQConfig.savedServer
        HQConfig.savedServer = normalized
    }

    override func tearDown() async throws {
        for socket in sockets { socket.stop() }
        sockets = []
        // After the sockets, so a late frame cannot land in a log that was checked.
        logs = []
        if live != nil { HQConfig.savedServer = previousServer }
    }

    /// Enrolls Ada and Bo once per run; every test after the first reuses the devices.
    private func signIn() async throws -> (ada: Who, bo: Who) {
        if let known = Self.signedIn { return known }
        let ada = Who(response: try await HQClient.enroll(
            key: live.keyA, personName: nil, deviceName: "LiveServerTests Ada"))
        let bo = Who(response: try await HQClient.enroll(
            key: live.keyB, personName: nil, deviceName: "LiveServerTests Bo"))
        Self.signedIn = (ada, bo)
        return (ada, bo)
    }

    /// A short word no earlier run used, so a search or a title finds only this run's rows.
    private func tag() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
    }

    private func clientMsgId() -> String { UUID().uuidString.lowercased() }

    // MARK: - Sockets

    @MainActor
    private final class FrameLog {
        private(set) var frames: [ServerFrame] = []
        var socket: EventSocket?

        func record(_ frame: ServerFrame) { frames.append(frame) }

        static func label(_ frame: ServerFrame) -> String {
            String(String(describing: frame).prefix { $0 != "(" })
        }

        /// Frames the app could not turn into anything. `ServerFrame.decode` drops a
        /// payload it cannot read as `.unknown` without a word, so this is the only
        /// place a wrong key on a frame shows.
        var undecodable: [ServerFrame] {
            frames.filter {
                switch $0 {
                case .unknown, .serverError: return true
                default: return false
                }
            }
        }

        func wait<T>(
            _ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
            _ match: (ServerFrame) -> T?
        ) async throws -> T {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                for frame in frames { if let found = match(frame) { return found } }
                if Date() > deadline { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let saw = frames.map(Self.label).joined(separator: ", ")
            XCTFail("no \(what) within \(Int(timeout))s; frames seen: [\(saw)]", file: file, line: line)
            throw Timeout(description: what)
        }
    }

    /// Opens a socket the way the app does and waits for `hello`.
    private func openSocket(
        _ who: Who, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> FrameLog {
        let log = FrameLog()
        let socket = EventSocket(bearer: who.response.bearer, onConnect: {}, onFrame: { log.record($0) })
        log.socket = socket
        sockets.append(socket)
        logs.append(log)
        socket.connect()
        let hello: (device: String, person: String, online: [String]) = try await log.wait(
            "hello for \(who.person.name)", file: file, line: line
        ) {
            if case .hello(let device, let person, let online) = $0 { return (device, person, online) }
            return nil
        }
        XCTAssertEqual(hello.device, who.response.deviceId, file: file, line: line)
        XCTAssertEqual(hello.person, who.id, file: file, line: line)
        return log
    }

    private func assertNothingUndecodable(_ log: FrameLog, _ owner: String, line: UInt = #line) {
        XCTAssertTrue(
            log.undecodable.isEmpty,
            "\(owner)'s socket got frames the app could not read: \(log.undecodable.map(FrameLog.label))",
            line: line
        )
    }

    private func expectAPIError<T>(
        _ status: Int, _ code: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> T
    ) async -> APIError? {
        do {
            _ = try await body()
            XCTFail("expected \(status) \(code), but the call succeeded", file: file, line: line)
            return nil
        } catch let error as APIError {
            XCTAssertEqual(error.status, status, file: file, line: line)
            XCTAssertEqual(error.code, code, file: file, line: line)
            return error
        } catch {
            XCTFail("expected APIError \(code), got \(error)", file: file, line: line)
            return nil
        }
    }

    private func isFractionalISO8601(_ text: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) != nil
    }

    private func png(_ color: NSColor, side: Int = 32) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: - a. Sign-in and the first reads

    func testEnrollThenPeopleConversationsAndCallsDecode() async throws {
        // Two devices from one invite: an invite adds devices until it expires.
        let ada = Who(response: try await HQClient.enroll(
            key: live.keyA, personName: nil, deviceName: "LiveServerTests Ada"))
        let bo = Who(response: try await HQClient.enroll(
            key: live.keyB, personName: "Bo", deviceName: "LiveServerTests Bo"))
        let again = try await HQClient.enroll(key: live.keyA, personName: nil, deviceName: "LiveServerTests Ada 2")
        XCTAssertNotEqual(again.deviceId, ada.response.deviceId)
        XCTAssertNotEqual(again.bearer, ada.response.bearer)
        XCTAssertFalse(ada.response.bearer.isEmpty)
        XCTAssertFalse(ada.person.name.isEmpty)
        XCTAssertNotEqual(ada.id, bo.id)
        XCTAssertTrue(ada.person.isAdmin)
        XCTAssertEqual(ada.person.kind, "person")
        XCTAssertFalse(bo.person.name.isEmpty)
        XCTAssertFalse(bo.person.isAdmin)
        XCTAssertNil(ada.person.removedAt)

        let people = try await ada.client.people()
        XCTAssertTrue(people.contains(ada.person), "people() lacks Ada exactly as enroll described her")
        XCTAssertTrue(people.contains(bo.person), "people() lacks Bo exactly as enroll described him")
        XCTAssertTrue(people.contains { $0.kind == "bot" }, "the built-in assistant is not on the roster")
        XCTAssertEqual(Set(people.map(\.id)).count, people.count)

        let conversations = try await ada.client.conversations()
        let room = try XCTUnwrap(conversations.first { $0.roomSlug != nil }, "Ada has no standing room (General)")
        XCTAssertEqual(room.kind, "group")
        XCTAssertTrue(room.memberIds.contains(ada.id))
        XCTAssertTrue(isFractionalISO8601(room.createdAt), "created_at is not ISO 8601: \(room.createdAt)")
        XCTAssertGreaterThanOrEqual(room.unreadCount, 0)

        let snapshot = try await ada.client.calls()
        XCTAssertTrue(snapshot.calls.isEmpty)
        XCTAssertTrue(snapshot.meetings.isEmpty)
        XCTAssertTrue(snapshot.ringing.isEmpty)

        // The two refusals a person meets first.
        let badKey = await expectAPIError(401, "invalid_key") {
            try await HQClient.enroll(key: "hq_" + String(repeating: "0", count: 40), personName: nil, deviceName: "x")
        }
        XCTAssertEqual(badKey?.errorDescription, "That access key isn't valid.")
        let badBearer = await expectAPIError(401, "unauthorized") {
            try await HQClient(bearer: "hq_" + String(repeating: "0", count: 40)).people()
        }
        XCTAssertEqual(badBearer?.errorDescription, "This device's access was revoked.")
    }

    // MARK: - b. A group reaches the other person's socket

    func testAGroupWithBoReachesBosSocket() async throws {
        let (ada, bo) = try await signIn()
        let adaLog = try await openSocket(ada)
        let boLog = try await openSocket(bo)

        let title = "Live group \(tag())"
        let group = try await ada.client.createGroup(title: title, personIds: [bo.id])
        XCTAssertEqual(group.kind, "group")
        XCTAssertEqual(group.title, title)
        // The server puts the built-in assistant in every group; nobody else comes uninvited.
        let roster = Dictionary(uniqueKeysWithValues: try await ada.client.people().map { ($0.id, $0) })
        func assertMembers(_ members: [String], _ what: String) {
            XCTAssertTrue(Set([ada.id, bo.id]).isSubset(of: members), "\(what) lacks Ada or Bo")
            let others = Set(members).subtracting([ada.id, bo.id])
            XCTAssertTrue(others.allSatisfy { roster[$0]?.kind == "bot" }, "\(what) has an uninvited member")
        }
        assertMembers(group.memberIds, "the new group")
        XCTAssertNil(group.roomSlug)
        XCTAssertNil(group.lastMessage)

        let seen: Conversation = try await boLog.wait("conversation_updated for the new group on Bo's socket") {
            if case .conversationUpdated(let conversation) = $0, conversation.id == group.id { return conversation }
            return nil
        }
        XCTAssertEqual(seen.title, title)
        assertMembers(seen.memberIds, "Bo's copy of the group")
        XCTAssertEqual(seen.kind, "group")
        _ = try await adaLog.wait("conversation_updated for the new group on Ada's socket") {
            if case .conversationUpdated(let conversation) = $0, conversation.id == group.id { return conversation }
            return nil
        }

        let listed = try await bo.client.conversations()
        XCTAssertTrue(listed.contains { $0.id == group.id }, "Bo's conversation list lacks the group")
        let fetched = try await bo.client.conversation(id: group.id)
        XCTAssertEqual(fetched.id, group.id)

        // A direct message is the other shape the sidebar draws.
        let dm = try await bo.client.createDM(personId: ada.id)
        XCTAssertEqual(dm.kind, "dm")
        XCTAssertTrue(dm.memberIds.contains(ada.id), "a DM's member_ids must name the other person")
        let dmAgain = try await bo.client.createDM(personId: ada.id)
        XCTAssertEqual(dmAgain.id, dm.id, "creating a DM twice must return the same DM")

        // Renaming reaches the other member too.
        let renamed = "Renamed \(tag())"
        _ = try await ada.client.rename(conversationId: group.id, title: renamed)
        _ = try await boLog.wait("the rename on Bo's socket") {
            if case .conversationUpdated(let conversation) = $0,
               conversation.id == group.id, conversation.title == renamed { return conversation }
            return nil
        }
        assertNothingUndecodable(adaLog, "Ada")
        assertNothingUndecodable(boLog, "Bo")
    }

    // MARK: - c. Send, reply, tapback, edit, unsend

    func testAMessageIsSentTappedBackEditedAndUnsentOnTheOtherPersonsSocket() async throws {
        let (ada, bo) = try await signIn()
        let adaLog = try await openSocket(ada)
        let boLog = try await openSocket(bo)
        let group = try await ada.client.createGroup(title: "Live msgs \(tag())", personIds: [bo.id])
        let word = tag()

        // Send.
        let original = "hello \(word)"
        let id = clientMsgId()
        let sent = try await ada.client.send(conversationId: group.id, clientMsgId: id, content: original)
        XCTAssertEqual(sent.conversationId, group.id)
        XCTAssertEqual(sent.senderPersonId, ada.id)
        XCTAssertEqual(sent.senderName, ada.person.name)
        XCTAssertEqual(sent.content, original)
        XCTAssertTrue(isFractionalISO8601(sent.createdAt), "created_at is not ISO 8601: \(sent.createdAt)")
        XCTAssertNil(sent.editedAt)
        XCTAssertNil(sent.deletedAt)
        XCTAssertTrue(sent.reactions.isEmpty)
        XCTAssertTrue(sent.attachments.isEmpty)
        XCTAssertNil(sent.replyTo)

        let arrived: Message = try await boLog.wait("message frame on Bo's socket") {
            if case .message(let message) = $0, message.id == sent.id { return message }
            return nil
        }
        XCTAssertEqual(arrived.content, original)
        XCTAssertEqual(arrived.senderPersonId, ada.id)
        XCTAssertEqual(arrived.senderName, ada.person.name)
        XCTAssertEqual(arrived.conversationId, group.id)
        XCTAssertEqual(arrived.createdAt, sent.createdAt)
        _ = try await adaLog.wait("Ada's own message frame (a sender's other devices need it)") {
            if case .message(let message) = $0, message.id == sent.id { return message }
            return nil
        }

        // A lost answer is retried with the same id and gets the first message back.
        let retried = try await ada.client.send(conversationId: group.id, clientMsgId: id, content: original)
        XCTAssertEqual(retried.id, sent.id)

        // Reply.
        let replyText = "replying \(word)"
        let reply = try await bo.client.send(
            conversationId: group.id, clientMsgId: clientMsgId(), content: replyText, replyToMessageId: sent.id)
        let stub = try XCTUnwrap(reply.replyTo, "the reply came back with no reply_to")
        XCTAssertEqual(stub.id, sent.id)
        XCTAssertEqual(stub.content, original)
        XCTAssertEqual(stub.senderName, ada.person.name)
        let replyArrived: Message = try await adaLog.wait("reply frame on Ada's socket") {
            if case .message(let message) = $0, message.id == reply.id { return message }
            return nil
        }
        XCTAssertEqual(replyArrived.replyTo, stub)
        XCTAssertGreaterThan(reply.id, sent.id, "message ids must sort in the order they were made")

        // Tapback: Bo reacts, Ada's socket hears it.
        let tapped = try await bo.client.react(messageId: sent.id, emoji: "👍")
        XCTAssertEqual(tapped.reactions, [Reaction(emoji: "👍", personIds: [bo.id])])
        let tapFrame: Message = try await adaLog.wait("message_updated for the tapback on Ada's socket") {
            if case .messageUpdated(let message) = $0, message.id == sent.id, !message.reactions.isEmpty {
                return message
            }
            return nil
        }
        XCTAssertEqual(tapFrame.reactions, [Reaction(emoji: "👍", personIds: [bo.id])])
        XCTAssertEqual(tapFrame.content, original)

        // Edit: Ada changes it, Bo's socket hears it, the old text is kept in the history.
        let edited = "edited \(word)"
        let editResult = try await ada.client.edit(messageId: sent.id, content: edited)
        XCTAssertEqual(editResult.content, edited)
        XCTAssertNotNil(editResult.editedAt)
        let editFrame: Message = try await boLog.wait("message_updated for the edit on Bo's socket") {
            if case .messageUpdated(let message) = $0, message.id == sent.id, message.content == edited {
                return message
            }
            return nil
        }
        let editedAt = try XCTUnwrap(editFrame.editedAt, "the edit frame has no edited_at")
        XCTAssertTrue(isFractionalISO8601(editedAt), "edited_at is not ISO 8601: \(editedAt)")
        XCTAssertEqual(editFrame.editHistory?.map(\.content), [original])
        XCTAssertEqual(editFrame.reactions, [Reaction(emoji: "👍", personIds: [bo.id])], "an edit must keep tapbacks")

        // Only the author can edit.
        let notYours = await expectAPIError(403, "forbidden") {
            try await bo.client.edit(messageId: sent.id, content: "not mine")
        }
        XCTAssertEqual(notYours?.errorDescription, "Only an admin can change this.")

        // Unsend: the row stays, the content goes.
        let gone = try await ada.client.unsend(messageId: sent.id)
        XCTAssertNotNil(gone.deletedAt)
        XCTAssertEqual(gone.content, "")
        XCTAssertTrue(gone.reactions.isEmpty)
        let goneFrame: Message = try await boLog.wait("message_updated for the unsend on Bo's socket") {
            if case .messageUpdated(let message) = $0, message.id == sent.id, message.deletedAt != nil {
                return message
            }
            return nil
        }
        XCTAssertEqual(goneFrame.id, sent.id)
        XCTAssertEqual(goneFrame.content, "")
        XCTAssertTrue(goneFrame.reactions.isEmpty)
        XCTAssertTrue(goneFrame.attachments.isEmpty)

        // The history read: oldest first, the unsent row in place, the reply after it.
        let history = try await bo.client.messages(conversationId: group.id, before: nil)
        XCTAssertEqual(history.map(\.id), [sent.id, reply.id])
        XCTAssertNotNil(history.first?.deletedAt)
        XCTAssertEqual(history.last?.replyTo?.id, sent.id)
        let older = try await bo.client.messages(conversationId: group.id, before: reply.id)
        XCTAssertEqual(older.map(\.id), [sent.id])

        // Search finds the reply, and only where Bo is a member.
        let found = try await bo.client.search(query: word)
        XCTAssertTrue(found.contains { $0.id == reply.id }, "search for \(word) did not find the reply")

        assertNothingUndecodable(adaLog, "Ada")
        assertNothingUndecodable(boLog, "Bo")
    }

    // MARK: - d. Read receipts and typing

    func testMarkReadAndTypingReachTheOtherPerson() async throws {
        let (ada, bo) = try await signIn()
        let adaLog = try await openSocket(ada)
        let boLog = try await openSocket(bo)
        let group = try await ada.client.createGroup(title: "Live read \(tag())", personIds: [bo.id])
        let sent = try await ada.client.send(
            conversationId: group.id, clientMsgId: clientMsgId(), content: "read me \(tag())")
        _ = try await boLog.wait("the message on Bo's socket") {
            if case .message(let message) = $0, message.id == sent.id { return message }
            return nil
        }

        let before = try await bo.client.conversations().first { $0.id == group.id }
        XCTAssertEqual(before?.unreadCount, 1, "Bo should have one unread message")
        XCTAssertEqual(before?.lastMessage?.id, sent.id)

        try await bo.client.markRead(conversationId: group.id, messageId: sent.id)
        let read: (conversation: String, person: String, message: String) = try await adaLog.wait(
            "read frame on Ada's socket"
        ) {
            if case .read(let conversation, let person, let message) = $0, conversation == group.id {
                return (conversation, person, message)
            }
            return nil
        }
        XCTAssertEqual(read.person, bo.id)
        XCTAssertEqual(read.message, sent.id)

        let after = try await ada.client.conversations().first { $0.id == group.id }
        XCTAssertTrue(
            after?.readMarks.contains(ReadMark(personId: bo.id, lastReadMessageId: sent.id)) == true,
            "Ada's copy of the conversation lacks Bo's read mark"
        )
        let boAfter = try await bo.client.conversations().first { $0.id == group.id }
        XCTAssertEqual(boAfter?.unreadCount, 0)

        // Mark unread is private to the reader.
        let unread = try await bo.client.markUnread(conversationId: group.id)
        XCTAssertGreaterThan(unread.unreadCount, 0)

        // Typing: the other person hears it, with an expiry in the future.
        adaLog.socket?.send(["type": "typing", "conversation_id": group.id])
        let typing: (person: String, expires: String) = try await boLog.wait("typing frame on Bo's socket") {
            if case .typing(let conversation, let person, let expires) = $0, conversation == group.id {
                return (person, expires)
            }
            return nil
        }
        XCTAssertEqual(typing.person, ada.id)
        XCTAssertTrue(isFractionalISO8601(typing.expires), "expires_at is not ISO 8601: \(typing.expires)")
        XCTAssertGreaterThan(ISO8601.parse(typing.expires), Date().addingTimeInterval(-1))

        assertNothingUndecodable(adaLog, "Ada")
        assertNothingUndecodable(boLog, "Bo")
    }

    // MARK: - e. Attachments and avatars

    func testAnUploadComesBackByteForByteAndAnAvatarIsSetAndRead() async throws {
        let (ada, bo) = try await signIn()
        let adaLog = try await openSocket(ada)
        let boLog = try await openSocket(bo)
        let group = try await ada.client.createGroup(title: "Live files \(tag())", personIds: [bo.id])

        // Upload, attach, send; the other member downloads the same bytes.
        let bytes = png(.systemTeal)
        let name = "teal \(tag()) ü.png"
        let attachment = try await ada.client.upload(
            conversationId: group.id, data: bytes, fileName: name, contentType: "image/png",
            pixelSize: CGSize(width: 32, height: 32))
        XCTAssertEqual(attachment.fileName, name)
        XCTAssertEqual(attachment.contentType, "image/png")
        XCTAssertEqual(attachment.byteSize, bytes.count)
        XCTAssertEqual(attachment.width, 32)
        XCTAssertEqual(attachment.height, 32)
        XCTAssertTrue(attachment.isImage)
        let mine = try await ada.client.attachmentData(id: attachment.id)
        XCTAssertEqual(mine, bytes, "the uploader reads back different bytes before sending")

        let sent = try await ada.client.send(
            conversationId: group.id, clientMsgId: clientMsgId(), content: "a picture", attachmentIds: [attachment.id])
        XCTAssertEqual(sent.attachments, [attachment])
        let arrived: Message = try await boLog.wait("message with the attachment on Bo's socket") {
            if case .message(let message) = $0, message.id == sent.id { return message }
            return nil
        }
        XCTAssertEqual(arrived.attachments, [attachment])
        let theirs = try await bo.client.attachmentData(id: attachment.id)
        XCTAssertEqual(theirs, bytes, "Bo downloads different bytes")
        let file = try await bo.client.attachmentFile(id: attachment.id)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), bytes, "the streamed download differs")

        // An empty body is refused with the server's own code.
        _ = await expectAPIError(400, "empty_file") {
            try await ada.client.upload(
                conversationId: group.id, data: Data(), fileName: "empty.png", contentType: "image/png",
                pixelSize: nil)
        }

        // A profile picture: set, read back, announced to everyone, cleared.
        let face = png(.systemOrange, side: 64)
        let updated = try await bo.client.setMyAvatar(data: face, contentType: "image/png")
        let avatarId = try XCTUnwrap(updated.avatarId, "setMyAvatar returned a person with no avatar_id")
        XCTAssertEqual(updated.id, bo.id)
        let back = try await bo.client.avatarData(kind: .people, ownerId: bo.id, avatarId: avatarId)
        XCTAssertEqual(back, face)
        let viaAda = try await ada.client.avatarData(kind: .people, ownerId: bo.id, avatarId: avatarId)
        XCTAssertEqual(viaAda, face)
        let announced: Person = try await adaLog.wait("person_updated for Bo's picture on Ada's socket") {
            if case .personUpdated(let person) = $0, person.id == bo.id, person.avatarId == avatarId { return person }
            return nil
        }
        XCTAssertEqual(announced, updated)
        let roster = try await ada.client.people()
        XCTAssertEqual(roster.first { $0.id == bo.id }?.avatarId, avatarId)

        // A group picture, members only.
        let badge = png(.systemPurple, side: 64)
        let withImage = try await ada.client.setConversationImage(
            conversationId: group.id, data: badge, contentType: "image/png")
        let imageId = try XCTUnwrap(withImage.avatarId, "the group has no avatar_id after setConversationImage")
        let groupBack = try await bo.client.avatarData(kind: .conversations, ownerId: group.id, avatarId: imageId)
        XCTAssertEqual(groupBack, badge)
        let cleared = try await ada.client.clearConversationImage(conversationId: group.id)
        XCTAssertNil(cleared.avatarId)

        // Leave the roster as found: Bo with no picture.
        let bare = try await bo.client.clearMyAvatar()
        XCTAssertNil(bare.avatarId)

        assertNothingUndecodable(adaLog, "Ada")
        assertNothingUndecodable(boLog, "Bo")
    }

    // MARK: - f. A socket that was away catches up

    func testASocketThatWasAwayReplaysTheMessagesItMissed() async throws {
        let (ada, bo) = try await signIn()
        _ = try await openSocket(ada)
        let first = try await openSocket(bo)
        let group = try await ada.client.createGroup(title: "Live sync \(tag())", personIds: [bo.id])
        let before = try await ada.client.send(
            conversationId: group.id, clientMsgId: clientMsgId(), content: "before the drop")
        let cursor: String = try await first.wait("the last message Bo saw") {
            if case .message(let message) = $0, message.id == before.id { return message.id }
            return nil
        }

        // Bo's socket goes away; two messages are sent meanwhile.
        first.socket?.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        let missed1 = try await ada.client.send(
            conversationId: group.id, clientMsgId: clientMsgId(), content: "missed one")
        let missed2 = try await ada.client.send(
            conversationId: group.id, clientMsgId: clientMsgId(), content: "missed two")

        // Bo reconnects and syncs from his cursor, as the store does on connect.
        let second = try await openSocket(bo)
        second.socket?.send(["type": "sync", "since_message_id": cursor])
        let partial: Bool = try await second.wait("sync_complete") {
            if case .syncComplete(let isPartial) = $0 { return isPartial }
            return nil
        }
        XCTAssertFalse(partial)
        let replayed = second.frames.flatMap { frame -> [Message] in
            if case .syncBatch(let messages) = frame { return messages }
            return []
        }
        XCTAssertEqual(
            replayed.filter { $0.conversationId == group.id }.map(\.id), [missed1.id, missed2.id],
            "the replay must carry exactly the two missed messages, oldest first")
        XCTAssertEqual(replayed.first { $0.id == missed2.id }?.content, "missed two")
        XCTAssertFalse(replayed.contains { $0.id == before.id }, "the replay repeated a message before the cursor")
        assertNothingUndecodable(second, "Bo")
    }

    // MARK: - g. MCP keys and members

    func testMcpKeysAreListedCreatedAndRevokedAndANewPersonGetsAKey() async throws {
        let (ada, bo) = try await signIn()

        // MCP keys: yours only, shown once, revoked in place.
        let label = "live \(tag())"
        let minted = try await bo.client.createMcpKey(label: label)
        XCTAssertEqual(minted.label, label)
        XCTAssertFalse(minted.id.isEmpty)
        XCTAssertTrue(minted.key.hasPrefix("hq_"))
        let listed = try await bo.client.mcpKeys()
        let row = try XCTUnwrap(listed.first { $0.id == minted.id }, "the new MCP key is not in Bo's list")
        XCTAssertEqual(row.label, label)
        XCTAssertEqual(row.scopes, "read,send")
        XCTAssertNil(row.revokedAt)
        let adaSees = try await ada.client.mcpKeys()
        XCTAssertFalse(adaSees.contains { $0.id == minted.id }, "Ada's list shows Bo's key")
        try await bo.client.revokeMcpKey(id: minted.id)
        let afterRevoke = try await bo.client.mcpKeys()
        XCTAssertNotNil(afterRevoke.first { $0.id == minted.id }?.revokedAt, "a revoked key must read as revoked")
        _ = await expectAPIError(400, "scope_unsupported") {
            try await bo.client.createMcpKey(label: "bad scope", scopes: ["admin"])
        }

        // A new teammate: the admin mints a key, the key signs them in.
        let letters = "abcdefghijklmnopqrstuvwxyz"
        let newName = "Guest" + String((0..<6).map { _ in letters.randomElement()! })
        let key = try await ada.client.mintKey(personName: newName)
        XCTAssertTrue(key.ok)
        XCTAssertEqual(key.personName, newName)
        XCTAssertTrue(key.key.hasPrefix("hq_"))
        let guest = Who(response: try await HQClient.enroll(
            key: key.key, personName: nil, deviceName: "LiveServerTests Guest"))
        XCTAssertEqual(guest.person.name, newName)
        XCTAssertFalse(guest.person.isAdmin)

        // An existing name is the operator's job, and the app says so.
        let exists = await expectAPIError(409, "person_exists") {
            try await ada.client.mintKey(personName: "Bo")
        }
        XCTAssertEqual(
            exists?.errorDescription,
            "They already have an account. Ask your server admin to run `bun hq invite <handle>`.")
        // A member cannot mint at all.
        let memberDenied = await expectAPIError(403, "admin_only") {
            try await bo.client.mintKey(personName: "Nobody" + self.tag())
        }
        XCTAssertEqual(memberDenied?.errorDescription, "Only an admin can change this.")

        // Members: promote, demote, remove (freezes), and the frozen device stops.
        let promoted = try await ada.client.setPersonRole(id: guest.id, isAdmin: true)
        XCTAssertTrue(promoted.isAdmin)
        let demoted = try await ada.client.setPersonRole(id: guest.id, isAdmin: false)
        XCTAssertFalse(demoted.isAdmin)
        let removed = try await ada.client.removePerson(id: guest.id)
        XCTAssertNotNil(removed.removedAt)
        XCTAssertTrue(removed.isRemoved)
        let frozen = await expectAPIError(401, "unauthorized") { try await guest.client.people() }
        XCTAssertNotNil(frozen)
        let adaPeople = try await ada.client.people()
        XCTAssertEqual(adaPeople.first { $0.id == guest.id }?.removedAt, removed.removedAt)
        let myself = await expectAPIError(409, "not_yourself") { try await ada.client.removePerson(id: ada.id) }
        XCTAssertNotNil(myself)
    }

    // MARK: - h. The store, end to end

    func testTheStoreEnrollsRefreshesAndHearsTheSocket() async throws {
        let (ada, bo) = try await signIn()
        // `AppStore.enroll` writes the host app's own Keychain item (keyed by this server);
        // put back whatever was there.
        let priorSession = Keychain.load()
        defer {
            if let priorSession { Keychain.save(priorSession) } else { Keychain.clear() }
        }

        let store = AppStore()
        await store.enroll(server: live.server, key: live.keyA, personName: "")
        XCTAssertNil(store.enrollmentError)
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.me?.name, ada.person.name)
        XCTAssertEqual(store.me?.id, ada.id)
        XCTAssertEqual(HQConfig.savedServer, live.server)
        XCTAssertNotNil(Keychain.load(), "the session did not reach the Keychain")

        await store.refresh()
        XCTAssertEqual(store.people[ada.id]?.name, ada.person.name)
        XCTAssertEqual(store.people[bo.id]?.name, bo.person.name)
        XCTAssertFalse(store.conversations.isEmpty)
        let room = try XCTUnwrap(store.conversations.first { $0.roomSlug != nil }, "the store has no standing room")
        XCTAssertTrue(store.calls.isEmpty)
        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertNil(store.enrollmentError)
        XCTAssertNil(store.callError)
        XCTAssertNil(store.taskMutationError)
        let retry = await store.didRunRefreshRetry(deviceId: ada.response.deviceId)
        XCTAssertFalse(retry, "a full refresh failed (its retry was pending)")

        // The store's own socket goes live and hears a message another person sends.
        let deadline = Date().addingTimeInterval(10)
        while !store.isSocketLive, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(store.isSocketLive, "the store's socket never went live")
        let hello = "store hears \(tag())"
        let sent = try await bo.client.send(conversationId: room.id, clientMsgId: clientMsgId(), content: hello)
        let heard = Date().addingTimeInterval(10)
        while !store.messages(in: room.id).contains(where: { $0.id == sent.id }), Date() < heard {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(store.messages(in: room.id).first { $0.id == sent.id }?.content, hello)

        // Typing from Bo shows up in the store.
        let boLog = try await openSocket(bo)
        boLog.socket?.send(["type": "typing", "conversation_id": room.id])
        let typingBy = Date().addingTimeInterval(10)
        while store.typingByConversation[room.id]?[bo.id] == nil, Date() < typingBy {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(store.typingByConversation[room.id]?[bo.id], "Bo's typing never reached the store")

        store.signOut()
        XCTAssertNil(store.session)
        XCTAssertEqual(store.phase, .enrolling)
    }
}

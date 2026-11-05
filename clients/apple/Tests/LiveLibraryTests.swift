import AppKit
import XCTest

@testable import HQ

/// The Library (docs and files) and scheduled meetings, through the app's real
/// networking against a real HQ Community server: `HQClient` and `EventSocket`,
/// no fixtures and no mocks. Modelled on `LiveServerTests`, and run the same
/// way:
///
///     HQ_LIVE_SERVER   the server's address, e.g. http://127.0.0.1:18790
///     HQ_LIVE_KEY_A    an invite key for an admin named Ada
///     HQ_LIVE_KEY_B    an invite key for a member named Bo
///
/// Skipped unless all three are set. Run against a throwaway database: the tests
/// write a doc, send files and make meetings, and meetings are cancelled again.
@MainActor
final class LiveLibraryTests: XCTestCase {
    // MARK: - Setup

    private struct Live {
        let server: String
        let keyA: String
        let keyB: String
    }

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
        if live != nil { HQConfig.savedServer = previousServer }
    }

    private func signIn() async throws -> (ada: Who, bo: Who) {
        if let known = Self.signedIn { return known }
        let ada = Who(response: try await HQClient.enroll(
            key: live.keyA, personName: nil, deviceName: "LiveLibraryTests Ada"))
        let bo = Who(response: try await HQClient.enroll(
            key: live.keyB, personName: nil, deviceName: "LiveLibraryTests Bo"))
        Self.signedIn = (ada, bo)
        return (ada, bo)
    }

    private func tag() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
    }

    private func clientMsgId() -> String { UUID().uuidString.lowercased() }

    private func expectAPIError<T>(
        _ status: Int, _ code: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> T
    ) async {
        do {
            _ = try await body()
            XCTFail("expected \(status) \(code), but the call succeeded", file: file, line: line)
        } catch let error as APIError {
            XCTAssertEqual(error.status, status, file: file, line: line)
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("expected APIError \(code), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Sockets

    @MainActor
    private final class FrameLog {
        private(set) var frames: [ServerFrame] = []

        func record(_ frame: ServerFrame) { frames.append(frame) }

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
            XCTFail("no \(what) within \(Int(timeout))s", file: file, line: line)
            throw Timeout(description: what)
        }
    }

    private func openSocket(_ who: Who) async throws -> FrameLog {
        let log = FrameLog()
        let socket = EventSocket(bearer: who.response.bearer, onConnect: {}, onFrame: { log.record($0) })
        sockets.append(socket)
        socket.connect()
        _ = try await log.wait("hello for \(who.person.name)") { (frame: ServerFrame) -> Bool? in
            if case .hello = frame { return true }
            return nil
        }
        return log
    }

    // MARK: - Docs

    /// Writes a doc the way an agent connected over MCP does: the app has no call that writes one.
    private func writeDoc(_ who: Who, slug: String, title: String, body: String) async throws {
        let url = try XCTUnwrap(HQConfig.url(path: "/mcp"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(who.response.bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let call: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "write_doc", "arguments": ["slug": slug, "title": title, "body": body]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: call)
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(answer["result"] as? [String: Any], "write_doc answered \(answer)")
        XCTAssertEqual(result["isError"] as? Bool, false, "write_doc failed: \(result)")
    }

    func testADocIsListedAndOpenedAndTheLibraryHasNoFolders() async throws {
        let (ada, bo) = try await signIn()
        let slug = "live-doc-\(tag())"
        let title = "Live doc \(tag())"
        let body = "# Plan\n\nWritten by the live test \(tag())."
        try await writeDoc(ada, slug: slug, title: title, body: body)

        let listed = try await bo.client.documents()
        let summary = try XCTUnwrap(listed.first { $0.slug == slug }, "the new doc is not in Bo's list")
        XCTAssertEqual(summary.title, title)
        XCTAssertEqual(summary.updatedByName, ada.person.name)
        XCTAssertNil(summary.folderId)
        XCTAssertEqual(listed.first?.slug, slug, "the newest doc is not first")

        let opened = try await bo.client.document(slug: slug)
        XCTAssertEqual(opened.slug, slug)
        XCTAssertEqual(opened.title, title)
        XCTAssertEqual(opened.content, body)
        XCTAssertEqual(opened.updatedByName, ada.person.name)

        let folders = try await bo.client.library()
        XCTAssertTrue(folders.isEmpty)
        await expectAPIError(404, "doc not found") { try await bo.client.document(slug: "no-such-doc-\(tag())") }
    }

    // MARK: - Files

    func testAFileSentInChatIsListedForAMemberAndNotForAPersonOutsideTheConversation() async throws {
        let (ada, bo) = try await signIn()
        let people = try await ada.client.people()
        let assistant = try XCTUnwrap(people.first { $0.kind == "bot" }, "the built-in assistant is not on the roster")

        // One group with Bo, and one that Bo is not in.
        let shared = try await ada.client.createGroup(title: "Live shared \(tag())", personIds: [bo.id])
        let closed = try await ada.client.createGroup(title: "Live closed \(tag())", personIds: [assistant.id])
        XCTAssertFalse(closed.memberIds.contains(bo.id))

        func send(_ conversationId: String, name: String, text: String) async throws -> Attachment {
            let attachment = try await ada.client.upload(
                conversationId: conversationId, data: Data(text.utf8), fileName: name, contentType: "text/plain",
                pixelSize: nil)
            _ = try await ada.client.send(
                conversationId: conversationId, clientMsgId: clientMsgId(), content: "sharing \(name)",
                attachmentIds: [attachment.id])
            return attachment
        }
        let seenName = "seen-\(tag()).txt"
        let hiddenName = "hidden-\(tag()).txt"
        let draftName = "draft-\(tag()).txt"
        let seen = try await send(shared.id, name: seenName, text: "for the group")
        let hidden = try await send(closed.id, name: hiddenName, text: "not for Bo")
        // An upload that no message holds is not a file in the room yet.
        let draft = try await ada.client.upload(
            conversationId: shared.id, data: Data("draft".utf8), fileName: draftName, contentType: "text/plain",
            pixelSize: nil)

        let boFiles = try await bo.client.files()
        let found = try XCTUnwrap(boFiles.first { $0.id == seen.id }, "Bo does not see the file sent to the group he is in")
        XCTAssertEqual(found.fileName, seenName)
        XCTAssertEqual(found.contentType, "text/plain")
        XCTAssertEqual(found.byteSize, "for the group".utf8.count)
        XCTAssertEqual(found.conversationId, shared.id)
        XCTAssertEqual(found.conversationTitle, shared.title)
        XCTAssertEqual(found.uploaderName, ada.person.name)
        XCTAssertNil(found.folderId)
        XCTAssertFalse(boFiles.contains { $0.id == hidden.id }, "Bo sees a file from a conversation he is not in")
        XCTAssertFalse(boFiles.contains { $0.id == draft.id }, "an upload nobody has sent is listed")
        XCTAssertFalse(boFiles.contains { $0.fileName == hiddenName })

        let adaFiles = try await ada.client.files()
        XCTAssertTrue(adaFiles.contains { $0.id == seen.id })
        XCTAssertTrue(adaFiles.contains { $0.id == hidden.id })
        XCTAssertFalse(adaFiles.contains { $0.id == draft.id })
        // The list opens with the same id the download uses.
        let bytes = try await bo.client.attachmentData(id: seen.id)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "for the group")
    }

    // MARK: - Meetings

    private func soon(_ hours: Double = 1) -> Date {
        // Whole seconds: the app sends none of the fraction.
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + hours * 3600).rounded())
    }

    func testAMeetingIsCreatedListedReInvitedAndCancelled() async throws {
        let (ada, bo) = try await signIn()
        let boLog = try await openSocket(bo)
        let title = "Live sync \(tag())"
        let when = soon()

        let made = try await ada.client.createMeeting(title: title, scheduledAt: when, inviteePersonIds: [bo.id])
        XCTAssertEqual(made.title, title)
        XCTAssertEqual(made.createdByPersonId, ada.id)
        XCTAssertEqual(Set(made.inviteePersonIds), [ada.id, bo.id])
        XCTAssertEqual(made.scheduledDate, when)
        XCTAssertNil(made.recurrence)
        XCTAssertNil(made.seriesId)
        XCTAssertFalse(made.isRecurring)
        let thread = try XCTUnwrap(made.conversationId, "the meeting has no thread")
        let room = try await bo.client.conversation(id: thread)
        XCTAssertTrue(room.memberIds.contains(bo.id), "an invitee is not in the meeting's thread")

        // In both people's snapshot of calls, and told to Bo on his socket.
        let adaCalls = try await ada.client.calls()
        XCTAssertTrue(adaCalls.calls.isEmpty)
        XCTAssertTrue(adaCalls.ringing.isEmpty)
        XCTAssertEqual(adaCalls.meetings.first { $0.id == made.id }, made)
        let boCalls = try await bo.client.calls()
        XCTAssertEqual(boCalls.meetings.first { $0.id == made.id }, made)
        let told: [Meeting] = try await boLog.wait("meetings frame with the new meeting on Bo's socket") {
            if case .meetings(let list) = $0, list.contains(where: { $0.id == made.id }) { return list }
            return nil
        }
        XCTAssertEqual(told.first { $0.id == made.id }, made)

        // Leave Bo out: he is uninvited, loses the thread, and his list drops it.
        let alone = try await ada.client.setMeetingInvitees(id: made.id, personIds: [])
        XCTAssertEqual(alone.inviteePersonIds, [ada.id], "the organizer must stay on the list")
        let boAfter = try await bo.client.calls()
        XCTAssertFalse(boAfter.meetings.contains { $0.id == made.id })
        _ = try await boLog.wait("meetings frame without the meeting on Bo's socket") {
            if case .meetings(let list) = $0, !list.contains(where: { $0.id == made.id }) { return true }
            return nil
        }
        let adaAfter = try await ada.client.calls()
        XCTAssertTrue(adaAfter.meetings.contains { $0.id == made.id })

        // Invite him again. He is on the list but not the organizer, so he cannot cancel it.
        let again = try await ada.client.setMeetingInvitees(id: made.id, personIds: [bo.id])
        XCTAssertEqual(Set(again.inviteePersonIds), [ada.id, bo.id])
        await expectAPIError(403, "forbidden") { try await bo.client.cancelMeeting(id: made.id) }
        await expectAPIError(403, "forbidden") {
            try await bo.client.setMeetingInvitees(id: made.id, personIds: [])
        }

        try await ada.client.cancelMeeting(id: made.id)
        let adaDone = try await ada.client.calls()
        let boDone = try await bo.client.calls()
        XCTAssertFalse(adaDone.meetings.contains { $0.id == made.id })
        XCTAssertFalse(boDone.meetings.contains { $0.id == made.id })
    }

    func testAnAdminCancelsAMembersMeetingAndOnlyRealPeopleAreInvited() async throws {
        let (ada, bo) = try await signIn()
        let made = try await bo.client.createMeeting(
            title: "Live bo \(tag())", scheduledAt: soon(2), inviteePersonIds: [ada.id])
        XCTAssertEqual(made.createdByPersonId, bo.id)
        let adaCalls = try await ada.client.calls()
        XCTAssertTrue(adaCalls.meetings.contains { $0.id == made.id })
        // Ada is an admin on a signed-in device: she may cancel Bo's meeting.
        try await ada.client.cancelMeeting(id: made.id)
        let boCalls = try await bo.client.calls()
        XCTAssertFalse(boCalls.meetings.contains { $0.id == made.id })

        await expectAPIError(404, "person_not_found") {
            try await ada.client.createMeeting(
                title: "Live nobody \(tag())", scheduledAt: soon(), inviteePersonIds: ["nobody"])
        }
        await expectAPIError(404, "meeting_not_found") { try await ada.client.cancelMeeting(id: "no-such-meeting") }
    }

    func testARepeatingMeetingSkipsToTheNextOneAndEndsForGood() async throws {
        let (ada, bo) = try await signIn()
        let when = soon()
        let rule = HQClient.RecurrenceBody(freq: "weekly", timezone: "UTC", weekdays: [])
        let first = try await ada.client.createMeeting(
            title: "Live standup \(tag())", scheduledAt: when, inviteePersonIds: [bo.id], recurrence: rule)
        let seriesId = try XCTUnwrap(first.seriesId, "a repeating meeting has no series id")
        XCTAssertTrue(first.isRecurring)
        XCTAssertTrue(try XCTUnwrap(first.recurrence).hasPrefix("Weekly on "), "recurrence is \(first.recurrence ?? "nil")")

        // Skipping this one puts the next up in its place, in the same thread, a week on.
        try await ada.client.cancelMeeting(id: first.id)
        let boCalls = try await bo.client.calls()
        let ofSeries = boCalls.meetings.filter { $0.seriesId == seriesId }
        XCTAssertEqual(ofSeries.count, 1, "exactly one occurrence should be ahead")
        let next = try XCTUnwrap(ofSeries.first)
        XCTAssertNotEqual(next.id, first.id)
        XCTAssertEqual(next.conversationId, first.conversationId)
        XCTAssertEqual(next.recurrence, first.recurrence)
        let gap = try XCTUnwrap(next.scheduledDate).timeIntervalSince(try XCTUnwrap(first.scheduledDate))
        XCTAssertEqual(gap, 7 * 86_400, accuracy: 1)
        XCTAssertEqual(Set(next.inviteePersonIds), [ada.id, bo.id])

        // Bo is invited, not the organizer: he cannot end it. Ada can, and nothing is left ahead.
        await expectAPIError(403, "forbidden") { try await bo.client.cancelMeetingSeries(id: seriesId) }
        try await ada.client.cancelMeetingSeries(id: seriesId)
        let adaDone = try await ada.client.calls()
        let boDone = try await bo.client.calls()
        XCTAssertFalse(adaDone.meetings.contains { $0.seriesId == seriesId })
        XCTAssertFalse(boDone.meetings.contains { $0.seriesId == seriesId })
    }
}

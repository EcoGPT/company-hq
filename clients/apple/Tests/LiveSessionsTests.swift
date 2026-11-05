import XCTest

@testable import HQ

/// Synced coding conversations, through the app's real networking against a real HQ
/// Community server. The Mac helper's side is a plain `URLSession` request with the
/// helper's body; everything the app reads goes through the real `HQClient`, with no
/// fixtures and no mocks. Modelled on `LiveServerTests`, and run the same way:
///
///     HQ_LIVE_SERVER   the server's address, e.g. http://127.0.0.1:18790
///     HQ_LIVE_KEY_A    an invite key for an admin named Ada
///     HQ_LIVE_KEY_B    an invite key for a member named Bo
///
/// Skipped unless all three are set. Run against a throwaway database: every run adds
/// conversations with ids no earlier run used, and archives some of them (nothing is
/// deleted).
@MainActor
final class LiveSessionsTests: XCTestCase {
    private struct Who {
        let response: HQClient.EnrollResponse
        var client: HQClient { HQClient(bearer: response.bearer) }
        var id: String { response.person.id }
    }

    /// What the thread view reads out of a transcript.
    private struct Transcript: Decodable {
        struct Entry: Decodable { let id: String; let role: String; let text: String }
        let messages: [Entry]
    }

    private var keyA: String!
    private var keyB: String!
    private var previousServer: String?

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
        self.keyA = keyA
        self.keyB = keyB
        previousServer = HQConfig.savedServer
        HQConfig.savedServer = normalized
    }

    override func tearDown() async throws {
        if keyA != nil { HQConfig.savedServer = previousServer }
    }

    // MARK: - Helpers

    private func signIn() async throws -> (ada: Who, bo: Who) {
        let ada = Who(response: try await HQClient.enroll(key: keyA, personName: nil, deviceName: "LiveSessionsTests Ada"))
        let bo = Who(response: try await HQClient.enroll(key: keyB, personName: nil, deviceName: "LiveSessionsTests Bo"))
        return (ada, bo)
    }

    private func tag() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
    }

    /// A made-up key of a shape the server hides, built here so no key-looking text sits in the source.
    private func fakeSecret(_ tag: String) -> String {
        "ghp_" + tag + String(repeating: "Zq7Lm2", count: 5)
    }

    /// One request as the helper makes it: JSON, the device bearer, its own user agent.
    private func send(_ method: String, _ path: String, as who: Who, json: Any? = nil) async throws
        -> (response: HTTPURLResponse, data: Data)
    {
        let url = try XCTUnwrap(HQConfig.url(path: path))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(who.response.bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("hq-session-sync/0.1", forHTTPHeaderField: "User-Agent")
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), data)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The helper's PUT body for a conversation of `text` messages.
    private func upload(baseRevision: Int, title: String, cwd: String, texts: [String]) -> [String: Any] {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let messages: [[String: Any]] = texts.enumerated().map { index, text in
            [
                "id": "m\(index + 1)", "role": index % 2 == 0 ? "user" : "assistant", "text": text,
                "timestamp": index == 0 ? stamp : NSNull(),
            ]
        }
        let snapshot: [String: Any] = [
            "projection": "conversation-text-v1", "title": title, "cwd": cwd, "git_branch": "live/branch",
            "task_ref": NSNull(), "messages": messages,
        ]
        return [
            "base_revision": baseRevision, "activity_at": Int(Date().timeIntervalSince1970 * 1000),
            "files_touched": ["src/live.swift"], "snapshot": snapshot,
        ]
    }

    private func expectAPIError<T>(
        _ status: Int, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T
    ) async {
        do {
            _ = try await body()
            XCTFail("expected HTTP \(status), but the call succeeded", file: file, line: line)
        } catch let error as APIError {
            XCTAssertEqual(error.status, status, file: file, line: line)
        } catch {
            XCTFail("expected an APIError with HTTP \(status), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Tests

    /// The whole path: the helper stores a conversation with a key in it, its owner sees it in
    /// her list, a teammate finds it on the board and opens it with the key hidden.
    func testASyncedConversationReachesTheBoardAndOpensForATeammateWithSecretsHidden() async throws {
        let (ada, bo) = try await signIn()
        let run = tag(), source = "live-\(run)", secret = fakeSecret(run)
        let folder = "/Users/ada/private-\(run)"

        let put = try await send(
            "PUT", "/v1/agent-sessions/claude/\(source)", as: ada,
            json: upload(baseRevision: 0, title: "Live \(run) with \(secret)", cwd: folder, texts: ["my key is \(secret), use it", "noted"]))
        XCTAssertEqual(put.response.statusCode, 200, String(decoding: put.data, as: UTF8.self))
        let receipt = try object(put.data)
        XCTAssertEqual(receipt["status"] as? String, "synced")
        let session = try XCTUnwrap(receipt["session"] as? [String: Any])
        let id = try XCTUnwrap(session["id"] as? String)
        let hash = try XCTUnwrap(session["sha256"] as? String)
        XCTAssertEqual(session["revision"] as? Int, 1)

        // Ada's own list (the call the task card and the helper make) has it.
        let mine = try await ada.client.codingSessions()
        let listed = try XCTUnwrap(mine.sessions.first { $0.id == id }, "the new conversation is not in Ada's list")
        XCTAssertEqual(listed.sourceId, source)
        XCTAssertEqual(listed.messageCount, 2)
        XCTAssertEqual(listed.revision, 1)
        XCTAssertEqual(listed.toolHistory, false)

        // The server tells the app a teammate may open it.
        let projects = try await bo.client.projects()
        XCTAssertTrue(projects.openTranscripts)

        // Bo's board page decodes, and shows it with the key hidden and Ada as its owner.
        let walk = await bo.client.walkActiveCodingThreads(sinceMinutes: 10)
        XCTAssertNil(walk.failure)
        let thread = try XCTUnwrap(walk.threads.first { $0.sessionId == id }, "the conversation is not on Bo's board")
        XCTAssertEqual(thread.ownerPersonId, ada.id)
        XCTAssertEqual(thread.provider, "claude")
        XCTAssertEqual(thread.gitBranch, "live/branch")
        XCTAssertTrue(thread.title?.contains("[REDACTED]") == true, "title: \(thread.title ?? "nil")")
        XCTAssertFalse(thread.title?.contains(secret) == true)

        // Bo opens the thread: it decodes, with the stored session as an app that asks sees it.
        let detail = try await bo.client.codingThread(id: id, openTranscripts: true)
        XCTAssertEqual(detail.thread.sessionId, id)
        let opened = try XCTUnwrap(detail.session)
        XCTAssertEqual(opened.id, id)
        XCTAssertEqual(opened.revision, 1)
        XCTAssertEqual(opened.messageCount, 2)
        // Without ?open=1 the server answers the same: any member may open it.
        let plain = try await bo.client.codingThread(id: id, openTranscripts: false)
        let unasked = try XCTUnwrap(plain.session)
        XCTAssertEqual(unasked.id, opened.id)
        XCTAssertEqual(unasked.revision, opened.revision)

        // Bo reads the conversation: the key is hidden, there is no working folder and no hash.
        let theirs = try await send("GET", "/v1/agent-sessions/by-id/\(id)/transcript", as: bo)
        XCTAssertEqual(theirs.response.statusCode, 200)
        XCTAssertNil(theirs.response.value(forHTTPHeaderField: "X-HQ-Snapshot-Sha256"))
        XCTAssertEqual(theirs.response.value(forHTTPHeaderField: "X-HQ-Revision"), "1")
        let theirText = String(decoding: theirs.data, as: UTF8.self)
        XCTAssertFalse(theirText.contains(secret), "Bo can read the key")
        XCTAssertFalse(theirText.contains(folder), "Bo can read Ada's folder")
        XCTAssertNil(try object(theirs.data)["cwd"])
        let read = try JSONDecoder().decode(Transcript.self, from: theirs.data)
        XCTAssertEqual(read.messages.map(\.id), ["m1", "m2"])
        XCTAssertTrue(read.messages[0].text.contains("[REDACTED]"))
        XCTAssertEqual(read.messages[1].text, "noted")

        // Ada reads her own as it was stored.
        let own = try await send("GET", "/v1/agent-sessions/by-id/\(id)/transcript", as: ada)
        XCTAssertEqual(own.response.statusCode, 200)
        XCTAssertEqual(own.response.value(forHTTPHeaderField: "X-HQ-Snapshot-Sha256"), hash)
        let ownText = String(decoding: own.data, as: UTF8.self)
        XCTAssertTrue(ownText.contains(secret), "Ada's own copy lost the key")
        XCTAssertEqual(try object(own.data)["cwd"] as? String, folder)
        let byIdentity = try await send("GET", "/v1/agent-sessions/claude/\(source)/transcript", as: ada)
        XCTAssertEqual(byIdentity.data, own.data)
    }

    /// What keeps a conversation its owner's to change, and lets her take it off the board.
    func testOnlyTheOwnerWritesAndAnArchivedConversationLeavesTheBoard() async throws {
        let (ada, bo) = try await signIn()
        let run = tag(), source = "live-\(run)"
        let first = try await send(
            "PUT", "/v1/agent-sessions/claude/\(source)", as: ada,
            json: upload(baseRevision: 0, title: "Archive \(run)", cwd: "/work/\(run)", texts: ["hello"]))
        let firstSession = try XCTUnwrap(try object(first.data)["session"] as? [String: Any])
        let sessionId = try XCTUnwrap(firstSession["id"] as? String)

        // A stale revision is a conflict and changes nothing.
        let stale = try await send(
            "PUT", "/v1/agent-sessions/claude/\(source)", as: ada,
            json: upload(baseRevision: 0, title: "Archive \(run)", cwd: "/work/\(run)", texts: ["hello", "again"]))
        XCTAssertEqual(stale.response.statusCode, 409)
        XCTAssertEqual(try object(stale.data)["error"] as? String, "revision_conflict")

        // The owner's routes are the owner's: Bo has no such conversation, and his own PUT is his own row.
        let notBos = try await send("GET", "/v1/agent-sessions/claude/\(source)", as: bo)
        XCTAssertEqual(notBos.response.statusCode, 404)
        let bos = try await send(
            "PUT", "/v1/agent-sessions/claude/\(source)", as: bo,
            json: upload(baseRevision: 0, title: "Bo \(run)", cwd: "/work/bo", texts: ["mine"]))
        XCTAssertEqual(bos.response.statusCode, 200)
        let bosSession = try XCTUnwrap(try object(bos.data)["session"] as? [String: Any])
        XCTAssertNotEqual(bosSession["id"] as? String, sessionId)

        let before = await bo.client.walkActiveCodingThreads(sinceMinutes: 10)
        XCTAssertTrue(before.threads.contains { $0.sessionId == sessionId })

        // Archived, it leaves the board, Ada's list and Bo's reach; Ada still opens it.
        let archived = try await send("PUT", "/v1/agent-sessions/claude/\(source)/archive", as: ada, json: ["archived": true])
        XCTAssertEqual(archived.response.statusCode, 200)
        let after = await bo.client.walkActiveCodingThreads(sinceMinutes: 10)
        XCTAssertNil(after.failure)
        XCTAssertFalse(after.threads.contains { $0.sessionId == sessionId })
        await expectAPIError(404) { try await bo.client.codingThread(id: sessionId, openTranscripts: true) }
        let hidden = try await send("GET", "/v1/agent-sessions/by-id/\(sessionId)/transcript", as: bo)
        XCTAssertEqual(hidden.response.statusCode, 404)
        let mine = try await ada.client.codingSessions()
        XCTAssertFalse(mine.sessions.contains { $0.id == sessionId })
        let still = try await ada.client.codingThread(id: sessionId, openTranscripts: true)
        XCTAssertEqual(still.thread.sessionId, sessionId)
    }
}

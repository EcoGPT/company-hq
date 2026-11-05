import XCTest

@testable import HQ

/// Session sync against a real HQ Community server: the helper's real `SyncTransport`
/// (compiled into this bundle from `Sources/SessionSyncAgent`) uploads as one person, and
/// another person opens the conversation through the app's real `HQClient`. No fixtures,
/// no mocks. Uses the same variables as `LiveServerTests` and is skipped unless all three
/// are set:
///
///     HQ_LIVE_SERVER   the server's address, e.g. http://127.0.0.1:18790
///     HQ_LIVE_KEY_A    an invite key for an admin named Ada (she syncs)
///     HQ_LIVE_KEY_B    an invite key for a member named Bo (he reads)
///
/// Every secret here is built at run time. Use a throwaway database: each run adds sessions.
/// The helper only sends to `https://` or to this Mac, so a plain-http server must be on
/// localhost; anything else skips.
@MainActor
final class LiveSessionSyncTests: XCTestCase {
    private var server = ""
    private var keyA = ""
    private var keyB = ""
    private var previousServer: String?
    private let scratch = Scratch()

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        func value(_ name: String) -> String? {
            let text = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        guard let address = value("HQ_LIVE_SERVER"), let a = value("HQ_LIVE_KEY_A"), let b = value("HQ_LIVE_KEY_B")
        else { throw XCTSkip("HQ_LIVE_SERVER, HQ_LIVE_KEY_A and HQ_LIVE_KEY_B are not all set") }
        guard case .success(let normalized) = HQConfig.normalizedServer(address) else {
            throw XCTSkip("HQ_LIVE_SERVER is not a usable server address")
        }
        guard SyncTransport.allowed(normalized) else {
            throw XCTSkip("the helper sends only to https:// or to localhost")
        }
        (server, keyA, keyB) = (normalized, a, b)
        previousServer = HQConfig.savedServer
        HQConfig.savedServer = normalized
    }

    override func tearDown() async throws {
        if !server.isEmpty { HQConfig.savedServer = previousServer }
    }

    private func randomSecret() -> String {
        "ghp_" + String((0..<36).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }

    private func transport(bearer: String, person: String) throws -> SyncTransport {
        let config = SessionSyncConfig(enabled: true, personID: person, baseURL: server, sources: []).acceptingRules()
        return try SyncTransport(config: config, token: bearer, scopeCheck: { true })
    }

    /// Ada's session as the server holds it: `id`, `message_count`, `revision`.
    private func session(_ transport: SyncTransport, _ id: String) async throws -> [String: Any] {
        let reply = try await transport.request("GET", "/v1/agent-sessions/claude/\(id)")
        return try XCTUnwrap(reply?["session"] as? [String: Any])
    }

    /// A conversation on Ada's Mac holding a secret, synced by the helper's collector and
    /// transport. The helper hides the secret before upload, so it never reaches the server;
    /// Bo opens the conversation and reads the text without it.
    func testAConversationSyncedByTheHelperIsReadByAnotherPersonWithTheSecretHidden() async throws {
        let ada = try await HQClient.enroll(key: keyA, personName: nil, deviceName: "LiveSessionSyncTests Ada")
        let bo = try await HQClient.enroll(key: keyB, personName: nil, deviceName: "LiveSessionSyncTests Bo")
        let secret = randomSecret()
        let id = UUID().uuidString.lowercased()
        let claude = try scratch.folder(".claude")
        let work = try scratch.folder("work").path
        try scratch.writeLines(
            [
                claudeRow("u1", "user", "Please use \(secret) to deploy", session: id, cwd: work),
                claudeRow("a1", "assistant", [["type": "text", "text": "Deployed"]], session: id, cwd: work),
            ], to: try scratch.folder(".claude/projects/p").appendingPathComponent(id + ".jsonl"))
        let source = SessionSyncSource(provider: "claude", path: claude.path)
        let candidate = try XCTUnwrap(SessionCollector.discover(source).first { $0.id == id })

        let transport = try transport(bearer: ada.bearer, person: ada.person.id)
        defer { transport.close() }
        _ = try await transport.sync(candidate)  // uploads, then reads the transcript back and compares it

        let held = try await session(transport, id)
        XCTAssertEqual(held["message_count"] as? Int, 2)
        let ownReply = try await transport.request("GET", "/v1/agent-sessions/claude/\(id)/transcript")
        let own = try XCTUnwrap(ownReply)
        let ownTexts = (own["messages"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        XCTAssertEqual(ownTexts, ["Please use [REDACTED] to deploy", "Deployed"], "the helper hid the secret before it left")

        let threadId = try XCTUnwrap(held["id"] as? String)
        let client = HQClient(bearer: bo.bearer)
        let detail = try await client.codingThread(id: threadId, openTranscripts: true)
        XCTAssertEqual(detail.thread.ownerPersonId, ada.person.id)
        XCTAssertNotNil(detail.session, "another member may open the conversation")
        let transcript = try await client.codingTranscript(id: threadId)
        XCTAssertEqual(transcript.messages.map(\.text), ["Please use [REDACTED] to deploy", "Deployed"])
        XCTAssertEqual(transcript.messages.map(\.role), ["user", "assistant"])
        XCTAssertFalse(String(describing: transcript).contains(secret))
    }

    /// A secret the helper did not catch is still hidden from everyone but its owner: Ada
    /// sends text with a secret straight through the real transport, she reads it back as it
    /// was stored, and Bo's read has it hidden.
    func testTheServerHidesASecretFromEveryoneButItsOwner() async throws {
        let ada = try await HQClient.enroll(key: keyA, personName: nil, deviceName: "LiveSessionSyncTests Ada")
        let bo = try await HQClient.enroll(key: keyB, personName: nil, deviceName: "LiveSessionSyncTests Bo")
        let secret = randomSecret()
        let id = UUID().uuidString.lowercased()
        let snapshot = SyncSnapshot(
            title: "Deploy", cwd: "/work", branch: nil,
            messages: [SyncMessage(id: "m1", role: "user", text: "the token is \(secret)", timestamp: nil)])
        let transport = try transport(bearer: ada.bearer, person: ada.person.id)
        defer { transport.close() }
        let reply = try await transport.request(
            "PUT", "/v1/agent-sessions/claude/\(id)",
            body: ["base_revision": 0, "snapshot": snapshot.json, "files_touched": [String]()])
        XCTAssertEqual((reply?["session"] as? [String: Any])?["sha256"] as? String, try snapshot.hash)

        let ownReply = try await transport.request("GET", "/v1/agent-sessions/claude/\(id)/transcript")
        let own = try XCTUnwrap(ownReply)
        let ownTexts = (own["messages"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        XCTAssertEqual(ownTexts, ["the token is \(secret)"], "its owner reads what was stored")

        let held = try await session(transport, id)
        let threadId = try XCTUnwrap(held["id"] as? String)
        let transcript = try await HQClient(bearer: bo.bearer).codingTranscript(id: threadId)
        XCTAssertEqual(transcript.messages.map(\.text), ["the token is [REDACTED]"])
    }
}

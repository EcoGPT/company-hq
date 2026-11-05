import CryptoKit
import Foundation
import XCTest

/// The helper's conversation with the server, against a fake that keeps what it is sent
/// the way the real routes do (revisions, the canonical hash, the small activity route).
final class TransportTests: XCTestCase {
  let scratch = Scratch()
  let base = "http://127.0.0.1:8797"
  var log: URL!
  var work: String!
  var source: SessionSyncSource!

  override func setUpWithError() throws {
    let claude = try scratch.folder(".claude")
    log = try scratch.folder(".claude/projects/p").appendingPathComponent("thread.jsonl")
    _ = try scratch.folder("work/.git")
    work = scratch.root.appendingPathComponent("work").path
    source = SessionSyncSource(provider: "claude", path: claude.path)
    FakeServer.reset()
    SessionCollector.transcripts.removeAll()
  }

  // MARK: Helpers

  private func chat(_ texts: [String], extra: [[String: Any]] = []) throws {
    var rows = texts.enumerated().map {
      claudeRow("m\($0.offset)", $0.offset % 2 == 0 ? "user" : "assistant", $0.element, cwd: work)
    }
    rows += extra
    try scratch.writeLines(rows, to: log)
  }

  private func candidate() throws -> SyncCandidate {
    let found = try SessionCollector.discover(source)
    XCTAssertEqual(found.count, 1)
    return found[0]
  }

  private func transport(scope: Bool = true, base: String? = nil) throws -> SyncTransport {
    let config = SessionSyncConfig(
      enabled: true, personID: "ada", baseURL: base ?? self.base, sources: [source]).acceptingRules()
    let settings = URLSessionConfiguration.ephemeral
    settings.protocolClasses = [FakeServer.self]
    return try SyncTransport(config: config, token: "fixture-bearer", settings: settings, scopeCheck: { scope })
  }

  private var methodsAndPaths: [String] { FakeServer.calls.map { "\($0.method) \($0.path)" } }

  // MARK: Uploads

  func testAFirstUploadAsksThenSendsThenReadsBack() async throws {
    try chat(["Question", "Answer"])
    let transport = try transport()
    defer { transport.close() }
    _ = try await transport.sync(try candidate())
    XCTAssertEqual(
      methodsAndPaths,
      ["GET /v1/agent-sessions/claude/thread", "PUT /v1/agent-sessions/claude/thread",
       "GET /v1/agent-sessions/claude/thread/transcript"])
    let put = try XCTUnwrap(FakeServer.calls.first { $0.method == "PUT" })
    XCTAssertEqual(put.body?["base_revision"] as? Int, 0)
    XCTAssertEqual(Set(put.body?.keys.map { $0 } ?? []), ["base_revision", "snapshot", "files_touched", "activity_at"])
    XCTAssertTrue(FakeServer.calls.allSatisfy { $0.bearer == "Bearer fixture-bearer" && $0.host == "127.0.0.1" })
    XCTAssertEqual(FakeServer.sessions["claude/thread"]?.snapshot["title"] as? String, "Question")
  }

  func testAnUnchangedChatAsksNothing() async throws {
    try chat(["Question", "Answer"])
    let transport = try transport()
    defer { transport.close() }
    let acknowledged = try await transport.sync(try candidate())
    FakeServer.calls = []
    let again = try await transport.sync(try candidate(), acknowledged: acknowledged)
    XCTAssertEqual(again, acknowledged)
    XCTAssertEqual(FakeServer.calls.count, 0)
  }

  func testNewTextSendsTheSnapshotOnTheRevisionItSaw() async throws {
    try chat(["Question", "Answer"])
    let transport = try transport()
    defer { transport.close() }
    let acknowledged = try await transport.sync(try candidate())
    FakeServer.calls = []
    try chat(["Question", "Answer", "Follow-up"])
    _ = try await transport.sync(try candidate(), acknowledged: acknowledged)
    let put = try XCTUnwrap(FakeServer.calls.first { $0.method == "PUT" })
    XCTAssertEqual(put.path, "/v1/agent-sessions/claude/thread")
    XCTAssertEqual(put.body?["base_revision"] as? Int, 1)
    XCTAssertEqual(FakeServer.sessions["claude/thread"]?.revision, 2)
  }

  func testOnlyANewerActivityTimeGoesToTheSmallRoute() async throws {
    try chat(["Question", "Answer"])
    let transport = try transport()
    defer { transport.close() }
    let acknowledged = try await transport.sync(try candidate())
    FakeServer.calls = []
    try chat(["Question", "Answer"], extra: [["sessionId": "thread", "type": "progress", "timestamp": "2026-10-20T12:05:00.000Z"]])
    _ = try await transport.sync(try candidate(), acknowledged: acknowledged)
    XCTAssertEqual(methodsAndPaths, ["GET /v1/agent-sessions/claude/thread", "PUT /v1/agent-sessions/claude/thread/activity"])
    XCTAssertEqual(Set(FakeServer.calls[1].body?.keys.map { $0 } ?? []), ["sha256", "files_touched", "activity_at"])
    XCTAssertEqual(FakeServer.sessions["claude/thread"]?.revision, 1, "no new revision")
  }

  func testASecretIsNeverInAnythingSent() async throws {
    let token = "ghp_" + String((0..<36).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    try chat(["here is \(token) for you", "ok"])
    let transport = try transport()
    defer { transport.close() }
    _ = try await transport.sync(try candidate())
    for call in FakeServer.calls {
      let body = call.body.map { String(decoding: (try? syncJSON($0)) ?? Data(), as: UTF8.self) } ?? ""
      XCTAssertFalse(body.contains(token), "\(call.method) \(call.path)")
    }
    let stored = FakeServer.sessions["claude/thread"]?.snapshot["messages"] as? [[String: Any]]
    XCTAssertEqual(stored?.first?["text"] as? String, "here is [REDACTED] for you")
  }

  // MARK: Checks that stop an acknowledgement

  func testARevisionConflictIsNotAcknowledged() async throws {
    try chat(["Question", "Answer"])
    let transport = try transport()
    defer { transport.close() }
    FakeServer.conflict = true
    do {
      _ = try await transport.sync(try candidate())
      XCTFail("a 409 must throw")
    } catch let error as SyncTransportError {
      XCTAssertEqual(error, .http(409))
    }
    FakeServer.conflict = false
    _ = try await transport.sync(try candidate())
    XCTAssertEqual(FakeServer.sessions["claude/thread"]?.revision, 1)
  }

  func testACorruptReadbackIsNotAcknowledged() async throws {
    try chat(["Question", "Answer"])
    let transport = try transport()
    defer { transport.close() }
    FakeServer.corruptReadback = true
    do {
      _ = try await transport.sync(try candidate())
      XCTFail("a readback that differs must throw")
    } catch SyncFailure.receipt {}
  }

  func testAVerbatimReceiptNeedsNoReadback() async throws {
    try chat(["Question", "Answer"])
    let transport = try transport()
    defer { transport.close() }
    FakeServer.verbatim = true
    _ = try await transport.sync(try candidate())
    XCTAssertEqual(methodsAndPaths, ["GET /v1/agent-sessions/claude/thread", "PUT /v1/agent-sessions/claude/thread"])
  }

  func testASignOutOrPauseStopsTheUploadBeforeItIsSent() async throws {
    try chat(["Question", "Answer"])
    let transport = try transport(scope: false)
    defer { transport.close() }
    do {
      _ = try await transport.sync(try candidate())
      XCTFail("a disabled scope must not upload")
    } catch SyncFailure.scope {}
    XCTAssertFalse(methodsAndPaths.contains { $0.hasPrefix("PUT") })
  }

  func testAnOutageIsAnErrorNotAnAcknowledgement() async throws {
    try chat(["Question", "Answer"])
    let transport = try transport()
    defer { transport.close() }
    FakeServer.offline = true
    do {
      _ = try await transport.sync(try candidate())
      XCTFail("offline must throw")
    } catch let error as SyncTransportError {
      XCTAssertEqual(error, .network(.notConnectedToInternet))
    }
  }

  // MARK: Archive

  func testAChatArchivedOnTheServerButLiveHereComesBackBeforeItSyncs() async throws {
    try chat(["Question", "Answer"])
    let transport = try transport()
    defer { transport.close() }
    _ = try await transport.sync(try candidate())
    FakeServer.sessions["claude/thread"]?.isArchived = true
    FakeServer.calls = []
    SessionCollector.transcripts.removeAll()
    try chat(["Question", "Answer", "More"])
    _ = try await transport.sync(try candidate())
    XCTAssertEqual(methodsAndPaths.prefix(2), ["GET /v1/agent-sessions/claude/thread", "PUT /v1/agent-sessions/claude/thread/archive"])
    XCTAssertEqual(FakeServer.calls[1].body?["archived"] as? Bool, false)
    XCTAssertEqual(FakeServer.sessions["claude/thread"]?.isArchived, false)
  }

  func testAChatArchivedHereIsHiddenOnTheServerAndNeverUploaded() async throws {
    try chat(["Question", "Answer"])
    let transport = try transport()
    defer { transport.close() }
    var candidate = try candidate()
    candidate.archived = true
    try await transport.archive(candidate)
    XCTAssertEqual(methodsAndPaths, ["GET /v1/agent-sessions/claude/thread"], "a chat the server never saw needs nothing")
    _ = try await transport.sync(try self.candidate())
    FakeServer.calls = []
    try await transport.archive(candidate)
    XCTAssertEqual(methodsAndPaths, ["GET /v1/agent-sessions/claude/thread", "PUT /v1/agent-sessions/claude/thread/archive"])
    XCTAssertEqual(FakeServer.sessions["claude/thread"]?.isArchived, true)
  }

  // MARK: Where it may send

  func testARedirectIsNeverFollowed() async throws {
    let transport = try transport()
    defer { transport.close() }
    FakeServer.redirectTo = "http://127.0.0.1:9999/elsewhere"
    do {
      _ = try await transport.request("GET", "/v1/agent-sessions/claude/thread")
      XCTFail("a redirect is an error")
    } catch let error as SyncTransportError {
      XCTAssertEqual(error, .http(302))
    }
    XCTAssertFalse(FakeServer.calls.contains { $0.path == "/elsewhere" || $0.port == 9999 })
  }

  func testARefusedUploadIsAConversationProblemAndAConflictIsNot() async throws {
    try chat(["Question", "Answer"])
    let transport = try transport()
    defer { transport.close() }
    for status in [413, 400] {
      FakeServer.reset()
      FakeServer.refuseUploads = status
      do {
        _ = try await transport.sync(try candidate())
        XCTFail("a refused upload must throw")
      } catch {
        XCTAssertEqual(error as? SyncTransportError, .http(status))
        XCTAssertTrue(RefusalMemo.isRefusal(error), "HTTP \(status) holds the conversation")
      }
    }
    FakeServer.reset()
    FakeServer.conflict = true
    do {
      _ = try await transport.sync(try candidate())
      XCTFail("a conflict must throw")
    } catch {
      XCTAssertFalse(RefusalMemo.isRefusal(error), "a changed revision is worth another try")
    }
  }

  func testARefusalIsHeldForTheContentThatWasSentNotWhatTheFileHoldsNow() async throws {
    try chat(["Question", "Answer"])
    let transport = try transport()
    defer { transport.close() }
    let sentCandidate = try candidate()
    let sent = try transport.acknowledgement(
      try SessionCollector.snapshot(sentCandidate, credential: "fixture-bearer"), key: sentCandidate.key)
    FakeServer.refuseUploads = 413
    FakeServer.whileUploading = { try? self.chat(["Question", "Answer", "A line added while it was being sent"]) }
    do {
      _ = try await transport.sync(sentCandidate)
      XCTFail("a refused upload must throw")
    } catch {
      XCTAssertTrue(RefusalMemo.isRefusal(error))
    }
    XCTAssertEqual(transport.attempted(sentCandidate.key), sent)
    let grown = try candidate()
    let now = try transport.acknowledgement(
      try SessionCollector.snapshot(grown, credential: "fixture-bearer"), key: grown.key)
    XCTAssertNotEqual(now, sent)
    var memo = RefusalMemo()
    memo.refuse(sentCandidate.key, fingerprint: transport.attempted(sentCandidate.key), reason: "r")
    XCTAssertFalse(memo.isHeld(sentCandidate.key) { now }, "the line added meanwhile is tried at once")
    XCTAssertNil(transport.attempted("claude/nothing-tried"))
  }

  func testOnlyHttpsOrThisMacIsAllowed() {
    for base in [
      "https://hq.example.test", "https://hq.example.test:8443", "https://hq.example.test/team",
      "http://127.0.0.1:8797", "http://localhost:8790", "http://[::1]:8790",
    ] {
      XCTAssertTrue(SyncTransport.allowed(base), base)
    }
    for base in [
      "http://hq.example.test", "http://hq.local:8790", "http://192.168.1.20:8790", "http://127.0.0.1.example.test",
      "https://user:pw@hq.example.test", "https://hq.example.test?x=1", "https://hq.example.test#x",
      "https://hq.example.test/", "ftp://hq.example.test", "hq.example.test", "", "https://",
    ] {
      XCTAssertFalse(SyncTransport.allowed(base), base)
    }
    XCTAssertThrowsError(try transport(base: "http://hq.local:8790")) { XCTAssertEqual($0 as? SyncFailure, .destination) }
  }
}

/// A fake server for the session routes: what the real ones keep, in a dictionary.
final class FakeServer: URLProtocol, @unchecked Sendable {
  struct Call {
    var method: String, path: String, host: String, port: Int?, bearer: String?
    var body: [String: Any]?
  }
  struct Stored {
    var snapshot: [String: Any]
    var revision: Int
    var sha256: String
    var activityAt: Double?
    var filesTouched: [String]
    var isArchived = false
  }
  nonisolated(unsafe) static var calls: [Call] = []
  nonisolated(unsafe) static var sessions: [String: Stored] = [:]
  nonisolated(unsafe) static var conflict = false
  nonisolated(unsafe) static var corruptReadback = false
  nonisolated(unsafe) static var verbatim = false
  nonisolated(unsafe) static var offline = false
  nonisolated(unsafe) static var redirectTo: String?
  /// Answers every snapshot upload with this status (400 and 413 are the server's refusals).
  nonisolated(unsafe) static var refuseUploads: Int?
  /// Runs when a snapshot upload arrives, before it is answered (a chat that grows meanwhile).
  nonisolated(unsafe) static var whileUploading: (() -> Void)?

  static func reset() {
    calls = []; sessions = [:]; conflict = false; corruptReadback = false; verbatim = false
    offline = false; redirectTo = nil; refuseUploads = nil; whileUploading = nil
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  /// The canonical hash over the snapshot, as the server computes it.
  static func hash(_ snapshot: [String: Any]) -> String {
    let messages = (snapshot["messages"] as? [[String: Any]] ?? []).map {
      [$0["id"] as Any, $0["role"] as Any, $0["text"] as Any, $0["timestamp"] ?? NSNull()] as [Any]
    }
    let envelope: [Any] = [
      snapshot["projection"] as Any, snapshot["title"] as Any, snapshot["cwd"] as Any,
      snapshot["git_branch"] ?? NSNull(), snapshot["task_ref"] ?? NSNull(), messages,
    ]
    return SHA256.hash(data: try! syncJSON(envelope)).map { String(format: "%02x", $0) }.joined()
  }

  private func session(_ stored: Stored) -> [String: Any] {
    var value: [String: Any] = [
      "sha256": stored.sha256, "revision": stored.revision,
      "message_count": (stored.snapshot["messages"] as? [Any])?.count ?? 0,
      "files_touched": stored.filesTouched,
      "archived_at": stored.isArchived ? "2026-10-20T12:00:00Z" : NSNull(),
    ]
    if let activity = stored.activityAt { value["activity_at"] = activity }
    return value
  }

  override func startLoading() {
    let url = request.url!
    var body: [String: Any]?
    if let data = request.httpBody ?? request.httpBodyStream.flatMap({ stream -> Data? in
      stream.open(); defer { stream.close() }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 65536)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
      }
      return data
    }) {
      body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    Self.calls.append(
      Call(
        method: request.httpMethod ?? "GET", path: url.path, host: url.host ?? "", port: url.port,
        bearer: request.value(forHTTPHeaderField: "Authorization"), body: body))
    if Self.offline {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    var code = 200
    var reply: [String: Any] = [:]
    var headers = ["Content-Type": "application/json"]
    let parts = url.path.split(separator: "/").map(String.init)  // v1 agent-sessions <provider> <source> [leaf]
    let key = parts.count >= 4 ? parts[2] + "/" + parts[3] : ""
    let leaf = parts.count >= 5 ? parts[4] : ""
    if let target = Self.redirectTo {
      code = 302
      headers["Location"] = target
    } else {
      switch (request.httpMethod ?? "GET", leaf) {
      case ("GET", ""):
        if let stored = Self.sessions[key] { reply = ["session": session(stored)] } else { code = 404 }
      case ("GET", "transcript"):
        if var stored = Self.sessions[key] {
          if Self.corruptReadback { stored.snapshot["title"] = "Corrupted" }
          reply = stored.snapshot
        } else { code = 404 }
      case ("PUT", "") where Self.refuseUploads != nil:
        Self.whileUploading?()
        code = Self.refuseUploads ?? 400
      case ("PUT", ""):
        let current = Self.sessions[key]
        if Self.conflict || (body?["base_revision"] as? Int) != (current?.revision ?? 0) {
          code = 409
          break
        }
        let snapshot = body?["snapshot"] as? [String: Any] ?? [:]
        let stored = Stored(
          snapshot: snapshot, revision: (current?.revision ?? 0) + 1, sha256: Self.hash(snapshot),
          activityAt: body?["activity_at"] as? Double, filesTouched: body?["files_touched"] as? [String] ?? [])
        Self.sessions[key] = stored
        reply = ["status": "synced", "session": session(stored), "stored_verbatim": Self.verbatim, "body_sha256": "x"]
      case ("PUT", "activity"):
        guard var stored = Self.sessions[key], stored.sha256 == body?["sha256"] as? String else {
          code = 409
          break
        }
        stored.activityAt = body?["activity_at"] as? Double ?? stored.activityAt
        stored.filesTouched = body?["files_touched"] as? [String] ?? stored.filesTouched
        Self.sessions[key] = stored
        reply = ["status": "unchanged", "session": session(stored)]
      case ("PUT", "archive"):
        guard var stored = Self.sessions[key] else { code = 404; break }
        stored.isArchived = body?["archived"] as? Bool ?? false
        Self.sessions[key] = stored
        reply = ["session": session(stored)]
      default:
        code = 404
      }
    }
    let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
    if code == 302, let target = URL(string: Self.redirectTo ?? "") {
      client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: (try? syncJSON(reply)) ?? Data("{}".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}

import CryptoKit
import Foundation
import SQLite3
import XCTest

/// What the helper reads from a Mac and what goes into a snapshot: the window, the
/// text-only rule, what is hidden, and the caps.
final class CollectorTests: XCTestCase {
  let scratch = Scratch()

  /// A Claude home with one project folder, and a work folder that is a checkout.
  private func claudeHome() throws -> (source: SessionSyncSource, project: URL, work: String) {
    let claude = try scratch.folder(".claude")
    let project = try scratch.folder(".claude/projects/p")
    _ = try scratch.folder("work/.git")
    return (SessionSyncSource(provider: "claude", path: claude.path), project, scratch.root.appendingPathComponent("work").path)
  }

  private func snapshot(_ source: SessionSyncSource, id: String = "thread", credential: String = "") throws -> SyncSnapshot {
    let found = try SessionCollector.discover(source)
    let candidate = try XCTUnwrap(found.first { $0.id == id }, "candidates: \(found.map(\.id))")
    return try SessionCollector.snapshot(candidate, credential: credential)
  }

  private func json(_ snapshot: SyncSnapshot) throws -> String {
    String(decoding: try syncJSON(snapshot.json), as: UTF8.self)
  }

  // MARK: Window and kinds of run

  func testClaudeChatsActiveInTheLastSevenDaysSyncFromAnyFolder() throws {
    let (source, project, work) = try claudeHome()
    for (name, age) in [("recent", 3600.0), ("week", 6 * 86400), ("old", 8 * 86400)] {
      let log = project.appendingPathComponent(name + ".jsonl")
      try scratch.writeLines(
        [claudeRow("u", "user", "Hello from \(name)", session: name, cwd: "/nonexistent/\(name)")], to: log)
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: log.path)
    }
    _ = work
    let ids = Set(try SessionCollector.discover(source).map(\.id))
    XCTAssertEqual(ids, ["recent", "week"], "an 8-day-old chat is not read; a chat in a folder that does not exist is")
  }

  func testScriptRunsAreSkippedAndInteractiveSdkRunsAreKept() throws {
    let (source, project, work) = try claudeHome()
    for (name, entrypoint) in [("print", "sdk-cli"), ("sdk", "sdk-ts"), ("cli", "cli"), ("desktop", "claude-desktop")] {
      try scratch.writeLines(
        [claudeRow("u", "user", "Question", session: name, cwd: work, extra: ["entrypoint": entrypoint])],
        to: project.appendingPathComponent(name + ".jsonl"))
    }
    XCTAssertEqual(Set(try SessionCollector.discover(source).map(\.id)), ["sdk", "cli", "desktop"])
  }

  func testCodexThreadsFollowTheSameWindowAndSkipScriptRunsAndSubagents() throws {
    let codex = try scratch.folder(".codex")
    let work = try scratch.folder("work").path
    let rollout = codex.appendingPathComponent("rollout.jsonl")
    try scratch.writeLines(
      [
        ["timestamp": "2026-10-16T12:00:00.000Z", "type": "session_meta", "payload": ["id": "cli-run", "cwd": work]],
        ["timestamp": "2026-10-16T12:00:01.000Z", "type": "response_item",
         "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Hello"]]]],
      ], to: rollout)
    let db = try Database(codex.appendingPathComponent("state_5.sqlite"))
    try db.run("CREATE TABLE threads (id TEXT, cwd TEXT, title TEXT, history_mode TEXT, updated_at INTEGER, rollout_path TEXT, source TEXT, originator TEXT)")
    let now = Int(Date().timeIntervalSince1970)
    try db.run("""
      INSERT INTO threads VALUES
        ('cli-run', '/anywhere', 'Interactive', 'legacy', \(now - 60), '\(rollout.path)', 'cli', 'codex_cli_rs'),
        ('old-run', '/anywhere', 'Old', 'legacy', \(now - 8 * 86400), '\(rollout.path)', 'cli', 'codex_cli_rs'),
        ('exec-run', '/anywhere', 'Exec', 'legacy', \(now - 60), '\(rollout.path)', 'exec', 'codex_exec'),
        ('guardian', '/anywhere', 'Review', 'paginated', \(now - 60), '', '{"subagent":{"other":"guardian"}}', 'Codex Desktop')
      """)
    let found = try SessionCollector.discover(SessionSyncSource(provider: "codex", path: codex.path))
    XCTAssertEqual(Set(found.filter { !$0.archived }.map(\.id)), ["cli-run"])
    XCTAssertEqual(found.filter(\.archived).map(\.id), ["guardian"], "a subagent thread comes back archived, never uploaded")
    let snapshot = try SessionCollector.snapshot(try XCTUnwrap(found.first { $0.id == "cli-run" }), credential: "")
    XCTAssertEqual(snapshot.messages.map(\.text), ["Hello"])
  }

  // MARK: Text only

  func testOnlyMessageTextIsReadNeverToolCallsReasoningOrMeta() throws {
    let (source, project, work) = try claudeHome()
    try scratch.writeLines(
      [
        claudeRow("u1", "user", "Question", cwd: work),
        claudeRow(
          "a1", "assistant",
          [
            ["type": "thinking", "thinking": "PRIVATE REASONING"],
            ["type": "tool_use", "id": "c1", "name": "Read", "input": ["path": "file", "api_key": "short-secret"]],
            ["type": "text", "text": "Answer"],
          ], cwd: work),
        claudeRow("u2", "user", [["type": "tool_result", "tool_use_id": "c1", "content": "SECRET-TOOL-OUTPUT"]], cwd: work),
        claudeRow("m1", "user", "META TEXT", cwd: work, extra: ["isMeta": true]),
      ], to: project.appendingPathComponent("thread.jsonl"), tail: "{\"type\":")
    let snapshot = try snapshot(source)
    XCTAssertEqual(snapshot.messages.map(\.text), ["Question", "Answer"], "a record still being written is waited for")
    let body = try json(snapshot)
    for leak in ["PRIVATE REASONING", "SECRET-TOOL-OUTPUT", "short-secret", "META TEXT", "tool_use"] {
      XCTAssertFalse(body.contains(leak), leak)
    }
    XCTAssertEqual(
      Set(snapshot.json.keys), ["projection", "title", "cwd", "git_branch", "task_ref", "messages"],
      "nothing but the conversation text and its labels is sent")
  }

  func testCodexToolItemsNameFilesButTheirTextIsNeverRead() throws {
    let codex = try scratch.folder(".codex")
    _ = try scratch.folder("work/.git")
    let work = scratch.root.appendingPathComponent("work").path
    let index = try Database(codex.appendingPathComponent("state_5.sqlite"))
    try index.run("CREATE TABLE threads (id TEXT, cwd TEXT, title TEXT, history_mode TEXT, updated_at_ms INTEGER)")
    try index.run("INSERT INTO threads VALUES ('desk', '\(work)', 'Desk', 'paginated', \(Int(Date().timeIntervalSince1970 * 1000)))")
    let history = try Database(codex.appendingPathComponent("thread_history_1.sqlite"))
    try history.run("CREATE TABLE thread_items (thread_id TEXT, turn_id TEXT, item_id TEXT, rollout_ordinal INTEGER, created_at_ms INTEGER, item_json TEXT, item_type TEXT)")
    let changes = "[{\"path\":\"\(work)/a.swift\"}]"
    try history.run("""
      INSERT INTO thread_items VALUES
        ('desk','t','1',1,300000,'{"type":"userMessage","content":[{"type":"text","text":"Run it"}]}','userMessage'),
        ('desk','t','2',2,300001,'{"type":"commandExecution","command":"env","aggregatedOutput":"GITHUB_TOKEN-OUTPUT","status":"completed"}','commandExecution'),
        ('desk','t','3',3,300002,'{"type":"fileChange","changes":\(changes),"status":"completed"}','fileChange'),
        ('desk','t','4',4,300003,'{"type":"mcpToolCall","server":"s","tool":"t","arguments":"MCP-ARGUMENTS","status":"completed"}','mcpToolCall'),
        ('desk','t','5',5,300004,'{"type":"agentMessage","text":"Done"}','agentMessage')
      """)
    let snapshot = try snapshot(SessionSyncSource(provider: "codex", path: codex.path), id: "desk")
    XCTAssertEqual(snapshot.messages.map(\.text), ["Run it", "Done"])
    XCTAssertEqual(snapshot.filesTouched, ["a.swift"])
    let body = try json(snapshot)
    XCTAssertFalse(body.contains("GITHUB_TOKEN-OUTPUT") || body.contains("MCP-ARGUMENTS"))
  }

  func testFilesTouchedAreRelativeToTheirCheckout() throws {
    let (source, project, work) = try claudeHome()
    func edit(_ id: String, _ path: String) -> [String: Any] {
      claudeRow(id, "assistant", [["type": "tool_use", "id": id, "name": "Edit", "input": ["file_path": path]]], cwd: work)
    }
    try scratch.writeLines(
      [
        claudeRow("u", "user", "Go", cwd: work), edit("e1", work + "/a.swift"), edit("e2", "sub/b.swift"),
        edit("e4", scratch.root.path + "/outside.txt"),
      ], to: project.appendingPathComponent("thread.jsonl"))
    XCTAssertEqual(try snapshot(source).filesTouched, ["sub/b.swift", "a.swift"], "newest first; a file in no checkout is dropped")
  }

  func testLabelsAreCutToTheServersLimitsAndHiddenLikeText() throws {
    let (source, project, work) = try claudeHome()
    let token = "ghp_" + String(repeating: "q", count: 36)
    let longFolder = scratch.root.appendingPathComponent(String(repeating: "d", count: 3000)).path
    func edit(_ id: String, _ path: String) -> [String: Any] {
      claudeRow(id, "assistant", [["type": "tool_use", "id": id, "name": "Edit", "input": ["file_path": path]]], cwd: longFolder)
    }
    var rows: [[String: Any]] = [
      claudeRow("u", "user", "Go", cwd: longFolder, extra: ["gitBranch": "feature/\(token)/" + String(repeating: "b", count: 400)])
    ]
    rows += (0..<60).map { edit("e\($0)", work + "/f\($0).swift") }
    rows.append(edit("named", work + "/\(token).swift"))
    try scratch.writeLines(rows, to: project.appendingPathComponent("thread.jsonl"))
    let snapshot = try snapshot(source)
    XCTAssertEqual(snapshot.cwd.utf16.count, SessionCollector.Limits.cwd)
    XCTAssertEqual(snapshot.branch?.utf16.count, SessionCollector.Limits.branch)
    XCTAssertEqual(snapshot.filesTouched.count, SessionCollector.Limits.files)
    let body = try json(snapshot) + snapshot.filesTouched.joined()
    XCTAssertFalse(body.contains(token), "a secret in a branch or file name is hidden")
    XCTAssertTrue(snapshot.branch?.contains("[REDACTED]") == true)
    XCTAssertEqual(snapshot.filesTouched.first, "[REDACTED].swift")
    XCTAssertEqual(SessionCollector.clamp("a🌳b", to: 2), "a", "a pair of surrogates is never split")
    XCTAssertEqual(SessionCollector.clamp("a🌳b", to: 3), "a🌳")
    XCTAssertEqual(SessionCollector.clamp("short", to: 200), "short")
  }

  func testABadTimestampGoesAsNullAndABadIdSkipsOnlyThatMessage() throws {
    let (source, project, work) = try claudeHome()
    let longId = String(repeating: "i", count: 300)
    try scratch.writeLines(
      [
        claudeRow("u1", "user", "First", cwd: work, stamp: "2026-10-20T12:00:00.000Z"),
        claudeRow("u2", "assistant", "Second", cwd: work, stamp: String(repeating: "t", count: 100)),
        claudeRow(longId, "user", "Third, with an id the server would refuse", cwd: work),
        claudeRow("u4", "assistant", "Fourth", cwd: work, stamp: String(repeating: "t", count: 64)),
      ], to: project.appendingPathComponent("thread.jsonl"))
    let messages = try snapshot(source).messages
    XCTAssertEqual(messages.map(\.text), ["First", "Second", "Fourth"], "only the message with the long id is left out")
    XCTAssertEqual(messages.map(\.timestamp), ["2026-10-20T12:00:00.000Z", nil, String(repeating: "t", count: 64)])
    XCTAssertTrue(messages.allSatisfy { $0.id.utf16.count <= 256 })
  }

  // MARK: Injected blocks

  func testInjectedBlocksNeverLeaveInAClaudeMessage() throws {
    let (source, project, work) = try claudeHome()
    let reminder = "<system-reminder>\nContents of /x/CLAUDE.md: PRIVATE-NOTES\n</system-reminder>"
    try scratch.writeLines(
      [
        claudeRow("u1", "user", reminder + "\nAdd retries to the uploader", cwd: work),
        claudeRow("u2", "user", reminder, cwd: work),
        claudeRow("u3", "user", "Look <system-reminder>never closed PRIVATE-TAIL", cwd: work),
        claudeRow("a1", "assistant", "The <system-reminder> tag is injected by the tool", cwd: work),
      ], to: project.appendingPathComponent("thread.jsonl"))
    let snapshot = try snapshot(source)
    XCTAssertEqual(
      snapshot.messages.map(\.text),
      ["Add retries to the uploader", "Look", "The <system-reminder> tag is injected by the tool"],
      "a message that was only a reminder is not a message, and the assistant's own words are never cut")
    XCTAssertFalse(try json(snapshot).contains("PRIVATE"))
  }

  func testInjectedBlocksNeverLeaveInACodexMessage() throws {
    let codex = try scratch.folder(".codex")
    let work = try scratch.folder("work").path
    let rollout = codex.appendingPathComponent("rollout.jsonl")
    func message(_ text: String) -> [String: Any] {
      ["timestamp": "2026-10-16T12:00:01.000Z", "type": "response_item",
       "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]]
    }
    try scratch.writeLines(
      [
        ["timestamp": "2026-10-16T12:00:00.000Z", "type": "session_meta", "payload": ["id": "cx", "cwd": work]],
        message("# AGENTS.md instructions for \(work)\n\n<INSTRUCTIONS>\nPRIVATE-RULES\n</INSTRUCTIONS>"),
        message("<environment_context>\n  <cwd>\(work)</cwd>\n</environment_context>"),
        message("Fix the flaky sync test"),
      ], to: rollout)
    let candidate = SyncCandidate(
      source: SessionSyncSource(provider: "codex", path: codex.path), id: "cx",
      metadata: ["cwd": work, "rollout_path": rollout.path, "updated_at": "1000"])
    let snapshot = try SessionCollector.snapshot(candidate, credential: "")
    XCTAssertEqual(snapshot.messages.map(\.text), ["Fix the flaky sync test"])
    XCTAssertFalse(try json(snapshot).contains("PRIVATE-RULES") || json(snapshot).contains("AGENTS.md"))
  }

  func testStrippingInjectedBlocks() {
    for name in SyncTitle.injected {
      XCTAssertEqual(SyncTitle.strippingInjected("A <\(name)>x</\(name)> B"), "A  B", name)
      XCTAssertEqual(SyncTitle.strippingInjected("<\(name.uppercased())>x</\(name.uppercased())>"), "", name)
    }
    XCTAssertEqual(SyncTitle.strippingInjected("plain <b>text</b>"), "plain <b>text</b>", "other tags stay")
    XCTAssertEqual(SyncTitle.strippingInjected("  untouched  "), "  untouched  ", "text with no block is returned as it is")
    XCTAssertEqual(
      SyncTitle.strippingInjected("<command-name>/x</command-name>"), "<command-name>/x</command-name>",
      "what the person ran is theirs")
  }

  // MARK: Secrets

  func testSecretsAreHiddenBeforeUpload() throws {
    let (source, project, work) = try claudeHome()
    // Built at run time, so the test file holds no secret.
    let token = "ghp_" + String((0..<36).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    let credential = String((0..<24).map { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ".randomElement()! })
    try scratch.writeLines(
      [claudeRow("u", "user", "use \(token) and \(credential) please", cwd: work)],
      to: project.appendingPathComponent("thread.jsonl"))
    let snapshot = try snapshot(source, credential: credential)
    XCTAssertEqual(snapshot.messages.first?.text, "use [REDACTED] and [REDACTED] please")
    XCTAssertFalse(try json(snapshot).contains(token))
  }

  func testEveryPatternHidesItsSecret() {
    func base64URL(_ count: Int) -> String {
      Data((0..<count).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
    let serverKey = "hq_" + base64URL(32)  // this server's own key format: hq_ plus 43 characters
    XCTAssertEqual(serverKey.count, 46)
    let cases: [(leak: String, text: String)] = [
      ("MIIEow", "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA7abc"),
      (serverKey, "key \(serverKey) end"),
      ("abcdefghijklmnop", "sk-proj-abcdefghijklmnop0123"),
      ("abcdefghijklmnop", "ghp_abcdefghijklmnop1234"),
      ("abcdefghijklmnop", "AKIAabcdefghijklmnop"),
      ("abcdefghijklmnop", "Bearer abcdefghijklmnop0123"),
      ("dozjgNryP4J3jVmNHl0w5N", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"),
      ("abcdefghijklmnop0123", "api_key=abcdefghijklmnop0123"),
      ("abcdefghijklmnop", "pscale_tkn_abcdefghijklmnop0123"),
      ("abcdefghijklmnop", "sk_live_abcdefghijklmnopqrstuvwx"),
      ("abcdefghijklmnop", "whsec_abcdefghijklmnop0123"),
      ("abcdefghijklmnop", "xoxb-1234567890-abcdefghijklmnop"),
      ("abcdefghijklmnop", "AIzaSyAbcdefghijklmnop0123"),
      ("abcdefghijklmnop", "SG.abcdefghijklmnop.0123456789abcdef"),
      ("ABCDEFGHIJKLMNOP", "ASIAABCDEFGHIJKLMNOP"),
      ("abcdefghijklmnop", "https://hooks.slack.com/services/T000/B000/abcdefghijklmnop"),
      ("wJalrXUtnFEMI", "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI"),
      ("s3cret", "MYSQL_PWD=s3cret"),
      ("p4ss", "mysql://user:p4ss@db.example.test/db"),
      ("dXNlcjpwYXNz", "Authorization: Basic dXNlcjpwYXNz"),
      ("abc123", "Cookie: session=abc123; theme=dark"),
      ("hunter2", "curl -u admin:hunter2 https://example.test"),
    ]
    for (leak, text) in cases {
      let out = SessionCollector.redact("before \(text) after", credential: "", secrets: [])
      XCTAssertTrue(out.contains("[REDACTED]") && !out.contains(leak), "\(text) -> \(out)")
    }
    XCTAssertEqual(
      SessionCollector.redact("ASIAPACIFIC, hq_short and curl -s https://example.test", credential: "", secrets: []),
      "ASIAPACIFIC, hq_short and curl -s https://example.test", "ordinary text is left alone")
    XCTAssertEqual(SessionCollector.redactionPatterns.count, 13)
  }

  func testEnvironmentSecretsAndTheSignInAreReplacedWherever() {
    XCTAssertEqual(
      Set(SessionCollector.secretValues(in: ["API_KEY": "abcdefgh1234", "GH_TOKEN": "short", "HOME": "/Users/ada", "db_password": "p4ssw0rd-long"])),
      ["abcdefgh1234", "p4ssw0rd-long"], "secret-named variables of 8 characters or more")
    let out = SessionCollector.redact(
      "x abcdefgh1234 y p4ssw0rd-long z", credential: "", secrets: ["abcdefgh1234", "p4ssw0rd-long"])
    XCTAssertEqual(out, "x [REDACTED] y [REDACTED] z")
    let bearer = "0123456789abcdefghij"
    XCTAssertEqual(SessionCollector.redact("t \(bearer) t", credential: bearer, secrets: []), "t [REDACTED] t")
  }

  /// The server's own hostile inputs (`adversarial` in `apps/tasks/redact.test.ts`): at least one
  /// 500,000-character text built against each of the 13 patterns, plus ordinary long text. ICU
  /// is a different engine from the server's, so the helper times them itself.
  func testHostileTextIsHiddenInGoodTime() {
    let size = 500_000
    func rep(_ unit: String, _ count: Int) -> String { String(repeating: unit, count: count) }
    func fill(_ unit: String) -> String { rep(unit, (size + unit.count - 1) / unit.count) }
    let adversarial: [(pattern: Int, name: String, text: String)] = [
      (1, "a key header, then one long run of other characters", "-----BEGIN PRIVATE KEY-----" + rep("!", size)),
      (1, "a key header and \"!\", repeated", fill("-----BEGIN PRIVATE KEY-----!")),
      (1, "a header with a long name", "-----BEGIN " + rep("A", size)),
      (1, "headers with no end", fill("-----BEGIN PRIVATE KEY-----")),
      (2, "hq_ and one character short of a key, repeated", fill("hq_" + rep("a", 39) + "!")),
      (2, "hq_ then one long run", "hq_" + rep("a", size)),
      (3, "sk- repeated", fill("sk-")),
      (3, "sk- and one character short, repeated", fill("sk-" + rep("a", 15) + "!")),
      (4, "Bearer and a space, repeated", fill("Bearer ")),
      (4, "Bearer then one long run of spaces", "Bearer" + rep(" ", size)),
      (4, "Bearer and a short token, repeated", fill("Bearer abcdefgh!")),
      (5, "eyJ- repeated", fill("eyJ-")),
      (5, "eyJ, eight characters and a dot, repeated", fill("eyJaaaaaaaa.aaaaaaaa.")),
      (5, "eyJ then one long run", "eyJ" + rep("a", size)),
      (5, "a JWT header and one long middle with no second dot", "eyJaaaaaaaa." + rep("b", size)),
      (5, "a JWT header, a middle, and one long signature", "eyJaaaaaaaa.bbbbbbbb." + rep("c", size)),
      (5, "blocks of 128 eyJ- ending in a dot", fill(rep("eyJ-", 128) + ".")),
      (5, "a header, a dot and a long run, then a hyphen, repeated", fill("eyJaaaaaaaa." + rep("b", 2000) + "-")),
      (6, "a keyword then one long run of spaces", "token" + rep(" ", size)),
      (6, "a keyword and a value one character short, repeated", fill("token=" + rep("a", 15) + "!")),
      (6, "keywords joined by hyphens", fill("password-")),
      (7, "a vendor prefix and one character short, repeated", fill("pscale_pw_" + rep("a", 15) + "!")),
      (7, "gsk_ repeated", fill("gsk_")),
      (8, "ASIA and fifteen letters, repeated", fill("ASIA" + rep("A", 15) + "!")),
      (8, "ASIA then one long run", "ASIA" + rep("A", size)),
      (9, "a webhook address one character short, repeated", fill("hooks.slack.com/services/" + rep("a", 15) + "!")),
      (9, "a webhook address then one long run", "hooks.slack.com/services/" + rep("a", size)),
      (10, "KEY repeated", fill("KEY")),
      (10, "an env name and \"= \", repeated", fill("X_KEY= ")),
      (10, "a long upper-case name", rep("A", size)),
      (11, "a://b: repeated", fill("a://b:")),
      (11, "a scheme and one long user name", "a://" + rep("b", size)),
      (11, "a user and one long password with no @", "a://b:" + rep("c", size)),
      (11, "://a: repeated", fill("://a:")),
      (12, "cookie then one long run of spaces", "cookie:" + rep(" ", size)),
      (12, "cookie: and a quote, repeated", fill("cookie: \"")),
      (12, "cookie names with no colon", fill("cookie ")),
      (13, "-u and a space, repeated", fill("-u ")),
      (13, "-u and one long run with no colon", "-u " + rep("a", size)),
      (13, "-u then one long run of spaces", "-u" + rep(" ", size)),
      (13, "curl repeated", fill("curl ")),
      (0, "a hyphen-joined run", rep("a-", 250_000)),
      (0, "a base64url blob", rep("Ab1_", 125_000)),
      (0, "hyphenated ids", rep("123a4567-a89b-12d3-a456-426614174000-", 13_500)),
      (0, "blank lines", rep("\n", size)),
      (0, "ordinary prose", rep("plain words go here. ", 25_000)),
    ]
    XCTAssertEqual(Set(adversarial.map(\.pattern).filter { $0 > 0 }), Set(1...13), "each pattern has input built against it")
    for input in adversarial {
      XCTAssertGreaterThanOrEqual(input.text.utf16.count, 450_000, input.name)
      let started = Date()
      _ = SessionCollector.redact(input.text, credential: "", secrets: [])
      XCTAssertLessThan(Date().timeIntervalSince(started), 2, "pattern \(input.pattern): \(input.name)")
    }
  }

  /// Bounds must not let a real credential of a usual size through.
  func testTheBoundsStillHideLongCredentials() {
    let jwt = "eyJ" + String(repeating: "a", count: 300) + "." + String(repeating: "b", count: 2000) + "." + String(repeating: "c", count: 600)
    let key = "-----BEGIN RSA PRIVATE KEY-----\n" + String(repeating: "MIIEowIBAAKCAQEA", count: 500) + "\n-----END RSA PRIVATE KEY-----"
    func hide(_ text: String) -> String { SessionCollector.redact(text, credential: "", secrets: []) }
    XCTAssertEqual(hide("x \(jwt) y"), "x [REDACTED] y")
    XCTAssertEqual(hide("x \(key) y"), "x [REDACTED] y")
    XCTAssertEqual(hide("curl -u admin:\(String(repeating: "p", count: 900)) z"), "curl [REDACTED] z")
    let bigJWT = "eyJ" + String(repeating: "a", count: 300) + "." + String(repeating: "b", count: 5000) + "." + String(repeating: "c", count: 10_000)
    XCTAssertEqual(hide("x \(bigJWT) y"), "x [REDACTED] y", "a 5,000-character middle and a 10,000-character signature")
    XCTAssertEqual(hide("API_KEY=\(String(repeating: "v", count: 6000)) z"), "[REDACTED] z", "a 6,000-character value")
  }

  // MARK: Caps and the canonical hash

  func testALongConversationKeepsItsNewestMessagesBehindOneNote() throws {
    let (source, project, work) = try claudeHome()
    let rows = (0..<700).map { claudeRow("m\($0)", $0 % 2 == 0 ? "user" : "assistant", "message \($0) " + String(repeating: "x", count: 3500), cwd: work) }
    try scratch.writeLines(rows, to: project.appendingPathComponent("thread.jsonl"))
    let snapshot = try snapshot(source)
    XCTAssertEqual(snapshot.messages.first?.id, "hq-sync-earlier-messages")
    XCTAssertTrue(snapshot.messages.first?.text.contains("earlier messages") == true)
    XCTAssertTrue(snapshot.messages.last?.text.hasPrefix("message 699 ") == true, "the newest message is always kept")
    XCTAssertLessThan(try syncJSON(["base_revision": 1, "snapshot": snapshot.json]).count, SessionCollector.maxBytes)
  }

  /// The server rejects a snapshot PUT whose JSON body passes 1 MiB. Sweep the message count
  /// across that edge: below it every message goes; past it the oldest are dropped behind one
  /// note; and no body, with the widest revision and time a request can carry, is ever over.
  func testTheUploadBodyNeverPassesTheServersOneMebibyteCap() throws {
    XCTAssertEqual(SessionCollector.maxBytes, 1_048_576)
    let (source, project, work) = try claudeHome()
    let log = project.appendingPathComponent("thread.jsonl")
    var sawAll = false, sawTrimmed = false
    for count in 100...130 {
      let rows = (0..<count).map {
        claudeRow("m\($0)", $0 % 2 == 0 ? "user" : "assistant", "n\($0) " + String(repeating: "y", count: 9000), cwd: work)
      }
      try scratch.writeLines(rows, to: log)
      SessionCollector.transcripts.removeAll()
      let snapshot = try snapshot(source)
      let body = try syncJSON([
        "base_revision": 9_007_199_254_740_991, "snapshot": snapshot.json,
        "activity_at": 9_007_199_254_740_991, "files_touched": snapshot.filesTouched,
      ])
      XCTAssertLessThanOrEqual(body.count, 1_048_576, "\(count) messages")
      XCTAssertTrue(snapshot.messages.last?.text.hasPrefix("n\(count - 1) ") == true, "the newest message is always kept")
      let raw = try syncJSON(snapshot.messages.filter { $0.id != "hq-sync-earlier-messages" }.map(\.json)).count
      if snapshot.messages.first?.id == "hq-sync-earlier-messages" {
        sawTrimmed = true
        let kept = snapshot.messages.count - 1
        XCTAssertLessThan(kept, count)
        let dropped = count - kept
        XCTAssertTrue(
          snapshot.messages[0].text.contains(dropped == 1 ? "1 earlier message omitted" : "\(dropped) earlier messages omitted"),
          snapshot.messages[0].text)
        XCTAssertEqual(snapshot.messages[1].id, "m\(count - kept)", "the oldest are the ones dropped")
      } else {
        sawAll = true
        XCTAssertEqual(snapshot.messages.count, count)
        XCTAssertLessThanOrEqual(raw, 1_048_576)
      }
    }
    XCTAssertTrue(sawAll && sawTrimmed, "the sweep crosses the cap")
  }

  func testAMessageOverTheLimitIsTruncatedAndSaysSo() throws {
    let (source, project, work) = try claudeHome()
    try scratch.writeLines(
      [claudeRow("u", "user", String(repeating: "x", count: 600_000), cwd: work)],
      to: project.appendingPathComponent("thread.jsonl"))
    let text = try XCTUnwrap(try snapshot(source).messages.first?.text)
    XCTAssertLessThanOrEqual(text.utf16.count, 500_000)
    XCTAssertTrue(text.hasSuffix("[Message truncated to fit the server's limit]"))
  }

  func testTheCanonicalHashIsTheOneEveryLanguageComputes() throws {
    let canonical = SyncSnapshot(
      title: "Hello 🌳", cwd: "/work", branch: nil,
      messages: [.init(id: "one", role: "user", text: "Hello / 🌳\n", timestamp: nil)])
    XCTAssertEqual(try canonical.hash, "ce19e892f8fc5c3a8be39b3feebc3436b74df054e9e0b1474885f0e03ec5bb95")
  }
}

/// A tiny SQLite writer for Codex fixtures.
final class Database {
  private var db: OpaquePointer?
  init(_ url: URL) throws {
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SyncFailure.source }
  }
  deinit { sqlite3_close(db) }
  func run(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SyncFailure.source }
  }
}

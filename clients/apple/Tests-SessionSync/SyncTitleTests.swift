import Foundation
import XCTest

/// Conversation titles: what `SyncTitle` makes of an opening message, and that a
/// transcript whose first user records are wrappers is titled by its first real prompt.
struct SyncTitleTests {
  static func check(_ condition: Bool, _ message: String) {
    guard !condition else { return }
    XCTFail(message)
  }

  static func expect(_ text: String, _ title: String?, _ label: String) {
    let made = SyncTitle.make(from: text)
    check(made == title, "\(label): expected \(String(describing: title)), got \(String(describing: made))")
  }

  static func run() throws {
    let clear = "<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"
    expect(clear, nil, "/clear record")
    for name in ["compact", "model", "resume", "login", "logout", "config", "cost", "status",
      "help", "exit", "effort", "fast", "context", "usage"]
    {
      expect(
        "<command-name>/\(name)</command-name>\n<command-message>\(name)</command-message>\n<command-args>sonnet</command-args>",
        nil, "/\(name) is housekeeping, whatever its arguments")
    }
    expect(
      "<command-name>/lane-flow</command-name>\n<command-message>lane-flow</command-message>\n<command-args>fix   the\nsync titles</command-args>",
      "/lane-flow fix the sync titles", "a command with arguments")
    expect("<command-name>/review</command-name><command-args></command-args>", "/review", "a command alone")
    expect("<command-name>plugin:skill</command-name><command-args>go</command-args>", "/plugin:skill go", "a name without its slash")
    // Only a record that is a command is read as one: a prompt that quotes the tag, or a
    // reminder that mentions one, is not.
    expect(
      "Titles show <command-name>/clear</command-name> in HQ, fix it",
      "Titles show <command-name>/clear</command-name> in HQ, fix it", "a prompt quoting a command tag")
    expect(
      "<system-reminder>ran <command-name>/review</command-name> earlier</system-reminder>\nFix the login bug",
      "Fix the login bug", "a reminder mentioning a command")
    expect(
      "<system-reminder>noise</system-reminder>\n<command-name>/review</command-name><command-args>auth</command-args>",
      "/review auth", "a command after a reminder is still a command")
    expect("  \n<command-name>/review</command-name>", "/review", "a command after blank space")
    print("PASS command records")

    expect("<system-reminder>Plan mode is active.</system-reminder>", nil, "system-reminder alone")
    expect("<system-reminder>one</system-reminder>\n<system-reminder>two</system-reminder>\nFix the login bug", "Fix the login bug", "reminders then a prompt")
    expect("<system-reminder>cut off at the size limit", nil, "an unterminated reminder")
    expect("Fix it <system-reminder>noise</system-reminder>", "Fix it", "a reminder after the prompt")
    expect("<task-notification>\n<task-id>1</task-id>\n<status>completed</status>\n</task-notification>", nil, "task-notification")
    expect("<local-command-stdout>Set model to sonnet</local-command-stdout>", nil, "local-command-stdout")
    expect("<local-command-stderr>boom</local-command-stderr>", nil, "local-command-stderr")
    expect("<local-command-caveat>Caveat: do not respond</local-command-caveat>", nil, "local-command-caveat")
    expect("<ide_opened_file>The user opened the file /a/b.swift in the IDE.</ide_opened_file>\nWhy does this crash?", "Why does this crash?", "ide_opened_file then a prompt")
    expect("<ide_selection>let x = 1</ide_selection>", nil, "ide_selection alone")
    expect("<SYSTEM-REMINDER>shout</SYSTEM-REMINDER>", nil, "tag case")
    print("PASS Claude wrappers")

    expect("<environment_context>\n  <cwd>/work</cwd>\n  <shell>zsh</shell>\n</environment_context>", nil, "environment_context alone")
    expect("<user_instructions>\nBe brief.\n</user_instructions>", nil, "user_instructions alone")
    expect("# AGENTS.md instructions for /work\n\n<INSTRUCTIONS>\nUse bun.\n</INSTRUCTIONS>", nil, "AGENTS.md preamble")
    expect(
      "# AGENTS.md instructions for /work\n\n<INSTRUCTIONS>\nUse bun.\n</INSTRUCTIONS>\n<environment_context>\n<cwd>/work</cwd>\n</environment_context>\nAdd a retry to the uploader",
      "Add a retry to the uploader", "preamble, environment, then the prompt")
    expect("# AGENTS.md instructions for /work\n\n<INSTRUCTIONS>\nUse bun.", nil, "an unterminated INSTRUCTIONS block")
    expect(
      "Background (from the session that started this one):\nThe pricing page loads slowly on phones.",
      "The pricing page loads slowly on phones.", "a started session's Background line")
    print("PASS Codex wrappers")

    expect("<pasted_content id=\"p1\">stack trace line one\nline two</pasted_content>", "stack trace line one", "pasted text alone")
    expect("Why does this fail?\n<pasted_content id=\"p1\">Error: boom</pasted_content>", "Why does this fail?", "typed text beside pasted text")
    expect("<pasted_content id=\"p1\">Error: boom</pasted_content>\nWhy does this fail?", "Why does this fail?", "typed text after pasted text")
    expect("<pasted_content id=\"p1\">\n\n</pasted_content><pasted_content id=\"p2\">second</pasted_content>", "second", "the first non-empty pasted text")
    print("PASS pasted content")

    expect("  Fix \t the   bug  \nsecond line", "Fix the bug", "first line, whitespace collapsed")
    expect("\n\n  \nReal first line\nnext", "Real first line", "leading blank lines")
    expect("<custom-wrapper>do the thing</custom-wrapper>", "do the thing", "an unknown wrapper is unwrapped")
    expect("<outer><inner>nested text</inner></outer>", "nested text", "nested unknown wrappers")
    expect("<custom-wrapper>\nthe thing\nmore\n</custom-wrapper>", "the thing", "an unknown wrapper over lines")
    expect("<br/>after a tag", "after a tag", "a self-closing tag")
    expect("</system-reminder>\nFix the login bug", "Fix the login bug", "a stray closing tag on the first line")
    expect("</a></b>\n\n<br/>\nFix the login bug", "Fix the login bug", "stray tags alone on several lines")
    expect("</system-reminder>", nil, "a stray tag alone")
    expect("a < b and 3 <4 are fine", "a < b and 3 <4 are fine", "a bare angle bracket is text")
    expect("", nil, "empty")
    expect("   \n  ", nil, "blank")
    expect(String(repeating: "x", count: 500), String(repeating: "x", count: 200), "clipped at 200")
    let emoji = SyncTitle.make(from: String(repeating: "🌳", count: 300))
    check(emoji?.unicodeScalars.count == 200, "clipped on scalars, not bytes")
    print("PASS plain text, unwrapping and clipping")

    try speed()
    try transcripts()
  }

  /// A message can be 500,000 characters and titling runs under the fold lock: a block that
  /// never closes, repeated, must cost one pass, not one pass per opening.
  static func speed() throws {
    let limit = 500_000
    let inputs: [(String, String)] = [
      ("<system-reminder>", "reminder"),
      ("<instructions x", "instructions with no >"),
      ("<pasted_content>", "pasted_content"),
    ]
    for (unit, label) in inputs {
      let text = "Fix the login bug\n" + String(String(repeating: unit, count: limit / unit.count).prefix(limit))
      check(text.count >= limit, "\(label): input is long enough")
      let done = DispatchSemaphore(value: 0)
      let box = Box()
      let started = Date()
      Thread.detachNewThread {
        box.value = SyncTitle.make(from: text)
        done.signal()
      }
      // Allowed 2 s: the script builds unoptimised, on a loaded Mac.
      guard done.wait(timeout: .now() + 2) == .success else {
        check(false, "\(label): \(limit) characters of unclosed tags still running after 2 s")
        return
      }
      let seconds = Date().timeIntervalSince(started)
      check(box.value == "Fix the login bug", "\(label): got \(String(describing: box.value))")
      print(String(format: "  %@: %d characters in %.3f s", label, text.count, seconds))
    }
    print("PASS unclosed tags are linear")
  }

  final class Box: @unchecked Sendable { var value: String? }

  /// A conversation that opens with wrappers is titled by its first real prompt. Messages
  /// keep their text, except blocks a tool injected beside what the person typed.
  static func transcripts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("work")
    let claude = root.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: claude.appendingPathComponent("projects/p"), withIntermediateDirectories: true)
    func write(_ rows: [[String: Any]], to url: URL) throws {
      var data = Data()
      for row in rows { data.append(try syncJSON(row)); data.append(10) }
      try data.write(to: url)
    }
    func claudeRow(_ id: String, _ role: String, _ text: String) -> [String: Any] {
      [
        "sessionId": "thread", "uuid": id, "cwd": workspace.path, "type": role,
        "timestamp": "2026-10-16T12:00:00.000Z", "message": ["content": text],
      ]
    }
    let clear = "<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"
    let log = claude.appendingPathComponent("projects/p/thread.jsonl")
    try write(
      [
        claudeRow("a", "user", clear),
        claudeRow("b", "user", "<local-command-stdout></local-command-stdout>"),
        claudeRow("c", "user", "<system-reminder>context</system-reminder>\nAdd retries to the uploader\nthen test"),
        claudeRow("d", "assistant", "Done"),
      ], to: log)
    let source = SessionSyncSource(provider: "claude", path: claude.path)
    let found = try SessionCollector.discover(source)
    check(found.count == 1, "one Claude candidate")
    let snapshot = try SessionCollector.snapshot(found[0], credential: "")
    check(snapshot.title == "Add retries to the uploader", "title after /clear: \(snapshot.title)")
    check(snapshot.messages.first?.text == clear, "the /clear record is still sent as it was")
    check(snapshot.messages.count == 4, "every message is still sent")
    check(
      snapshot.messages[2].text == "Add retries to the uploader\nthen test",
      "the reminder is cut out of the message that carried it: \(snapshot.messages[2].text)")

    // A named chat keeps its name; a chat of only wrappers falls back to its id.
    try write(
      [claudeRow("a", "user", clear), ["type": "custom-title", "sessionId": "thread", "customTitle": "Named"]], to: log)
    let named = try SessionCollector.snapshot(found[0], credential: "")
    check(named.title == "Named", "a custom title still wins: \(named.title)")
    try write([claudeRow("a", "user", clear)], to: log)
    let bare = try SessionCollector.snapshot(found[0], credential: "")
    check(bare.title == "thread", "no usable message falls back to the id: \(bare.title)")
    print("PASS Claude transcript titled by its first real prompt")

    let codex = root.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let rollout = codex.appendingPathComponent("rollout.jsonl")
    func codexRow(_ text: String) -> [String: Any] {
      [
        "timestamp": "2026-10-16T12:00:01.000Z", "type": "response_item",
        "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]],
      ]
    }
    let environment = "<environment_context>\n  <cwd>\(workspace.path)</cwd>\n</environment_context>"
    try write(
      [
        ["timestamp": "2026-10-16T12:00:00.000Z", "type": "session_meta",
         "payload": ["id": "cx", "cwd": workspace.path]],
        codexRow("# AGENTS.md instructions for \(workspace.path)\n\n<INSTRUCTIONS>\nUse bun.\n</INSTRUCTIONS>"),
        codexRow(environment),
        codexRow("Fix the flaky sync test"),
      ], to: rollout)
    let candidate = SyncCandidate(
      source: SessionSyncSource(provider: "codex", path: codex.path), id: "cx",
      metadata: ["cwd": workspace.path, "rollout_path": rollout.path, "updated_at": "1000"])
    let opened = try SessionCollector.snapshot(candidate, credential: "")
    check(opened.title == "Fix the flaky sync test", "Codex title after its preamble: \(opened.title)")
    check(
      opened.messages.map(\.text) == ["Fix the flaky sync test"],
      "the instruction file and the environment are not messages: \(opened.messages.map(\.text))")
    print("PASS Codex rollout titled by its first real prompt")
  }
}

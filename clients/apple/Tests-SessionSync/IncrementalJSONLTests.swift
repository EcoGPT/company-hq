import CryptoKit
import Foundation
import XCTest

struct IncrementalJSONLTests {
  static func run() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? files.removeItem(at: root) }
    let workspace = root.appendingPathComponent("work").path
    let claude = root.appendingPathComponent(".claude")
    let project = claude.appendingPathComponent("projects/p")
    try files.createDirectory(at: project, withIntermediateDirectories: true)
    // The work folder is a git checkout: files_touched are relative to it.
    try files.createDirectory(atPath: workspace + "/.git", withIntermediateDirectories: true)
    let cache = SessionCollector.transcripts
    let credential = "incremental-test-credential"

    func line(_ row: [String: Any]) throws -> Data { try syncJSON(row) + Data([10]) }
    func row(_ id: String, _ content: Any, type: String = "user", stamp: Int = 0, extra: [String: Any] = [:])
      -> [String: Any]
    {
      var value: [String: Any] = [
        "sessionId": "thread", "uuid": id, "cwd": workspace, "type": type, "gitBranch": "main",
        "timestamp": String(format: "2026-10-02T12:%02d:%02d.000Z", stamp / 60, stamp % 60),
        "message": ["content": content],
      ]
      value.merge(extra) { _, new in new }
      return value
    }
    func use(_ id: String, _ name: String, _ input: [String: Any], stamp: Int) -> [String: Any] {
      row("u-" + id, [["type": "tool_use", "id": id, "name": name, "input": input]], type: "assistant", stamp: stamp)
    }
    func result(_ id: String, _ output: String, stamp: Int, error: Bool = false) -> [String: Any] {
      row("r-" + id, [["type": "tool_result", "tool_use_id": id, "content": output, "is_error": error]], stamp: stamp)
    }
    let log = project.appendingPathComponent("thread.jsonl")
    func write(_ data: Data, atomic: Bool = false) throws {
      try data.write(to: log, options: atomic ? .atomic : [])
    }
    func append(_ data: Data) throws {
      let handle = try FileHandle(forWritingTo: log)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    }
    func candidate() throws -> SyncCandidate {
      let found = try SessionCollector.discover(
        .init(provider: "claude", path: claude.path))
      check(found.count == 1, "one candidate: \(found.map(\.id))")
      return found[0]
    }
    func snapshot(_ candidate: SyncCandidate) throws -> SyncSnapshot {
      try SessionCollector.snapshot(candidate, credential: credential)
    }
    /// What a cold helper (no cache) produces from the same bytes.
    func full(_ candidate: SyncCandidate) throws -> SyncSnapshot {
      cache.removeAll()
      return try snapshot(candidate)
    }
    func same(_ a: SyncSnapshot, _ b: SyncSnapshot) throws -> Bool {
      try a.hash == b.hash && NSDictionary(dictionary: a.json).isEqual(to: b.json)
        && a.activityAt == b.activityAt && a.filesTouched == b.filesTouched && a.title == b.title
        && a.branch == b.branch
    }

    // Append-only: the incremental fold equals a full read, and reads only the appended bytes.
    var initial = Data()
    for value in [
      row("one", "First question", stamp: 1),
      use("call-1", "Edit", ["file_path": workspace + "/a.swift", "old_string": "a", "new_string": "b"], stamp: 2),
      row("two", [["type": "text", "text": "Working on it"]], type: "assistant", stamp: 3),
    ] { initial += try line(value) }
    try write(initial)
    let thread = try candidate()
    let first = try snapshot(thread)
    check(first.messages.count == 2)
    var appended = Data()
    for value in [
      result("call-1", "Edited a.swift", stamp: 4),
      use("call-2", "Write", ["file_path": "b.md", "content": "x"], stamp: 5),
      result("call-2", "denied", stamp: 6, error: true),
      row("two", [["type": "text", "text": "Revised answer"]], type: "assistant", stamp: 7),
      ["type": "custom-title", "sessionId": "thread", "customTitle": "  Named thread  "],
      row("three", "Follow-up", stamp: 8, extra: ["gitBranch": "feature"]),
    ] { appended += try line(value) }
    try append(appended)
    cache.resetStats()
    let incremental = try snapshot(thread)
    check(cache.stats.bytesRead == appended.count, "read \(cache.stats.bytesRead) of \(appended.count) appended bytes")
    check(cache.stats.linesParsed == 6 && cache.stats.fullReads == 0, "\(cache.stats)")
    check(incremental.messages.map(\.text) == ["First question", "Revised answer", "Follow-up"])
    check(incremental.title == "Named thread")
    check(incremental.branch == "feature" && incremental.filesTouched == ["b.md", "a.swift"], "\(incremental.filesTouched)")
    let cold = try full(thread)
    check(try same(incremental, cold), "incremental fold equals a full read")
    print("PASS append-only incremental fold equals a full read and reads only appended bytes")

    // Unchanged: one stat, the same snapshot revision, no bytes read.
    let warm = try snapshot(thread)
    _ = try candidate()
    cache.resetStats()
    let again = try snapshot(thread)
    _ = try candidate()
    check(cache.stats.bytesRead == 0 && cache.stats.linesParsed == 0, "unchanged file read: \(cache.stats)")
    check(again.revision != nil && again.revision == warm.revision, "unchanged snapshot keeps its revision")
    // Rapid changes between passes are folded once, in one read.
    var burst = Data()
    for index in 0..<5 {
      let chunk = try line(row("burst-\(index)", "Burst \(index)", stamp: 10 + index))
      try append(chunk)
      burst += chunk
    }
    cache.resetStats()
    let batched = try snapshot(thread)
    check(cache.stats.linesParsed == 5 && cache.stats.bytesRead == burst.count, "\(cache.stats)")
    check(batched.revision != again.revision, "a changed transcript gets a new revision")
    check(try same(batched, try full(thread)))
    print("PASS unchanged transcript costs a stat; rapid appends fold once per pass")

    // A partial trailing record is held back until its newline arrives.
    let pending = try line(row("four", "Half-written", stamp: 20))
    let split = pending.count / 2
    _ = try snapshot(thread)
    try append(pending.prefix(split))
    let partial = try snapshot(thread)
    check(!partial.messages.contains { $0.text == "Half-written" })
    check(try same(partial, try full(thread)), "partial line ignored exactly as a full read does")
    _ = try snapshot(thread)
    try append(pending.suffix(from: split))
    cache.resetStats()
    let completed = try snapshot(thread)
    check(completed.messages.last?.text == "Half-written" && cache.stats.linesParsed == 1, "\(cache.stats)")
    check(try same(completed, try full(thread)))
    print("PASS partial trailing record held back, then folded once complete")

    // Truncation, replacement and in-place rewrites refold from the start.
    _ = try snapshot(thread)
    try write(initial)
    cache.resetStats()
    let truncated = try snapshot(thread)
    check(cache.stats.fullReads == 1 && truncated.messages.map(\.text) == ["First question", "Working on it"])
    check(try same(truncated, try full(thread)))
    _ = try snapshot(thread)
    var rewritten = Data()
    for value in [
      row("one", "Other question", stamp: 1),
      use("call-1", "Edit", ["file_path": workspace + "/z.swift", "old_string": "a", "new_string": "b"], stamp: 2),
      row("two", [["type": "text", "text": "Working on it"]], type: "assistant", stamp: 3),
    ] { rewritten += try line(value) }
    check(rewritten.count == initial.count, "same-size rewrite fixture")
    try write(rewritten + appended)
    cache.resetStats()
    let inPlace = try snapshot(thread)
    check(cache.stats.fullReads == 1 && inPlace.messages.first?.text == "Other question", "\(cache.stats)")
    check(try same(inPlace, try full(thread)))
    _ = try snapshot(thread)
    try write(initial, atomic: true)
    cache.resetStats()
    let replaced = try snapshot(thread)
    check(cache.stats.fullReads == 1 && replaced.messages.first?.text == "First question")
    check(try same(replaced, try full(thread)))
    print("PASS truncation, same-inode rewrite and atomic replacement refold from the start")

    // A malformed record fails the same way every pass, without re-reading, until replaced.
    _ = try snapshot(thread)
    try append(Data("{broken}\n".utf8))
    func refused() -> Bool {
      do { _ = try snapshot(thread); return false } catch { return true }
    }
    check(refused(), "malformed completed records are refused")
    try append(try line(row("five", "After the break", stamp: 30)))
    cache.resetStats()
    check(refused() && cache.stats.bytesRead == 0, "the remembered failure is rethrown without reading")
    cache.removeAll()
    check(refused(), "a full read refuses the same bytes")
    try write(initial)
    check(try same(try snapshot(thread), try full(thread)), "a repaired transcript syncs again")
    print("PASS malformed record refusal is remembered per prefix and cleared by a rewrite")

    // Codex rollouts: line-numbered message ids continue across appends.
    let codex = root.appendingPathComponent(".codex")
    let rollouts = codex.appendingPathComponent("sessions")
    try files.createDirectory(at: rollouts, withIntermediateDirectories: true)
    let rollout = rollouts.appendingPathComponent("rollout.jsonl")
    func codexLine(_ type: String, _ payload: [String: Any], _ stamp: Int) throws -> Data {
      try line(["type": type, "timestamp": String(format: "2026-10-02T13:00:%02d.000Z", stamp), "payload": payload])
    }
    func message(_ role: String, _ text: String, _ stamp: Int) throws -> Data {
      try codexLine("response_item", ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]], stamp)
    }
    var codexData = try codexLine("session_meta", ["id": "rollout-thread", "cwd": workspace], 0)
    codexData += try message("user", "Codex question", 1)
    codexData += try codexLine("response_item", ["type": "function_call", "call_id": "c1", "name": "shell", "arguments": "{\"cmd\":[\"ls\"]}"], 2)
    try codexData.write(to: rollout)
    let codexCandidate = SyncCandidate(
      source: .init(provider: "codex", path: codex.path), id: "rollout-thread",
      metadata: ["cwd": workspace, "rollout_path": rollout.path, "title": "Codex", "updated_at": "1000"])
    _ = try SessionCollector.snapshot(codexCandidate, credential: credential)
    let more = try codexLine("response_item", ["type": "function_call_output", "call_id": "c1", "output": "a\nb"], 3)
      + message("assistant", "Codex answer", 4)
    let handle = try FileHandle(forWritingTo: rollout)
    try handle.seekToEnd()
    try handle.write(contentsOf: more)
    try handle.close()
    cache.resetStats()
    let codexIncremental = try SessionCollector.snapshot(codexCandidate, credential: credential)
    check(cache.stats.linesParsed == 2 && codexIncremental.messages.map(\.id) == ["line-2", "line-5"], "\(codexIncremental.messages.map(\.id))")
    cache.removeAll()
    let codexFull = try SessionCollector.snapshot(codexCandidate, credential: credential)
    check(try same(codexIncremental, codexFull))
    var renamed = codexCandidate
    renamed.metadata["title"] = "Renamed"
    renamed.metadata["updated_at"] = "1900000000"
    let metadataChanged = try SessionCollector.snapshot(renamed, credential: credential)
    check(metadataChanged.title == "Renamed" && metadataChanged.activityAt == 1_900_000_000_000)
    check(metadataChanged.revision != codexFull.revision, "metadata changes re-finish the snapshot")
    print("PASS Codex rollout incremental fold, line-numbered ids, metadata-only changes")

    // Discovery folds a resumed transcript's leading records once, and resumes when the own id arrives.
    let resumed = project.appendingPathComponent("child.jsonl")
    var parent = Data()
    for index in 0..<120 {
      parent += try line(["sessionId": "parent", "uuid": "p\(index)", "cwd": workspace, "type": "user",
                          "timestamp": "2026-10-02T11:00:00.000Z", "message": ["content": "Parent \(index)"]])
    }
    try parent.write(to: resumed)
    var issues: [String] = []
    _ = try SessionCollector.discover(.init(provider: "claude", path: claude.path), onIssue: { issues.append($0) })
    check(!issues.contains { $0.contains("child") }, "a copy with no turn of its own yet waits quietly")
    let own = try line(["sessionId": "child", "uuid": "c1", "cwd": workspace, "type": "user",
                        "timestamp": "2026-10-02T12:00:00.000Z", "message": ["content": "Child"]])
    let childHandle = try FileHandle(forWritingTo: resumed)
    try childHandle.seekToEnd()
    try childHandle.write(contentsOf: own)
    try childHandle.close()
    cache.resetStats()
    let found = try SessionCollector.discover(.init(provider: "claude", path: claude.path))
    check(Set(found.map(\.id)) == ["thread", "child"] && cache.stats.linesParsed == 1, "\(found.map(\.id)) \(cache.stats)")
    cache.resetStats()
    _ = try SessionCollector.discover(.init(provider: "claude", path: claude.path))
    check(cache.stats.bytesRead == 0, "discovery of unchanged transcripts reads nothing")
    print("PASS discovery folds leading records once and resumes on append")
  }
}

import Foundation

// Fixtures shared by the helper's tests and the hosted ones (`HQTests` compiles this
// folder too). Foundation only.

/// A scratch folder per test, removed afterwards.
final class Scratch {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("hq-sync-" + UUID().uuidString)
    .resolvingSymlinksInPath()
  init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
  deinit { try? FileManager.default.removeItem(at: root) }

  func folder(_ path: String) throws -> URL {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Writes JSON lines the way Claude Code and Codex do.
  func writeLines(_ rows: [[String: Any]], to url: URL, tail: String = "") throws {
    var data = Data()
    for row in rows {
      data.append(try syncJSON(row))
      data.append(10)
    }
    data.append(Data(tail.utf8))
    try data.write(to: url)
  }
}

/// A Claude Code transcript row.
func claudeRow(
  _ id: String, _ role: String = "user", _ content: Any, session: String = "thread", cwd: String,
  stamp: String = "2026-10-20T12:00:00.000Z", extra: [String: Any] = [:]
) -> [String: Any] {
  var row: [String: Any] = [
    "sessionId": session, "uuid": id, "cwd": cwd, "type": role, "timestamp": stamp,
    "message": ["content": content],
  ]
  row.merge(extra) { _, new in new }
  return row
}

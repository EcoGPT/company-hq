import CryptoKit
import Foundation
import SQLite3

enum SyncFailure: String, Error {
  case source = "Source is unavailable or its format is unsupported"
  case scope = "Conversation is outside its Claude or Codex folder"
  case oversized = "Conversation exceeds the 1 MiB limit"
  case empty = "Waiting for conversation text"
  case identity = "Conversation identity is missing or ambiguous"
  case receipt = "The server's copy did not match; will retry"
  case destination = "The server address is not allowed"
}

struct SyncMessage: Codable {
  var id: String
  var role: String
  var text: String
  var timestamp: String?
  var json: [String: Any] {
    ["id": id, "role": role, "text": text, "timestamp": timestamp as Any? ?? NSNull()]
  }
}

struct SyncSnapshot {
  var title: String
  var cwd: String
  var branch: String?
  var messages: [SyncMessage]
  var activityAt: Double? = nil
  /// Relative to the git checkout holding each file, most recent first. Coordination metadata, not snapshot content.
  var filesTouched: [String] = []
  /// Identifies this exact snapshot within the helper process, so an unchanged
  /// transcript's acknowledgement is not rehashed every pass. Never sent.
  var revision: String? = nil
  var json: [String: Any] {
    [
      "projection": "conversation-text-v1", "title": title, "cwd": cwd,
      "git_branch": branch as Any? ?? NSNull(), "task_ref": NSNull(),
      "messages": messages.map(\.json),
    ]
  }
  var hash: String {
    get throws {
      let envelope: [Any] = [
        "conversation-text-v1", title, cwd, branch as Any? ?? NSNull(), NSNull(),
        messages.map { [$0.id, $0.role, $0.text, $0.timestamp as Any? ?? NSNull()] as [Any] },
      ]
      return SHA256.hash(data: try syncJSON(envelope)).map { String(format: "%02x", $0) }.joined()
    }
  }
}

func syncJSON(_ value: Any) throws -> Data {
  try JSONSerialization.data(
    withJSONObject: value, options: [.withoutEscapingSlashes, .fragmentsAllowed])
}

func syncWithin(_ path: String, _ folder: String) -> Bool {
  let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
  let w = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
  return p == w || p.hasPrefix(w == "/" ? "/" : w + "/")
}

final class SyncDatabase {
  private var db: OpaquePointer?
  init(_ url: URL) throws {
    // Codex keeps WAL databases. While Codex is closed there is no -shm/-wal and
    // a read-only open cannot create them (SQLITE_CANTOPEN); with no -wal file
    // there is nothing uncommitted, so an immutable read sees the whole database.
    if !Self.open(url.path, SQLITE_OPEN_READONLY, &db) {
      guard !FileManager.default.fileExists(atPath: url.path + "-wal"),
        var uri = URLComponents(string: "file:")
      else { throw SyncFailure.source }
      uri.path = url.path
      uri.queryItems = [URLQueryItem(name: "immutable", value: "1")]
      guard let immutable = uri.string,
        Self.open(immutable, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, &db)
      else { throw SyncFailure.source }
    }
  }
  private static func open(_ path: String, _ flags: Int32, _ db: inout OpaquePointer?) -> Bool {
    if sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK {
      sqlite3_busy_timeout(db, 2000)
      if sqlite3_exec(db, "PRAGMA query_only=ON; BEGIN; SELECT count(*) FROM sqlite_master", nil, nil, nil)
        == SQLITE_OK
      {
        return true
      }
    }
    sqlite3_close(db)
    db = nil
    return false
  }
  deinit { sqlite3_close(db) }
  func each(_ sql: String, id: String? = nil, _ visit: ([String: String]) throws -> Void) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw SyncFailure.source
    }
    defer { sqlite3_finalize(statement) }
    if let id {
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      guard sqlite3_bind_text(statement, 1, id, -1, transient) == SQLITE_OK else {
        throw SyncFailure.source
      }
    }
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return }
      guard code == SQLITE_ROW else { throw SyncFailure.source }
      var row: [String: String] = [:]
      for col in 0..<sqlite3_column_count(statement) {
        if let value = sqlite3_column_text(statement, col),
          let name = sqlite3_column_name(statement, col)
        {
          row[String(cString: name)] = String(cString: value)
        }
      }
      try visit(row)
    }
  }
}

struct SyncCandidate {
  var source: SessionSyncSource
  var id: String
  /// A Claude conversation's transcripts, oldest first. A chat that moves to
  /// another project folder (a worktree) mid-session continues in a new file.
  var paths: [URL]
  var metadata: [String: String]
  var archived = false
  var key: String { source.provider + "/" + id }
  init(
    source: SessionSyncSource, id: String, path: URL? = nil, metadata: [String: String],
    archived: Bool = false
  ) {
    self.source = source
    self.id = id
    self.paths = path.map { [$0] } ?? []
    self.metadata = metadata
    self.archived = archived
  }
}

enum SessionCollector {
  /// The server's cap on one snapshot upload: the whole JSON request body, envelope included.
  static let maxBytes = 1024 * 1024
  static let maxLine = 16 * 1024 * 1024

  /// Folds append-only JSONL across passes; see `IncrementalJSONL`.
  static var transcripts: IncrementalJSONL { .shared }

  static func validID(_ id: String) -> Bool {
    id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
  }

  /// Claude's `entrypoint` for a print run (`claude -p`) a program started.
  /// Only this one: `sdk-ts` and `sdk-py` are the Agent SDKs, which interactive
  /// tools also run on, so they must sync.
  static let scriptEntrypoints: Set<String> = ["sdk-cli"]

  /// A `codex exec` run: its threads row (mirroring the rollout's
  /// `session_meta`) says `source` exec or `originator` codex_exec.
  static func isScriptRun(codex row: [String: String]) -> Bool {
    row["source"] == "exec" || row["originator"] == "codex_exec"
  }

  /// A thread Codex started itself: an automatic approval review (Guardian) or a
  /// helper another thread spawned. Its `source` is an object keyed `subagent`:
  /// JSON text in the threads row, decoded in the rollout's `session_meta`.
  static func isSubagent(codexSource source: Any?) -> Bool {
    if let text = source as? String {
      guard text.hasPrefix("{") else { return false }
      return isSubagent(codexSource: try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }
    return (source as? [String: Any])?["subagent"] != nil
  }

  /// A chat is a candidate while its last activity is this recent, from any folder.
  static let activeWindow: TimeInterval = 7 * 24 * 3600

  /// Last activity of a Codex `threads` row, in seconds: `updated_at_ms`, else
  /// `updated_at`, else `created_at` (older schemas and fixtures).
  static func activity(codex row: [String: String]) -> Double? {
    if let milliseconds = row["updated_at_ms"].flatMap(Double.init), milliseconds > 0 {
      return milliseconds / 1000
    }
    return [row["updated_at"], row["created_at"]].lazy.compactMap { $0.flatMap(Double.init) }
      .first { $0 > 0 }
  }

  /// Candidates are chats active within `activeWindow` of `now`, in any folder.
  /// Script runs are never candidates: skipped quietly. Nothing is sent for them,
  /// so a row the server already holds is left as it is. A Codex subagent thread
  /// is no one's chat either: it comes back archived, so it is never uploaded and
  /// a row an earlier run uploaded is archived on the server.
  static func discover(
    _ source: SessionSyncSource, now: Date = Date(),
    onIssue: ((String) -> Void)? = nil
  ) throws -> [SyncCandidate] {
    let cutoff = now.timeIntervalSince1970 - activeWindow
    let home = URL(fileURLWithPath: source.path)
    guard FileManager.default.fileExists(atPath: home.path) else {
      paginated.retain(source: source.path, ids: [])
      return []
    }
    if source.provider == "codex" {
      let files = try FileManager.default.contentsOfDirectory(
        at: home, includingPropertiesForKeys: nil)
      let indexes = files.filter {
        $0.lastPathComponent.range(of: "^state_[0-9]+\\.sqlite$", options: .regularExpression)
          != nil
      }
      guard
        let index = indexes.max(by: {
          $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending
        })
      else {
        paginated.retain(source: source.path, ids: [])
        return []
      }
      let db = try SyncDatabase(index)
      var names: [String: String] = [:]
      let nameIndex = home.appendingPathComponent("session_index.jsonl")
      if FileManager.default.fileExists(atPath: nameIndex.path) {
        guard syncWithin(nameIndex.path, home.path) else { throw SyncFailure.scope }
        names = try transcripts.fold(
          nameIndex, purpose: "codex-index", initial: { [String: String]() }
        ) { names, _, row in
          if let id = row["id"] as? String, let name = row["thread_name"] as? String {
            names[id] = name.trimmingCharacters(in: .whitespacesAndNewlines)
          }
          return true
        }.state
      }
      var found: [SyncCandidate] = []
      try db.each("SELECT * FROM threads") { row in
        guard let id = row["id"], validID(id), !isScriptRun(codex: row), row["cwd"] != nil,
          activity(codex: row).map({ $0 >= cutoff }) == true
        else { return }
        var metadata = row
        metadata["title"] = [row["name"], names[id], row["title"]]
          .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
          .first { !$0.isEmpty }
        found.append(
          SyncCandidate(
            source: source, id: id, metadata: metadata,
            archived: row["archived"] == "1" || isSubagent(codexSource: row["source"])))
      }
      paginated.retain(source: source.path, ids: Set(found.map(\.id)))
      keepTranscripts(found)
      return found
    }
    guard source.provider == "claude" else { throw SyncFailure.source }
    let projects = home.appendingPathComponent("projects")
    guard FileManager.default.fileExists(atPath: projects.path) else { return [] }
    let archived = archivedClaudeSessions(home)
    var found: [SyncCandidate] = []
    // Per conversation: its index in `found` and each file's first own timestamp.
    var joined: [String: (index: Int, starts: [Double])] = [:]
    // A conversation is a candidate when any of its files was written inside the
    // window; then all of its files are read, so a chat that
    // moved to a worktree long ago still joins its first file. Listing costs a
    // stat per file; only a candidate's files are folded.
    var logs: [URL] = []
    var wanted: Set<String> = []
    for project in try FileManager.default.contentsOfDirectory(
      at: projects, includingPropertiesForKeys: [.isDirectoryKey])
    {
      guard try project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
        continue
      }
      for log in try FileManager.default.contentsOfDirectory(
        at: project, includingPropertiesForKeys: nil)
      where log.pathExtension == "jsonl" && validID(log.deletingPathExtension().lastPathComponent) {
        let name = log.deletingPathExtension().lastPathComponent
        let modified = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate
        logs.append(log)
        if modified.map({ $0.timeIntervalSince1970 >= cutoff }) ?? true {
          wanted.insert(name)
        }
      }
    }
    for log in logs where wanted.contains(log.deletingPathExtension().lastPathComponent) {
      do {
        guard syncWithin(log.path, source.path) else { throw SyncFailure.scope }
        // A resumed/forked transcript starts with its parent's records (their
        // sessionId); cwd and creation time come from the first own record.
        // Only the leading records decide this, so it is folded once per file.
        let own = log.deletingPathExtension().lastPathComponent
        let head = try transcripts.fold(log, purpose: "claude-head", initial: { ClaudeHead() }) {
          head, number, row in
          if let id = row["sessionId"] as? String, id != own {
            head.inherited = true
            return true
          }
          if let cwd = row["cwd"] as? String, let id = row["sessionId"] as? String {
            head.own = (id, cwd, row["timestamp"] as? String)
            head.isScript = scriptEntrypoints.contains(row["entrypoint"] as? String ?? "")
            return false
          }
          if row["sessionId"] as? String == own, ["user", "assistant"].contains(row["type"] as? String) {
            head.hasOwnTurn = true
          }
          return number < 100 || head.inherited
        }.state
        if let own = head.own, !head.isScript {
          guard let stamp = own.stamp, let created = timestamp(stamp) else { throw SyncFailure.source }
          if let known = joined[own.id] {
            // The same conversation in another project folder: it moved
            // mid-session. One candidate, its files in time order.
            let at = known.starts.firstIndex { $0 > created } ?? known.starts.count
            found[known.index].paths.insert(log, at: at)
            joined[own.id]?.starts.insert(created, at: at)
            if at == 0 { found[known.index].metadata["cwd"] = own.cwd }
          } else {
            joined[own.id] = (found.count, [created])
            found.append(
              SyncCandidate(
                source: source, id: own.id, path: log,
                metadata: ["cwd": own.cwd], archived: archived.contains(own.id)))
          }
        }
        // A copy (another session's records under this name, its own only
        // metadata) has no turns of its own: that session syncs from its own
        // file, so this one is skipped quietly. An own turn that cannot be
        // placed is still an error.
        if head.inherited && head.own == nil && head.hasOwnTurn { throw SyncFailure.identity }
      } catch {
        if let onIssue {
          onIssue(
            "Claude thread " + log.deletingPathExtension().lastPathComponent
              + ": source unavailable or unsupported")
        } else {
          throw error
        }
      }
    }
    keepTranscripts(found)
    return found
  }

  /// A discovered chat's folded transcript stays through this pass's sweep even when
  /// the pass never reaches its fold (an upload that failed first). An archived one
  /// is never folded again, so its state goes.
  private static func keepTranscripts(_ found: [SyncCandidate]) {
    for candidate in found where !candidate.archived {
      guard let files = transcriptFiles(candidate) else { continue }
      for path in files.paths { transcripts.keep(path, purpose: files.purpose) }
    }
  }

  /// A JSONL chat's transcript files, oldest first, and the purpose they fold under;
  /// nil for Codex paginated history (read from SQLite) or a missing rollout path.
  /// Not checked against the source folder: `snapshot` does that.
  static func transcriptFiles(_ candidate: SyncCandidate) -> (paths: [URL], purpose: String)? {
    guard candidate.source.provider == "codex" else { return (candidate.paths, "claude-transcript") }
    guard candidate.metadata["history_mode"] != "paginated", let rollout = candidate.metadata["rollout_path"]
    else { return nil }
    return ([URL(fileURLWithPath: rollout)], "codex-rollout")
  }

  /// The Claude desktop app keeps per-chat metadata beside each account's
  /// CLAUDE_CONFIG_DIR (`<profile>/code-config`) in `<profile>/claude-code-sessions`.
  /// A transcript is archived when every desktop record naming it is archived.
  /// Cards are parsed again only when their inode, size or modification time changes.
  static func archivedClaudeSessions(_ home: URL) -> Set<String> {
    let root = home.deletingLastPathComponent().appendingPathComponent("claude-code-sessions")
    guard home.lastPathComponent == "code-config",
      let files = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [])
    else { return [] }
    let known = cards.entries(root.path)
    var seen: [String: CardMemo.Entry] = [:]
    var archived: Set<String> = []
    var visible: Set<String> = []
    for case let url as URL in files where url.pathExtension == "json" {
      var info = stat()
      guard lstat(url.path, &info) == 0 else { continue }
      let identity = CardMemo.Identity(
        inode: info.st_ino, size: info.st_size, seconds: info.st_mtimespec.tv_sec,
        nanoseconds: info.st_mtimespec.tv_nsec)
      let card: CardMemo.Card?
      if let entry = known[url.path], entry.identity == identity {
        card = entry.card
      } else if info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1024 * 1024 {
        // A failed read is not remembered: a chmod changes neither size nor mtime.
        guard let data = try? Data(contentsOf: url) else { continue }
        if let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = record["cliSessionId"] as? String
        {
          card = CardMemo.Card(id: id, isArchived: record["isArchived"] as? Bool == true)
        } else {
          card = nil
        }
      } else {
        card = nil
      }
      seen[url.path] = CardMemo.Entry(identity: identity, card: card)
      guard let card else { continue }
      if card.isArchived { archived.insert(card.id) } else { visible.insert(card.id) }
    }
    cards.set(root.path, seen)
    return archived.subtracting(visible)
  }

  /// Desktop cards by sessions root, for the life of the helper process.
  private static let cards = CardMemo()

  // Configured once and never mutated: a formatter per record dominated cold folds.
  private nonisolated(unsafe) static let fractionalDates: ISO8601DateFormatter = {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return parser
  }()
  private nonisolated(unsafe) static let wholeSecondDates: ISO8601DateFormatter = {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime]
    return parser
  }()

  static func timestamp(_ value: String) -> Double? {
    if let date = fractionalDates.date(from: value) { return date.timeIntervalSince1970 }
    return wholeSecondDates.date(from: value)?.timeIntervalSince1970
  }

  static func text(_ value: Any?) -> String {
    if let text = value as? String { return text }
    return (value as? [[String: Any]] ?? []).compactMap { block in
      guard let kind = block["type"] as? String,
        ["text", "input_text", "output_text"].contains(kind)
      else { return nil }
      return block["text"] as? String
    }.joined(separator: "\n")
  }

  /// Calls to `redact`, for tests that prove a pass skipped it.
  static let redactions = SyncCounter()

  /// The server's redaction list (`apps/tasks/redact.ts`),
  /// verbatim and in the same order: 13 patterns, each replaced with `[REDACTED]` wherever it
  /// matches. Every boundary is an ASCII lookaround (Swift's `\b` counts letters of every
  /// script as word characters, so `密钥sk-proj-…` would slip through) and every repeat has an
  /// upper bound (an unbounded one is rescanned from every start inside a long run).
  /// `test/fixtures/redaction-cases.json` holds the cases both sides must agree on.
  static let redactionSpecs: [(pattern: String, caseInsensitive: Bool)] = [
    ("-----BEGIN [A-Z ]{0,40}PRIVATE KEY(?: BLOCK)?-----(?:(?:(?!-----BEGIN)[\\s\\S]){0,16384}?-----END [A-Z ]{0,40}PRIVATE KEY(?: BLOCK)?-----|[A-Za-z0-9+/=:\\s,.-]{0,16384})", false),  // 1
    ("(?<![A-Za-z0-9_])hq_[A-Za-z0-9_-]{40,16384}", false),  // 2
    ("(?<![A-Za-z0-9_])(?:sk-(?:proj-|ant-)?|gh[pousr]_|github_pat_|AKIA)[A-Za-z0-9_-]{16,16384}", false),  // 3
    ("(?<![A-Za-z0-9_])Bearer\\s{1,16}[A-Za-z0-9._~+/-]{16,16384}={0,16}", true),  // 4
    ("(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,512}\\.[A-Za-z0-9_-]{8,16384}\\.[A-Za-z0-9_-]{8,16384}", false),  // 5
    ("(?:api[_-]?key|(?:secret|private)[_-]?(?:access[_-]?)?key|token|secret|password|passwd|passphrase)(?![A-Za-z0-9_])[\"']?\\s{0,8}[:=]\\s{0,8}[\"']?[A-Za-z0-9_./+~=-]{16,16384}", true),  // 6
    ("(?<![A-Za-z0-9_])(?:pscale_(?:tkn|pw)_|[sr]k_live_|whsec_|xox[abposr]-|AIza|xai-|gsk_|SG\\.)[A-Za-z0-9._-]{16,16384}", false),  // 7
    ("(?<![A-Za-z0-9_])ASIA[A-Z0-9]{16}(?![A-Za-z0-9_])", false),  // 8
    ("(?<![A-Za-z0-9_])hooks\\.slack\\.com\\/services\\/[A-Za-z0-9/]{16,512}", false),  // 9
    ("(?<![A-Za-z0-9_])[A-Z0-9_]{0,64}(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|CREDENTIALS?|_PWD)[A-Z0-9_]{0,64}[ \\t]{0,8}=[ \\t]{0,8}[\"']?[^\\s\"']{1,16384}", false),  // 10
    ("(?<![A-Za-z0-9_])[a-z][a-z0-9+.-]{0,31}:\\/\\/[^\\s:/@]{1,256}:[^\\s@/]{1,1024}@", true),  // 11
    ("(?<![A-Za-z0-9_])(?:authorization|cookie|set-cookie)[ \\t]{0,8}:[ \\t]{0,8}[^\\r\\n\"']{1,16384}", true),  // 12
    ("(?<!\\S)(?:-u|--user)[ \\t]{1,8}[^\\s:]{1,256}:\\S{1,1024}", false),  // 13
  ]

  /// Compiled once: `redact` runs for every message and title.
  static let redactionPatterns: [NSRegularExpression] = redactionSpecs.map {
    try! NSRegularExpression(pattern: $0.pattern, options: $0.caseInsensitive ? [.caseInsensitive] : [])
  }

  /// The 13 patterns, in order, over the whole text.
  static func redactPatterns(_ input: String) -> String {
    var text = input
    for pattern in redactionPatterns {
      text = pattern.stringByReplacingMatches(
        in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: "[REDACTED]")
    }
    return text
  }

  /// A key whose value is dropped whole, anywhere in the key, in any case.
  private static let secretKey = try! NSRegularExpression(
    pattern: "(api[_-]?key|token|secret|password|authorization|cookie|private[_-]?key)",
    options: [.caseInsensitive])

  private static func redactTree(_ value: Any) -> Any {
    if let list = value as? [Any] { return list.map(redactTree) }
    if let object = value as? [String: Any] {
      var safe: [String: Any] = [:]
      for (key, child) in object {
        let hit = secretKey.firstMatch(in: key, range: NSRange(location: 0, length: key.utf16.count)) != nil
        safe[key] = hit ? "[REDACTED]" : redactTree(child)
      }
      return safe
    }
    return value
  }

  /// One string, as the server hides it for another member: if it is itself JSON (an object or
  /// a list), a value under a secret-named key is dropped whole; then the 13 patterns. The JSON
  /// is written back (compact) only when a value was dropped, so ordinary text, and JSON with
  /// nothing to hide, keeps its exact formatting, and JSON cut off mid-value falls through to
  /// the patterns alone. Key order of a rewritten object is sorted, not the original.
  static func redactString(_ input: String) -> String {
    let first = input.drop(while: { $0.isWhitespace }).first
    if first == "{" || first == "[",
      let parsed = try? JSONSerialization.jsonObject(with: Data(input.utf8)),
      parsed is [String: Any] || parsed is [Any]
    {
      let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
      if let original = try? JSONSerialization.data(withJSONObject: parsed, options: options),
        let cleaned = try? JSONSerialization.data(withJSONObject: redactTree(parsed), options: options),
        cleaned != original
      {
        return redactPatterns(String(decoding: cleaned, as: UTF8.self))
      }
    }
    return redactPatterns(input)
  }

  /// `credential`: the helper's own bearer. `secrets`: values that must never leave the Mac,
  /// replaced wherever they appear (by default the helper's own secret-named environment values).
  static func redact(_ input: String, credential: String, secrets: [String] = environmentSecrets) -> String {
    redactions.add()
    var text =
      credential.count >= 16
      ? input.replacingOccurrences(of: credential, with: "[REDACTED]") : input
    text = redactString(text)
    for secret in secrets {
      text = text.replacingOccurrences(of: secret, with: "[REDACTED]")
    }
    return text
  }

  /// The values of secret-named variables (KEY, TOKEN, SECRET, PASSWORD) in `environment`.
  static func secretValues(in environment: [String: String]) -> [String] {
    environment
      .filter { $0.key.range(of: "(?i)(KEY|TOKEN|SECRET|PASSWORD)", options: .regularExpression) != nil && $0.value.count >= 8 }
      .map(\.value)
  }

  /// Found once: the helper's environment is fixed.
  static let environmentSecrets: [String] = secretValues(in: ProcessInfo.processInfo.environment)

  /// File paths named by `*** Update|Add|Delete File:` lines in an apply_patch
  /// input, which Codex nests as a raw string, JSON arguments, or argv.
  static func patchedFiles(_ value: Any?) -> [String] {
    if let text = value as? String {
      if let data = text.data(using: .utf8),
        let parsed = try? JSONSerialization.jsonObject(with: data), parsed is [Any] || parsed is [String: Any]
      {
        return patchedFiles(parsed)
      }
      guard text.contains("*** Begin Patch") else { return [] }
      return text.components(separatedBy: .newlines).compactMap { line in
        guard let match = line.range(of: "^\\*\\*\\* (Update|Add|Delete) File: ", options: .regularExpression)
        else { return nil }
        return String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
      }
    }
    if let array = value as? [Any] { return array.flatMap(patchedFiles) }
    if let object = value as? [String: Any] { return object.keys.sorted().flatMap { patchedFiles(object[$0]) } }
    return []
  }

  /// Absolute paths in source order → relative to the git checkout holding each
  /// (the deepest ancestor with a `.git` file or folder, a worktree's included),
  /// so every clone and worktree names a file alike. A path in no checkout is
  /// dropped: it has no repository-relative name. A checkout rooted at the home
  /// folder itself (a dotfiles repo) is skipped too: its names would be
  /// `.ssh/config` and the like. Most recent first, deduplicated, capped at 50.
  static func checkoutFiles(
    _ paths: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [String] {
    var roots: [String: String?] = [:]
    let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
    func checkout(_ folder: URL) -> String? {
      if let known = roots[folder.path] { return known }
      let found: String?
      if folder.path == "/" {
        found = nil
      } else if folder.resolvingSymlinksInPath().path == homePath {
        found = nil
      } else if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) {
        found = folder.path
      } else {
        found = checkout(folder.deletingLastPathComponent())
      }
      roots[folder.path] = .some(found)
      return found
    }
    var seen: Set<String> = []
    var result: [String] = []
    for path in paths.reversed() where result.count < 50 {
      let file = URL(fileURLWithPath: path).standardizedFileURL
      guard let root = checkout(file.deletingLastPathComponent()),
        file.path.hasPrefix(root + "/")
      else { continue }
      let relative = String(file.path.dropFirst(root.count + 1))
      guard !relative.isEmpty, relative.utf16.count <= 512,
        !relative.components(separatedBy: "/").contains(".."), seen.insert(relative).inserted
      else { continue }
      result.append(relative)
    }
    return result
  }

  static func credentialDigest(_ credential: String) -> String {
    SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Finished Codex paginated snapshots; see `PaginatedHistory`.
  static let paginated = PaginatedHistory()

  /// The candidate's metadata a finished snapshot depends on.
  static func snapshotInputs(_ metadata: [String: String]) throws -> String {
    let inputs = ["cwd", "title", "git_branch", "updated_at_ms", "updated_at"].map {
      metadata[$0] as Any? ?? NSNull()
    }
    return String(decoding: try syncJSON(inputs), as: UTF8.self)
  }

  /// Codex paginated history is read from SQLite, and the finished snapshot is
  /// reused while the thread's projection marker and the candidate's metadata
  /// are unchanged. JSONL transcripts (Claude, Codex rollouts) are folded
  /// incrementally and the finished snapshot is reused while neither the file
  /// nor the candidate's metadata changed.
  static func snapshot(_ candidate: SyncCandidate, credential: String) throws
    -> SyncSnapshot
  {
    try autoreleasepool {
      let metadata = candidate.metadata
      let home = URL(fileURLWithPath: candidate.source.path)
      if candidate.source.provider == "codex", metadata["history_mode"] == "paginated" {
        let db = try SyncDatabase(home.appendingPathComponent("thread_history_1.sqlite"))
        // Codex writes a thread's items and advances its projection state in one
        // transaction (codex-rs thread-store `apply_projection`), so an unchanged
        // offset and ordinal mean unchanged items. Read in the same transaction as
        // the items. Older Codex has no projection state: read every pass.
        var marker: String?
        try? db.each(
          "SELECT next_rollout_byte_offset AS offset, next_rollout_ordinal AS ordinal FROM thread_history_projection_state WHERE thread_id = ?",
          id: candidate.id
        ) { row in marker = (row["offset"] ?? "") + ":" + (row["ordinal"] ?? "") }
        let inputs = [credentialDigest(credential), try snapshotInputs(metadata)]
        return try paginated.snapshot(
          source: candidate.source.path, id: candidate.id,
          marker: marker.map { ([$0] + inputs).joined(separator: "\u{1}") }
        ) {
          var state = TranscriptState(credential: credential)
          try db.each("SELECT MAX(created_at_ms) AS latest FROM thread_items WHERE thread_id = ?", id: candidate.id) { row in
            state.activity(row["latest"])
          }
          try db.each(
            """
            SELECT turn_id, item_id, created_at_ms,
            CASE WHEN length(item_json) <= 16777216 THEN item_json END AS item_json
            FROM thread_items WHERE thread_id = ? AND item_type IN ('userMessage', 'agentMessage', 'commandExecution', 'fileChange', 'dynamicToolCall')
            ORDER BY rollout_ordinal, turn_id, item_id
            """, id: candidate.id
          ) { row in
            paginated.decoded.add()
            try state.codexItem(row)
          }
          return try finish(state, candidate)
        }
      }
      let isCodex = candidate.source.provider == "codex"
      let (paths, purpose) = try checkedTranscriptFiles(candidate)
      let context = [candidate.source.provider, candidate.id, credentialDigest(credential)]
        .joined(separator: "\u{1}")
      // Files of one conversation fold as one sequence, oldest first: each
      // later file starts from the state the earlier ones left, and their
      // revision is part of its context, so a change there refolds it.
      func foldChain() throws -> (state: TranscriptState, revision: UInt64)? {
        var chain: (state: TranscriptState, revision: UInt64)?
        for path in paths {
          let earlier = chain
          chain = try transcripts.fold(
            path, purpose: purpose, context: context + (earlier.map { "\u{1}\($0.revision)" } ?? ""),
            initial: { earlier?.state ?? TranscriptState(credential: credential) }
          ) { state, number, row in
            if isCodex {
              try state.codexRecord(row, number: number, id: candidate.id)
            } else {
              try state.claudeRecord(row, id: candidate.id)
            }
            return true
          }
        }
        return chain
      }
      guard let folded = try foldChain(), let path = paths.last else { throw SyncFailure.scope }
      guard folded.state.identified else { throw SyncFailure.identity }
      let key = try snapshotInputs(metadata)
      return try transcripts.finalized(path, purpose: purpose, revision: folded.revision, key: key) {
        try finish(folded.state, candidate)
      }
    }
  }

  /// `transcriptFiles`, each inside the candidate's source folder.
  private static func checkedTranscriptFiles(_ candidate: SyncCandidate) throws -> (paths: [URL], purpose: String) {
    guard let files = transcriptFiles(candidate), !files.paths.isEmpty,
      files.paths.allSatisfy({ syncWithin($0.path, candidate.source.path) })
    else { throw SyncFailure.scope }
    return files
  }

  /// How long a chat's files stay unmodified before its acknowledged snapshot is parked.
  /// Any later change re-reads the chat from zero, so not much shorter: at 30 minutes
  /// real chats came back often enough to re-read 54 GB a week on one Mac.
  static let parkAfter: TimeInterval = 2 * 3600

  /// What a parked acknowledgement depends on besides its files.
  private static func parkKey(_ candidate: SyncCandidate, credential: String) -> String? {
    guard let inputs = try? snapshotInputs(candidate.metadata) else { return nil }
    return [candidate.source.provider, candidate.id, credentialDigest(credential), inputs]
      .joined(separator: "\u{1}")
  }

  /// The acknowledgement of a parked chat whose files and inputs are unchanged.
  static func parkedAcknowledgement(_ candidate: SyncCandidate, credential: String) -> String? {
    guard let files = try? checkedTranscriptFiles(candidate),
      let key = parkKey(candidate, credential: credential)
    else { return nil }
    return transcripts.parked(candidate.key, key: key, files.paths)
  }

  /// After `acknowledgement` matched this pass: a JSONL chat whose files have not
  /// changed for `parkAfter` keeps only that acknowledgement and its files'
  /// identities; its folded state and snapshot go. A later change folds it from zero.
  /// True when the chat is parked now.
  @discardableResult
  static func park(_ candidate: SyncCandidate, credential: String, acknowledgement: String) -> Bool {
    guard let files = try? checkedTranscriptFiles(candidate),
      let key = parkKey(candidate, credential: credential)
    else { return false }
    return transcripts.park(
      files.paths, purpose: files.purpose, id: candidate.key, key: key, acknowledgement: acknowledgement,
      idle: parkAfter)
  }

  /// The snapshot from folded transcript state plus the candidate's metadata.
  static func finish(_ state: TranscriptState, _ candidate: SyncCandidate) throws
    -> SyncSnapshot
  {
    var metadata = candidate.metadata
    if let title = state.title { metadata["title"] = title }
    if let branch = state.branch { metadata["git_branch"] = branch }
    var activityAt = state.activityAt
    let updated = metadata["updated_at_ms"] ?? metadata["updated_at"].flatMap(Double.init).map { String($0 * 1000) }
    if let value = TranscriptState.activityValue(updated) { activityAt = max(activityAt ?? 0, value) }
    var messages = state.messages
    var omitted = state.omitted
    guard !messages.isEmpty else { throw SyncFailure.empty }
    guard let folder = metadata["cwd"], !folder.isEmpty else { throw SyncFailure.identity }
    let title = redact(
      metadata["title"] ?? state.opening?.text ?? candidate.id,
      credential: state.credential)
    let touched = state.touched.map { touch in
      touch.path.hasPrefix("/")
        ? touch.path : ((touch.cwd ?? metadata["cwd"] ?? "/") as NSString).appendingPathComponent(touch.path)
    }
    // Each field is cut to what the server accepts (a longer one is refused, and the whole
    // conversation with it), and the branch and file names go through the secret patterns
    // like the text does.
    let branch = metadata["git_branch"].map { clamp(redact($0, credential: state.credential), to: Limits.branch) }
    var snapshot = SyncSnapshot(
      title: clamp(title, to: Limits.title), cwd: clamp(folder, to: Limits.cwd),
      branch: branch?.isEmpty == false ? branch : nil, messages: messages, activityAt: activityAt,
      filesTouched: checkoutFiles(touched).prefix(Limits.files).map {
        clamp(redact($0, credential: state.credential), to: Limits.file)
      })
    // Over the server's limits: keep the newest messages that fit, behind one note
    // saying how many earlier ones were left out. Never the newest message.
    // Measured as the whole PUT body the server caps at 1 MiB, with the widest base
    // revision and activity time the fields beside the snapshot can hold, so the real
    // body is never larger than the one measured.
    while true {
      snapshot.messages = omitted > 0 ? [omissionNote(omitted, before: messages[0])] + messages : messages
      let size = try syncJSON([
        "base_revision": 9_007_199_254_740_991, "snapshot": snapshot.json,
        "activity_at": 9_007_199_254_740_991, "files_touched": snapshot.filesTouched,
      ]).count
      if size <= maxBytes && snapshot.messages.count <= 10_000 { return snapshot }
      guard messages.count > 1 else { throw SyncFailure.oversized }
      var excess = size - maxBytes + 256  // room for the note to appear or grow
      var drop = 0
      repeat {
        excess -= try syncJSON(messages[drop].json).count + 1
        drop += 1
      } while (excess > 0 || messages.count - drop + 1 > 10_000) && drop < messages.count - 1
      messages.removeFirst(drop)
      omitted += drop
    }
  }

  /// What the server accepts for each label of a snapshot (docs/session-sync.md): characters
  /// (UTF-16 units) for the text fields, a count for the files.
  enum Limits {
    static let title = 200
    static let cwd = 2048
    static let branch = 256
    static let files = 50
    static let file = 512
  }

  /// `text` cut to at most `limit` UTF-16 units. A prefix on Unicode scalars never splits
  /// a surrogate pair.
  static func clamp(_ text: String, to limit: Int) -> String {
    guard text.utf16.count > limit else { return text }
    var clipped = ""
    var units = 0
    for scalar in text.unicodeScalars {
      let size = scalar.value > 0xFFFF ? 2 : 1
      if units + size > limit { break }
      clipped.unicodeScalars.append(scalar)
      units += size
    }
    return clipped
  }

  /// The one message that stands in for the earlier ones a long conversation
  /// leaves out. The snapshot has only user and assistant roles.
  static func omissionNote(_ omitted: Int, before first: SyncMessage) -> SyncMessage {
    let count = omitted == 1 ? "1 earlier message omitted" : "\(omitted) earlier messages omitted"
    return SyncMessage(
      id: "hq-sync-earlier-messages", role: "assistant",
      text: "Earlier messages not synced: this conversation is over the server's limit of 1 MiB or 10,000 messages (\(count)).",
      timestamp: first.timestamp)
  }
}

/// Parsed Claude desktop cards keyed by sessions root, then card path. Each call
/// replaces its root's map with the cards it saw, so deleted cards drop out.
private final class CardMemo: @unchecked Sendable {
  struct Identity: Equatable {
    var inode: UInt64
    var size: Int64
    var seconds: Int
    var nanoseconds: Int
  }
  struct Card {
    var id: String
    var isArchived: Bool
  }
  /// `card` is nil for a skipped file: not a regular file, over 1 MiB, not a JSON
  /// object, or without a `cliSessionId`. A card that cannot be read is not stored.
  struct Entry {
    var identity: Identity
    var card: Card?
  }
  private let lock = NSLock()
  private var roots: [String: [String: Entry]] = [:]
  func entries(_ root: String) -> [String: Entry] {
    lock.lock()
    defer { lock.unlock() }
    return roots[root] ?? [:]
  }
  func set(_ root: String, _ entries: [String: Entry]) {
    lock.lock()
    defer { lock.unlock() }
    roots[root] = entries
  }
}

/// Finished snapshots of Codex paginated threads by source and thread, for the
/// life of the helper process. An entry is reused while its marker (the
/// thread's projection state and the snapshot's other inputs) is unchanged, so
/// an idle thread is neither decoded nor redacted again, and its stable
/// revision lets the transport skip rehashing it. Only built snapshots are kept;
/// a failure is retried next pass. A thread that is no longer a candidate is
/// dropped, as is every thread of a source whose folder or index is gone. A
/// failed discovery keeps them, so a passing error doesn't rebuild every thread.
final class PaginatedHistory: @unchecked Sendable {
  private struct Entry {
    let marker: String
    let snapshot: SyncSnapshot
  }
  private let lock = NSLock()
  private var entries: [String: [String: Entry]] = [:]
  private var nextRevision: UInt64 = 0
  /// `thread_items` rows decoded, for tests that prove a pass skipped them.
  let decoded = SyncCounter()

  /// The cached snapshot when `marker` matches; else `build`'s, kept under
  /// `marker`. A nil marker (no projection state) always builds, and drops what
  /// was kept, so it is never served if the same marker comes back.
  func snapshot(source: String, id: String, marker: String?, build: () throws -> SyncSnapshot)
    throws -> SyncSnapshot
  {
    guard let marker else {
      lock.withLock { entries[source]?[id] = nil }
      return try build()
    }
    let cached = lock.withLock { entries[source]?[id] }
    if let cached, cached.marker == marker { return cached.snapshot }
    var snapshot = try build()
    lock.withLock {
      nextRevision += 1
      snapshot.revision = "paginated-\(nextRevision)"
      entries[source, default: [:]][id] = Entry(marker: marker, snapshot: snapshot)
    }
    return snapshot
  }

  /// Keeps only `ids` for `source`: the candidates its latest discovery found.
  func retain(source: String, ids: Set<String>) {
    lock.withLock {
      entries[source] = ids.isEmpty ? nil : entries[source]?.filter { ids.contains($0.key) }
    }
  }
}

final class SyncCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func add() { lock.withLock { count += 1 } }
}

/// The leading records of a Claude transcript that decide whether it is a
/// candidate: whether it inherits a parent's records, its first own record,
/// and whether an own turn came before any own cwd.
struct ClaudeHead {
  var inherited = false
  var own: (id: String, cwd: String, stamp: String?)?
  var hasOwnTurn = false
  /// The own record's `entrypoint` names a program-started run.
  var isScript = false
}

/// Everything a snapshot needs from transcript records, accumulated in source
/// order so appending records to it equals reading the whole transcript again.
struct TranscriptState {
  let credential: String
  var activityAt: Double?
  /// Paths as written, with the record's cwd; resolved against the candidate's
  /// cwd only when the snapshot is finished.
  var touched: [(path: String, cwd: String?)] = []
  /// The newest messages, oldest first. A conversation over the server's limits keeps
  /// only what fits, so a long chat syncs its recent part instead of failing:
  /// the oldest are dropped and counted in `omitted`. `kept[..<start]` are
  /// dropped slots awaiting compaction; `positions` and `sizes` index `kept`.
  private var kept: [SyncMessage] = []
  private var sizes: [Int] = []
  private var start = 0
  private var positions: [String: Int] = [:]
  private var dropped: Set<String> = []
  var messages: [SyncMessage] { Array(kept[start...]) }
  var omitted = 0
  var bytes = 0
  /// The title of the first user message that has one (`SyncTitle`), kept for when that
  /// message has been dropped. Wrapper-only messages (a /clear record, a system
  /// reminder) have none, so the next user message is tried; the message itself is
  /// sent unchanged.
  var opening: (id: String, text: String)?
  var identified = false
  /// A Claude custom title, when one was recorded (`.some(nil)` clears it).
  var title: String?? = nil
  var branch: String?

  init(credential: String) { self.credential = credential }

  static func activityValue(_ stamp: String?) -> Double? {
    guard let stamp else { return nil }
    let milliseconds = Double(stamp) ?? SessionCollector.timestamp(stamp).map { $0 * 1000 }
    guard let milliseconds, milliseconds > 0 else { return nil }
    return milliseconds.rounded(.down)
  }

  mutating func activity(_ stamp: String?) {
    if let value = Self.activityValue(stamp) { activityAt = max(activityAt ?? 0, value) }
  }

  mutating func touch(_ path: Any?, cwd: Any? = nil) {
    guard let path = path as? String, !path.isEmpty else { return }
    touched.append((path, cwd as? String))
  }

  mutating func touchPatch(_ input: Any?) {
    for path in SessionCollector.patchedFiles(input) { touch(path) }
  }

  /// Appended to a message cut to fit the server: 500,000 characters as JavaScript
  /// counts them, and small enough to fit a request beside the rest.
  static let truncated = "\n[Message truncated to fit the server's limit]"
  static let messageBytes = SessionCollector.maxBytes - 64 * 1024

  mutating func add(_ id: String, _ role: String, _ text: String, _ stamp: String?) throws {
    activity(stamp)
    // What a tool injected beside the person's words (reminders, environment and
    // instruction files) is not a message they wrote and is not uploaded.
    let visible = role == "user" ? SyncTitle.strippingInjected(text) : text
    guard !visible.isEmpty else { return }
    // The server takes ids of up to 256 characters: a longer one skips this message only.
    guard id.utf16.count <= 256 else { return }
    // Dropped as too old: a repeated record stays dropped.
    guard !dropped.contains(id) else { return }
    var safe = SessionCollector.redact(visible, credential: credential)
    if safe.utf16.count > 500_000 { safe = Self.clip(safe, to: 500_000) }
    // And timestamps of up to 64: a longer one goes as null.
    var message = SyncMessage(id: id, role: role, text: safe, timestamp: stamp.flatMap { $0.utf16.count <= 64 ? $0 : nil })
    var size = try syncJSON(message.json).count
    while size > Self.messageBytes {
      let keep = Int(Double(message.text.utf16.count) * Double(Self.messageBytes) / Double(size) * 0.95)
      message.text = Self.clip(message.text, to: keep)
      size = try syncJSON(message.json).count
    }
    if role == "user", opening == nil || opening?.id == id {
      opening = SyncTitle.make(from: message.text).map { (id, $0) }
    }
    bytes += size
    if let index = positions[id] {
      bytes -= sizes[index]
      kept[index] = message
      sizes[index] = size
    } else {
      positions[id] = kept.count
      kept.append(message)
      sizes.append(size)
    }
    while bytes > SessionCollector.maxBytes || kept.count - start > 10_000, kept.count - start > 1 {
      bytes -= sizes[start]
      positions[kept[start].id] = nil
      dropped.insert(kept[start].id)
      kept[start] = SyncMessage(id: "", role: "", text: "", timestamp: nil)
      omitted += 1
      start += 1
    }
    if start > 1024, start * 2 > kept.count {
      kept.removeFirst(start)
      sizes.removeFirst(start)
      let shift = start
      positions = positions.mapValues { $0 - shift }
      start = 0
    }
  }

  /// A prefix of at most `limit` UTF-16 units, marker included, on a scalar boundary.
  static func clip(_ text: String, to limit: Int) -> String {
    let room = max(0, limit - truncated.utf16.count)
    var clipped = ""
    var units = 0
    for scalar in text.unicodeScalars {
      units += scalar.utf16.count
      if units > room { break }
      clipped.unicodeScalars.append(scalar)
    }
    return clipped + truncated
  }

  /// One Codex paginated `thread_items` row.
  mutating func codexItem(_ row: [String: String]) throws {
    guard let raw = row["item_json"]?.data(using: .utf8),
      let item = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
      let turn = row["turn_id"], let id = row["item_id"]
    else { throw SyncFailure.source }
    // Tool items only name the files a chat touched; their text is never read.
    switch item["type"] as? String ?? "" {
    case "commandExecution":
      touchPatch(item["command"])
      return
    case "fileChange":
      for change in item["changes"] as? [[String: Any]] ?? [] { touch(change["path"]) }
      return
    case "dynamicToolCall":
      touchPatch(item["arguments"])
      return
    default: break
    }
    let user = item["type"] as? String == "userMessage"
    try add(
      turn + ":" + id, user ? "user" : "assistant",
      user ? SessionCollector.text(item["content"]) : SessionCollector.text(item["text"]), row["created_at_ms"])
  }

  /// One Codex rollout JSONL record (`number` is its 1-based line).
  mutating func codexRecord(_ row: [String: Any], number: Int, id candidate: String) throws {
    activity(row["timestamp"] as? String)
    let payload = row["payload"] as? [String: Any] ?? [:]
    if row["type"] as? String == "session_meta" {
      guard payload["id"] as? String == candidate,
        payload["cwd"] is String
      else { throw SyncFailure.identity }
      identified = true
    }
    if row["type"] as? String == "response_item",
      ["function_call", "custom_tool_call"].contains(payload["type"] as? String ?? "")
    {
      touchPatch(payload["arguments"] ?? payload["input"])
    }
    if row["type"] as? String == "response_item", payload["type"] as? String == "message",
      let role = payload["role"] as? String, ["user", "assistant"].contains(role)
    {
      try add("line-\(number)", role, SessionCollector.text(payload["content"]), row["timestamp"] as? String)
    }
  }

  /// One Claude transcript record. Parent records (resume/fork) may only lead;
  /// the own id must appear and nothing foreign may follow it. The inherited
  /// messages are shown too.
  mutating func claudeRecord(_ row: [String: Any], id candidate: String) throws {
    if let id = row["sessionId"] as? String {
      if id == candidate { identified = true } else if identified { throw SyncFailure.identity }
    }
    activity(row["timestamp"] as? String)
    if row["type"] as? String == "custom-title", row["sessionId"] as? String == candidate {
      let custom = (row["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      title = .some(custom?.isEmpty == true ? nil : custom)
    }
    if let branch = row["gitBranch"] as? String { self.branch = branch }
    if let role = row["type"] as? String, ["user", "assistant"].contains(role),
      row["isMeta"] as? Bool != true
    {
      let blocks = (row["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
      for block in blocks {
        // Tool calls only name the files a chat touched; their text is never read.
        if block["type"] as? String == "tool_use",
          ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(block["name"] as? String),
          let input = block["input"] as? [String: Any]
        {
          touch(input["file_path"] ?? input["notebook_path"], cwd: row["cwd"])
        }
      }
      let content = SessionCollector.text((row["message"] as? [String: Any])?["content"])
      if !content.isEmpty {
        guard let id = row["uuid"] as? String else { throw SyncFailure.identity }
        try add(id, role, content, row["timestamp"] as? String)
      }
    }
  }
}

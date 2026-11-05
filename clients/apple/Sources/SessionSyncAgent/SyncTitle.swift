import Foundation

/// A conversation's title when its tool recorded none: the first user message that says
/// something, cleaned; and the removal of blocks a tool injected into a user message.
/// Pure.
enum SyncTitle {
  /// Blocks a tool or an IDE wraps around, or injects beside, what the person typed.
  /// Matched case-insensitively; the whole block goes, tags and content.
  static let wrappers = [
    "system-reminder", "task-notification", "local-command-stdout", "local-command-stderr",
    "local-command-caveat", "command-contents", "user-prompt-submit-hook", "bash-input",
    "bash-stdout", "bash-stderr", "ide_opened_file", "ide_selection", "ide_diagnostics",
    "environment_context", "user_instructions", "instructions", "permissions instructions",
    "collaboration_mode", "turn_aborted", "subagent_notification", "user_action",
  ]

  /// Commands that tidy a session rather than start work: their arguments (a model
  /// name, a session id) say nothing about what the conversation is for.
  static let housekeeping: Set<String> = [
    "clear", "compact", "model", "resume", "login", "logout", "config", "cost", "status",
    "help", "exit", "effort", "fast", "context", "usage",
  ]

  static let limit = 200

  /// Blocks a tool injects into a user message beside what the person typed: reminders
  /// (which carry CLAUDE.md and memory files), the environment, and instruction files
  /// (Codex wraps AGENTS.md in `<INSTRUCTIONS>`). These never leave the Mac. The
  /// other wrappers above (a command's output, an open IDE file) are context the
  /// person chose, and stay.
  static let injected = [
    "system-reminder", "environment_context", "user_instructions", "instructions",
    "permissions instructions", "collaboration_mode", "user-prompt-submit-hook",
  ]

  /// `text` without its injected blocks (tags and content, matched case-insensitively;
  /// a block that never closes loses everything from its opening tag). Text with no
  /// block is returned as it is; otherwise it comes back trimmed, and empty when the
  /// message was nothing else.
  static func strippingInjected(_ text: String) -> String {
    guard text.utf8.contains(UInt8(ascii: "<")) else { return text }
    var bytes = Array(text.utf8)
    var removed: Set<String> = []
    for name in injected {
      let next = removeBlocks(named: name, from: bytes)
      if next.count != bytes.count {
        removed.insert(name)
        bytes = next
      }
    }
    guard !removed.isEmpty else { return text }
    var body = String(decoding: bytes, as: UTF8.self)
    if removed.contains("instructions") { body = removeAgentsHeading(body) }
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The "# AGENTS.md instructions for <dir>" line Codex puts above its `<INSTRUCTIONS>` block.
  private static func removeAgentsHeading(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("# agents.md instructions") }
      .joined(separator: "\n")
  }

  /// The title for a user message, or nil when it holds nothing a person would
  /// recognise (the caller then tries the next user message).
  static func make(from text: String) -> String? {
    // One byte buffer for every scan below: tag names are ASCII, so cutting at a tag
    // never splits a character, and each scan is a single pass over the text.
    var bytes = Array(text.utf8)
    for name in wrappers { bytes = removeBlocks(named: name, from: bytes) }
    // A command record is a message that is only that record, whatever a reminder or a
    // typed prompt happens to quote.
    if startsWithCommandTag(bytes), let title = command(in: bytes) { return title }
    var body = String(decoding: bytes, as: UTF8.self)
    body = removePreamble(body)
    body = preferringTypedText(body)
    body = unwrapped(body)
    // A line can open with a stray closing tag, or be nothing else: strip tags before
    // choosing the first line that says something.
    let lines = body.split(whereSeparator: \.isNewline).lazy
      .map { collapse(strippingLeadingTags(String($0))) }
    guard let line = lines.first(where: { !$0.isEmpty }) else { return nil }
    return clip(line)
  }

  private static func startsWithCommandTag(_ bytes: [UInt8]) -> Bool {
    let prefix = Array("<command-".utf8)
    guard let start = bytes.firstIndex(where: { !isSpace($0) }), bytes.count - start >= prefix.count
    else { return false }
    return matches(prefix, in: bytes, at: start)
  }

  /// `<command-name>/x</command-name>` records: "/x args", or nil for housekeeping.
  /// Outer nil: not a command record. Inner nil: a command that names nothing.
  private static func command(in bytes: [UInt8]) -> String?? {
    guard let name = firstBlock("command-name", in: bytes) else { return nil }
    let trimmed = collapse(name)
    let bare = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
    guard !bare.isEmpty, !housekeeping.contains(bare.lowercased()) else { return .some(nil) }
    let args = firstBlock("command-args", in: bytes).map(collapse) ?? ""
    return .some(clip(args.isEmpty ? "/" + bare : "/" + bare + " " + args))
  }

  /// Text outside `<pasted_content>` blocks when there is any; otherwise the pasted text.
  private static func preferringTypedText(_ text: String) -> String {
    let bytes = Array(text.utf8)
    let outside = String(decoding: removeBlocks(named: "pasted_content", from: bytes), as: UTF8.self)
    if !outside.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return outside }
    var pasted: [String] = []
    var position = 0
    while let open = openingTag("pasted_content", in: bytes, from: position) {
      guard let close = find(Array("</pasted_content>".utf8), in: bytes, from: open.end) else {
        pasted.append(String(decoding: bytes[open.end...], as: UTF8.self))
        break
      }
      pasted.append(String(decoding: bytes[open.end..<close], as: UTF8.self))
      position = close + "</pasted_content>".utf8.count
    }
    return pasted.joined(separator: "\n")
  }

  /// Codex opens a rollout with "# AGENTS.md instructions for <dir>" and the file
  /// inside an <INSTRUCTIONS> block (already removed above); the heading goes too.
  /// A chat another Claude session started opens with the same "Background" line.
  private static func removePreamble(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
      .filter {
        let line = $0.trimmingCharacters(in: .whitespaces).lowercased()
        return !line.hasPrefix("# agents.md instructions")
          && line != "background (from the session that started this one):"
      }
      .joined(separator: "\n")
  }

  /// Any tag the lists above do not know: drop the opening tag at the start, and its
  /// closing tag, and keep what was inside.
  private static func unwrapped(_ text: String) -> String {
    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for _ in 0..<8 {
      guard let tag = body.range(of: #"^<([A-Za-z][\w:.-]*)(?:\s[^>]*)?/?>"#, options: .regularExpression)
      else { break }
      let name = body[tag].dropFirst().prefix { $0.isLetter || $0.isNumber || "_:.-".contains($0) }
      body.removeSubrange(tag)
      if let close = body.range(of: "</\(name)>", options: .caseInsensitive) {
        body.removeSubrange(close)
      }
      body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return body
  }

  /// Drops opening, closing and self-closing tags from the start of a line, one pass.
  private static func strippingLeadingTags(_ line: String) -> String {
    let bytes = Array(line.utf8)
    var start = 0
    while let end = tagEnd(in: bytes, at: start) {
      start = end
      while start < bytes.count, isSpace(bytes[start]) { start += 1 }
    }
    return start == 0 ? line : String(decoding: bytes[start...], as: UTF8.self)
  }

  /// Where the tag that starts at `start` ends, or nil when no tag starts there.
  private static func tagEnd(in bytes: [UInt8], at start: Int) -> Int? {
    guard start < bytes.count, bytes[start] == UInt8(ascii: "<") else { return nil }
    var index = start + 1
    if index < bytes.count, bytes[index] == UInt8(ascii: "/") { index += 1 }
    guard index < bytes.count, isLetter(bytes[index]) else { return nil }
    while index < bytes.count, isLetter(bytes[index]) || isNameByte(bytes[index]) { index += 1 }
    guard index < bytes.count else { return nil }
    if bytes[index] == UInt8(ascii: "/") { index += 1 }
    guard index < bytes.count else { return nil }
    if bytes[index] == UInt8(ascii: ">") { return index + 1 }
    guard isSpace(bytes[index]), let close = bytes[index...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
    return close + 1
  }

  private static func isLetter(_ byte: UInt8) -> Bool {
    (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
  }

  /// The rest of a tag name: digits, `_ : . -`, and any non-ASCII byte.
  private static func isNameByte(_ byte: UInt8) -> Bool {
    (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ":")
      || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-") || byte >= 0x80
  }

  /// The inner text of the first `<name>…</name>`, nil when there is none.
  private static func firstBlock(_ name: String, in bytes: [UInt8]) -> String? {
    guard let open = openingTag(name, in: bytes, from: 0),
      let close = find(Array("</\(name)>".utf8), in: bytes, from: open.end)
    else { return nil }
    return String(decoding: bytes[open.end..<close], as: UTF8.self)
  }

  /// Removes every `<name …>…</name>`; a block that never closes (a message cut at
  /// the size limit) loses everything from its opening tag.
  private static func removeBlocks(named name: String, from bytes: [UInt8]) -> [UInt8] {
    let closing = Array("</\(name)>".utf8)
    var result: [UInt8] = []
    var position = 0
    while let open = openingTag(name, in: bytes, from: position) {
      result.append(contentsOf: bytes[position..<open.start])
      guard let close = find(closing, in: bytes, from: open.end) else { return result }
      position = close + closing.count
    }
    guard position > 0 else { return bytes }
    result.append(contentsOf: bytes[position...])
    return result
  }

  // MARK: Tag scanning
  //
  // Literal, ASCII case-insensitive scans that only move forward. A tag that never closes
  // ends the search instead of being searched for again from each later opening.

  /// The next `<name>` or `<name …>` at or after `from`: where it starts and where its `>` ends.
  /// No `>` after a `<name ` means none of the later openings has one either.
  private static func openingTag(_ name: String, in bytes: [UInt8], from: Int) -> (start: Int, end: Int)? {
    let literal = Array(("<" + name).utf8)
    var position = from
    while let start = find(literal, in: bytes, from: position) {
      let next = start + literal.count
      guard next < bytes.count else { return nil }
      if bytes[next] == UInt8(ascii: ">") { return (start, next + 1) }
      if isSpace(bytes[next]) {
        guard let end = bytes[next...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
        return (start, end + 1)
      }
      position = next
    }
    return nil
  }

  /// The index of the first case-insensitive match of the lower-case `needle` at or after
  /// `from`. Every needle here starts with `<`, so `memchr` can hop between candidates.
  private static func find(_ needle: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
    guard let first = needle.first, bytes.count >= needle.count, from <= bytes.count - needle.count
    else { return nil }
    precondition(first == UInt8(ascii: "<"))
    return bytes.withUnsafeBufferPointer { buffer -> Int? in
      guard let base = buffer.baseAddress else { return nil }
      let last = bytes.count - needle.count
      var index = from
      while index <= last, let hit = memchr(base + index, Int32(first), last - index + 1) {
        index = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
        if matches(needle, in: bytes, at: index) { return index }
        index += 1
      }
      return nil
    }
  }

  private static func matches(_ needle: [UInt8], in bytes: [UInt8], at start: Int) -> Bool {
    for offset in 0..<needle.count where lower(bytes[start + offset]) != needle[offset] { return false }
    return true
  }

  private static func lower(_ byte: UInt8) -> UInt8 {
    byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte
  }

  private static func isSpace(_ byte: UInt8) -> Bool {
    byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
  }

  private static func collapse(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// Unicode scalars, so a surrogate pair is never split; HQ's own cap is 200 UTF-16 units.
  private static func clip(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
  }
}

import Darwin
import Foundation

/// Folds append-only JSONL files incrementally across collector passes.
///
/// Transcripts are append-only and grow to tens of megabytes, and the collector
/// runs every 15 s. Re-reading and re-decoding every file on every pass made the
/// helper's footprint swing by gigabytes. This keeps, per file and purpose, the
/// folded state and the byte offset after the last complete line, so a pass
/// reads only what was appended since the previous one. An unchanged file (same
/// inode, size and mtime) costs one `stat`. A replaced, truncated or rewritten
/// file (inode change, size below the offset, or different bytes at the start or
/// just before the offset) is folded again from the beginning, so the result
/// always equals a full read. A trailing line without its newline is never
/// consumed: it is read again, complete, on a later pass.
///
/// Memory follows the chats still changing. A finished, acknowledged chat whose
/// files have been idle is parked: only its files' identities and its
/// acknowledgement are kept, and any change to them refolds it from zero.
/// Nothing is evicted by the clock: the collector ends each pass with `endPass`,
/// which drops what that pass never used (a chat that left the window, a file
/// that is gone), so a pass slower than any timeout keeps what it has not reached.
final class IncrementalJSONL: @unchecked Sendable {
  static let shared = IncrementalJSONL()

  static let chunk = 64 * 1024
  static let guardBytes = 4096

  struct Stats {
    var bytesRead = 0
    var linesParsed = 0
    var fullReads = 0
  }

  /// What `stat` says about a file; equal means the fold of it is unchanged.
  private struct Identity: Equatable {
    var device: dev_t
    var inode: ino_t
    var size: off_t
    var seconds: Int
    var nanoseconds: Int
    init(_ status: stat) {
      device = status.st_dev
      inode = status.st_ino
      size = status.st_size
      seconds = status.st_mtimespec.tv_sec
      nanoseconds = status.st_mtimespec.tv_nsec
    }
  }

  /// A parked chat: its files as they were folded, in order, and what was acknowledged for them.
  private struct Parked {
    let files: [(path: String, identity: Identity)]
    let key: String
    let acknowledgement: String
  }

  private final class Entry {
    let context: String
    var device: dev_t = 0
    var inode: ino_t = 0
    var size: off_t = 0
    var mtime = timespec()
    var offset: off_t = 0
    /// End of the bytes this entry vouches for: `offset`, or the end of the
    /// record that failed, so removing that record clears the failure.
    var guardEnd: off_t = 0
    var lines = 0
    var head = Data()
    var tail = Data()
    var state: Any
    var failure: Error?
    var stopped = false
    /// Inside a line longer than the limit: its bytes are dropped up to the next newline.
    var discarding = false
    var revision: UInt64 = 0
    var finalized: (revision: UInt64, key: String, result: Result<SyncSnapshot, Error>)?
    init(context: String, state: Any) {
      self.context = context
      self.state = state
    }
    /// Nothing about the file changed since the last read: a stat is the whole cost.
    func matches(_ status: stat) -> Bool {
      status.st_dev == device && status.st_ino == inode && status.st_size == size
        && status.st_mtimespec.tv_sec == mtime.tv_sec && status.st_mtimespec.tv_nsec == mtime.tv_nsec
    }

    /// The open file still begins with the bytes already folded: same inode, not
    /// shorter than them, and the same bytes at its start and at their end.
    /// Anything else is a replacement and is folded from zero.
    func continues(_ descriptor: Int32, _ status: stat) -> Bool {
      guard status.st_dev == device, status.st_ino == inode, status.st_size >= guardEnd else { return false }
      return IncrementalJSONL.read(descriptor, at: 0, count: head.count) == head
        && IncrementalJSONL.read(descriptor, at: guardEnd - off_t(tail.count), count: tail.count) == tail
    }
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var parked: [String: Parked] = [:]
  /// Entry keys and parked chats used since the last `endPass`.
  private var used: Set<String> = []
  private var usedParked: Set<String> = []
  private var nextRevision: UInt64 = 0
  private(set) var stats = Stats()

  /// Folded files and parked chats held now.
  var held: (entries: Int, parked: Int) {
    lock.withLock { (entries.count, parked.count) }
  }

  func resetStats() {
    lock.lock()
    defer { lock.unlock() }
    stats = Stats()
  }

  private func nextRevisionNumber() -> UInt64 {
    nextRevision += 1
    return nextRevision
  }

  /// Folds every complete line of `url` into `State`, resuming from the last pass.
  /// `visit` gets the 1-based line number and returns false to stop reading the
  /// file for good (until it is replaced). An error thrown while reading a line is
  /// remembered with that prefix and rethrown, without re-reading, until the file
  /// changes underneath it — exactly what a full read of the same bytes would do.
  /// `context` names everything else the fold depends on; a change refolds.
  /// A line longer than `maxLine` is skipped, never read into memory whole: it costs that
  /// one message, not the conversation.
  func fold<State>(
    _ url: URL, purpose: String, context: String = "", maxLine: Int = SessionCollector.maxLine,
    initial: () -> State,
    _ visit: (inout State, Int, [String: Any]) throws -> Bool
  ) throws -> (state: State, revision: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    let key = purpose + "\u{0}" + url.path
    used.insert(key)
    var status = stat()
    guard stat(url.path, &status) == 0 else {
      entries[key] = nil
      throw CocoaError(.fileReadNoSuchFile)
    }
    if let entry = entries[key], entry.context == context, entry.matches(status) {
      if let failure = entry.failure { throw failure }
      return (entry.state as! State, entry.revision)
    }
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      entries[key] = nil
      throw CocoaError(.fileReadNoPermission)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    guard fstat(descriptor, &status) == 0 else {
      entries[key] = nil
      throw CocoaError(.fileReadUnknown)
    }
    let entry: Entry
    if let cached = entries[key], cached.context == context, cached.continues(descriptor, status) {
      entry = cached
    } else {
      entry = Entry(context: context, state: initial())
      entry.revision = nextRevisionNumber()
      entries[key] = entry
      stats.fullReads += 1
    }
    entry.device = status.st_dev
    entry.inode = status.st_ino
    entry.size = status.st_size
    entry.mtime = status.st_mtimespec
    if let failure = entry.failure { throw failure }
    if entry.stopped || status.st_size <= entry.offset {
      return (entry.state as! State, entry.revision)
    }
    // Take the state out so appending to its arrays never copies them.
    var state = entry.state as! State
    entry.state = ()
    let startLines = entry.lines
    defer {
      entry.state = state
      if entry.failure == nil { entry.guardEnd = entry.offset }
      entry.head = Self.read(descriptor, at: 0, count: Int(min(off_t(Self.guardBytes), entry.guardEnd)))
      let tail = min(off_t(Self.guardBytes), entry.guardEnd)
      entry.tail = Self.read(descriptor, at: entry.guardEnd - tail, count: Int(tail))
    }
    // Set while a record is being decoded: a failure there is a property of these
    // bytes and is remembered. Any other failure (I/O) is retried next pass.
    var failingEnd: off_t?
    do {
      try handle.seek(toOffset: UInt64(entry.offset))
      var buffer = Data()
      reading: while true {
        let more: Bool = try autoreleasepool {
          guard let chunk = try handle.read(upToCount: Self.chunk), !chunk.isEmpty else { return false }
          stats.bytesRead += chunk.count
          buffer.append(chunk)
          var start = buffer.startIndex
          defer { buffer.removeSubrange(buffer.startIndex..<start) }
          if entry.discarding {
            guard let end = buffer[start...].firstIndex(of: 10) else {
              entry.offset += off_t(buffer.endIndex - start)
              start = buffer.endIndex
              return true
            }
            entry.offset += off_t(end - start + 1)
            entry.lines += 1
            start = buffer.index(after: end)
            entry.discarding = false
          }
          while let end = buffer[start...].firstIndex(of: 10) {
            let line = buffer[start..<end]
            guard line.count <= maxLine else {
              entry.offset += off_t(end - start + 1)
              entry.lines += 1
              start = buffer.index(after: end)
              continue
            }
            failingEnd = entry.offset + off_t(end - start + 1)
            guard let row = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
              throw SyncFailure.source
            }
            stats.linesParsed += 1
            entry.lines += 1
            let proceed = try visit(&state, entry.lines, row)
            entry.offset += off_t(end - start + 1)
            start = buffer.index(after: end)
            failingEnd = nil
            if !proceed {
              entry.stopped = true
              return false
            }
          }
          let pending = buffer.endIndex - start
          if pending > maxLine {
            // Too long and still no newline: drop what has been read and keep dropping.
            entry.offset += off_t(pending)
            start = buffer.endIndex
            entry.discarding = true
          }
          return true
        }
        if !more { break reading }
      }
    } catch {
      if let failingEnd {
        entry.failure = error
        entry.guardEnd = failingEnd
      } else {
        entries[key] = nil
      }
      throw error
    }
    if entry.lines != startLines { entry.revision = nextRevisionNumber() }
    return (state, entry.revision)
  }

  /// The collector's finished snapshot for one fold revision and one set of
  /// inputs, so an unchanged transcript is not reassembled every pass.
  func finalized(
    _ url: URL, purpose: String, revision: UInt64, key: String,
    _ build: () throws -> SyncSnapshot
  ) throws -> SyncSnapshot {
    lock.lock()
    let entry = entries[purpose + "\u{0}" + url.path]
    let cached = entry?.finalized.flatMap { $0.revision == revision && $0.key == key ? $0 : nil }
    lock.unlock()
    if let cached { return try cached.result.get() }
    let result = Result {
      try build()
    }.map { snapshot -> SyncSnapshot in
      var snapshot = snapshot
      lock.lock()
      snapshot.revision = "\(nextRevisionNumber())"
      lock.unlock()
      return snapshot
    }
    lock.lock()
    if let entry, entry.revision == revision, entries[purpose + "\u{0}" + url.path] === entry {
      entry.finalized = (revision, key, result)
    }
    lock.unlock()
    return try result.get()
  }

  /// Parks the chat `id`, whose files were folded in order under `purpose`, when each is
  /// still as folded and was last modified `idle` or longer ago: their entries are
  /// dropped, and `acknowledgement` is kept for as long as `key` and every file's
  /// identity stay the same. False, and nothing changes, otherwise.
  func park(
    _ urls: [URL], purpose: String, id: String, key: String, acknowledgement: String, idle: TimeInterval
  ) -> Bool {
    let cutoff = Date().timeIntervalSince1970 - idle
    return lock.withLock {
      var files: [(path: String, identity: Identity)] = []
      for url in urls {
        var status = stat()
        guard let entry = entries[purpose + "\u{0}" + url.path], entry.failure == nil,
          stat(url.path, &status) == 0, entry.matches(status),
          TimeInterval(status.st_mtimespec.tv_sec) <= cutoff
        else { return false }
        files.append((url.path, Identity(status)))
      }
      for url in urls { entries[purpose + "\u{0}" + url.path] = nil }
      parked[id] = Parked(files: files, key: key, acknowledgement: acknowledgement)
      usedParked.insert(id)
      return true
    }
  }

  /// The acknowledgement parked for `id` while `key` and its files (`urls`, in order)
  /// are as parked. Anything else drops the record, and the chat folds from zero.
  func parked(_ id: String, key: String, _ urls: [URL]) -> String? {
    lock.withLock {
      guard let record = parked[id] else { return nil }
      let same =
        record.key == key && record.files.count == urls.count
        && zip(record.files, urls).allSatisfy { file, url in
          var status = stat()
          return file.path == url.path && stat(url.path, &status) == 0 && Identity(status) == file.identity
        }
      guard same else {
        parked[id] = nil
        return nil
      }
      usedParked.insert(id)
      return record.acknowledgement
    }
  }

  /// Marks the folded state of `url` used this pass without reading the file.
  func keep(_ url: URL, purpose: String) {
    lock.withLock { _ = used.insert(purpose + "\u{0}" + url.path) }
  }

  /// Drops the folded state of `urls` and the chat parked as `id`: the next fold reads from zero.
  func forget(_ urls: [URL], purpose: String, id: String) {
    lock.withLock {
      for url in urls { entries[purpose + "\u{0}" + url.path] = nil }
      parked[id] = nil
    }
  }

  /// Ends one collector pass: drops every folded file and parked chat the pass did not
  /// use (a chat that left the window, a file that is gone), except those inside
  /// `folders`, the sources this pass could not list. A folder matches as written and as
  /// its real path (listings can name `/private/var` for `/var`); files inside an
  /// unreadable folder cannot be resolved, so they are compared as written.
  func endPass(keeping folders: [String] = []) {
    var prefixes: [String] = []
    for folder in folders {
      prefixes.append(folder)
      if let real = realpath(folder, nil) {
        prefixes.append(String(cString: real))
        free(real)
      }
    }
    prefixes = prefixes.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    lock.withLock {
      func kept(_ path: String) -> Bool { prefixes.contains { path.hasPrefix($0) } }
      // An entry's key is its purpose, a NUL, then its path.
      entries = entries.filter { key, _ in used.contains(key) || kept(String(key.drop { $0 != "\u{0}" }.dropFirst())) }
      parked = parked.filter { id, record in usedParked.contains(id) || record.files.contains { kept($0.path) } }
      used = []
      usedParked = []
    }
  }

  /// Forget everything (tests, and scope changes that should start cold).
  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    entries = [:]
    parked = [:]
  }

  fileprivate static func read(_ descriptor: Int32, at offset: off_t, count: Int) -> Data {
    guard count > 0 else { return Data() }
    var data = Data(count: count)
    let read = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, offset) }
    return read == count ? data : Data()
  }
}

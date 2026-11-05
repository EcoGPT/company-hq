import Foundation

/// HQ.app's watchdog over the background helper. HQ launches the helper with
/// `Process()`, not launchd, so nothing else relaunches one that stopped. The
/// decision lives here, free of AppKit, so a test can run it against a fake Mac.
enum SessionSyncKeeper {
  /// How often HQ looks for the helper: a dead one is back within about this long.
  static let interval: Duration = .seconds(60)

  /// What one check reads from the Mac.
  struct Observation {
    var config: SessionSyncConfig?
    /// The signed-in person, nil when HQ is signed out.
    var personID: String?
    var baseURL: String
    /// The one-time notice was answered (OK) for this person and hub.
    var isNoticeAnswered: Bool
    /// Not a worktree, test host or Debug build (the gate `restore` uses).
    var isAllowed: Bool
    /// The login item is approved: relaunching around a person's refusal in
    /// Login Items, or re-registering every minute, is `restore`'s business.
    var isLoginItemEnabled: Bool
    var isHelperRunning: Bool
  }

  /// Relaunch only what `restore` would have left running: sync on for the
  /// signed-in person and hub, notice answered, not paused, and no helper.
  static func shouldRelaunch(_ seen: Observation) -> Bool {
    guard seen.isAllowed, !seen.isHelperRunning, seen.isLoginItemEnabled, seen.isNoticeAnswered,
      let personID = seen.personID, let config = seen.config
    else { return false }
    return config.isSyncing && config.paused != true && config.personID == personID
      && config.baseURL == seen.baseURL
  }

  /// Whether `start` retires a running helper. Every update replaces the
  /// helper's bundle, so its file times say nothing about whether its code
  /// changed: when the helper recorded the stamp of its own sources at launch
  /// (`HelperStamp`), that stamp and the bundled helper's decide. A restarted
  /// helper refolds the whole week of chats, so it is replaced only when its
  /// code differs.
  ///
  /// - Same stamp: kept. Different stamp: retired.
  /// - No record, one that cannot be read, one from another process, or a
  ///   stamp that cannot identify code (a build without git history, or with
  ///   uncommitted edits to the stamped paths): the time rule below, as before.
  ///   An unreadable record is not a reason to retire: if the helper cannot
  ///   replace it, every HQ launch would kill a healthy helper.
  static func isOutdated(
    started: Date?, modified: Date?, changed: Date?,
    recorded: HelperStamp.Record? = nil, pid: Int32 = 0, bundled: String? = nil
  ) -> Bool {
    if let recorded, recorded.pid == pid, HelperStamp.identifiesCode(recorded.stamp),
      HelperStamp.identifiesCode(bundled)
    {
      return recorded.stamp != bundled
    }
    return startedBeforeInstall(started: started, modified: modified, changed: changed)
  }

  /// Whether a running helper predates the installed binary. An update's copy
  /// keeps the build's modification time (the build machine's clock), so the
  /// status-change time is when this binary arrived; the modification time
  /// stands in only when that cannot be read. A time that cannot be read
  /// counts as outdated.
  static func startedBeforeInstall(started: Date?, modified: Date?, changed: Date?) -> Bool {
    guard let started, let installed = changed ?? modified else { return true }
    return started < installed
  }

  /// One check: starts the helper when it should be running and is not.
  /// Returns whether it asked for a start.
  @MainActor @discardableResult
  static func check(
    observe: @MainActor () -> Observation, start: @MainActor () async throws -> Void
  ) async -> Bool {
    guard shouldRelaunch(observe()) else { return false }
    // `start` reads the config again and launches nothing if a Pause landed meanwhile.
    try? await start()
    return true
  }

  /// Checks every `interval` until the task is cancelled.
  @MainActor
  static func run(
    every interval: Duration = Self.interval, observe: @MainActor () -> Observation,
    start: @MainActor () async throws -> Void
  ) async {
    while !Task.isCancelled {
      try? await Task.sleep(for: interval)
      if Task.isCancelled { return }
      await check(observe: observe, start: start)
    }
  }
}

/// Which code a helper runs, so an app update that left the helper's code alone
/// leaves the helper running. The build stamps the helper's Info.plist with the
/// last commit that touched its sources or project.yml; the helper records that
/// stamp, with its process id, in `helper.stamp` when it launches. The record is
/// the only way to know: an update replaces the running helper's bundle, so the
/// stamp on disk is the new helper's.
enum HelperStamp {
  static let plistKey = "HQSessionSyncSourceHash"
  static var file: URL { SessionSyncConfig.directory.appendingPathComponent("helper.stamp") }

  /// What the helper process left behind: "<pid> <stamp>".
  struct Record: Equatable {
    var pid: Int32
    var stamp: String
  }

  /// A stamp that names one commit of the helper's code. The build writes "dev"
  /// when git cannot answer and a "-dirty" suffix for uncommitted edits to the
  /// stamped paths: neither says which code runs.
  static func identifiesCode(_ stamp: String?) -> Bool {
    guard let stamp, !stamp.isEmpty, stamp != "dev" else { return false }
    return !stamp.hasSuffix("-dirty")
  }

  /// nil when there is no file (a helper from before stamps) or it is not
  /// "<pid> <stamp>": either way the time rule decides.
  static func read(from url: URL = file) -> Record? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(
      separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 2, let pid = Int32(parts[0]), !parts[1].isEmpty else { return nil }
    return Record(pid: pid, stamp: String(parts[1]))
  }

  /// The running helper calls this once it holds the helper lock.
  static func write(stamp: String, pid: Int32, to url: URL = file) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try Data("\(pid) \(stamp)\n".utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  /// The stamp in a helper bundle's Info.plist, read from disk each time:
  /// `Bundle` caches a bundle's dictionary for the life of the process.
  static func bundled(in helper: URL) -> String? {
    let plist = helper.appendingPathComponent("Contents/Info.plist")
    return (NSDictionary(contentsOf: plist)?[plistKey] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// The order a pass walks conversations in.
enum SyncPassOrder {
  /// Newest activity first, so a conversation being written now is not behind
  /// a week of idle ones on a cold pass; a conversation with no known time goes
  /// last, and ties break on the key so the order is stable.
  static func newestFirst(_ keys: some Sequence<String>, activity: [String: Date]) -> [String] {
    keys.sorted { a, b in
      switch (activity[a], activity[b]) {
      case (let x?, let y?) where x != y: return x > y
      case (.some, nil): return true
      case (nil, .some): return false
      default: return a < b
      }
    }
  }
}

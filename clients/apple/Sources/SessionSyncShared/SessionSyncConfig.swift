import Foundation

/// Names the helper and the app share. Both derive from the app's bundle id
/// (`$(BUNDLE_ID_PREFIX).hq`, Config/Signing.xcconfig); the helper is that id plus
/// `.session-sync`, so a fork with its own prefix never shares a Keychain item,
/// folder or login item with another build.
enum SessionSyncIdentity {
  static let helperSuffix = ".session-sync"

  /// The app's bundle id, read the same way from the app and from the helper.
  static var appBundleID: String {
    let id = Bundle.main.bundleIdentifier ?? "hq"
    return id.hasSuffix(helperSuffix) ? String(id.dropLast(helperSuffix.count)) : id
  }
  static var helperBundleID: String { appBundleID + helperSuffix }
}

struct SessionSyncSource: Codable, Equatable {
  var provider: String
  var path: String
}

struct SessionSyncConfig: Codable {
  /// Whether the helper should run now. Sign-out and Pause both clear it.
  var enabled: Bool
  var personID: String
  var baseURL: String
  var sources: [SessionSyncSource]
  /// The person chose Pause. Only that keeps sync off after a sign-in; sign-out
  /// does not set it. Optional so a file without it still decodes.
  var paused: Bool? = nil
  /// The notice version this Mac's person has answered. Only HQ.app writes it,
  /// after the notice is answered; a file without it uploads nothing.
  var rules: Int? = nil
  static let currentRules = 1

  /// Whether the notice for the current rules has been answered on this Mac.
  var hasAcceptedRules: Bool { (rules ?? 0) >= Self.currentRules }
  /// What the helper checks: on, and told about what uploads.
  var isSyncing: Bool { enabled && hasAcceptedRules }

  static var directory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/\(SessionSyncIdentity.appBundleID)/session-sync")
  }
  static var file: URL { directory.appendingPathComponent("config.json") }
  static var statusFile: URL { directory.appendingPathComponent("status.json") }
  static func load() -> Self? {
    guard let data = try? Data(contentsOf: file) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }
  func save() throws {
    try Self.write(JSONEncoder().encode(self), to: Self.file)
  }
  static func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  static func detectedSources(home: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> [SessionSyncSource]
  {
    let files = FileManager.default
    var result: [SessionSyncSource] = []
    let codex = home.appendingPathComponent(".codex")
    if files.fileExists(atPath: codex.path) {
      result.append(SessionSyncSource(provider: "codex", path: codex.path))
    }
    // ~/.claude, account switchers' ~/.claude-work etc., and the Claude desktop
    // app's per-account CLAUDE_CONFIG_DIR under Application Support/Claude*/code-config.
    // Arbitrary CLAUDE_CONFIG_DIR locations can be added in Settings.
    let support = home.appendingPathComponent("Library/Application Support")
    let roots =
      ((try? files.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.lastPathComponent == ".claude" || $0.lastPathComponent.hasPrefix(".claude-") }
      + ((try? files.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.lastPathComponent.hasPrefix("Claude") }
      .map { $0.appendingPathComponent("code-config") }
    for url in roots.sorted(by: { $0.path < $1.path })
    where files.fileExists(atPath: url.appendingPathComponent("projects").path) {
      result.append(SessionSyncSource(provider: "claude", path: url.path))
    }
    return result
  }

  /// Sign-out stops sync but is not a choice: `paused` stays as it was, so the
  /// next sign-in resumes unless the person had paused.
  func signedOut() -> Self {
    var next = self
    next.enabled = false
    return next
  }

  /// The notice has been answered: the helper may now upload under the current rules.
  func acceptingRules() -> Self {
    var next = self
    next.rules = Self.currentRules
    return next
  }

  /// The person's Pause: sync stays off across sign-ins until Resume.
  func pausedByPerson() -> Self {
    var next = signedOut()
    next.paused = true
    return next
  }

  /// The config to run after a sign-in, or nil when sync is paused on this Mac
  /// (`ignoringPause` is Resume). A pause is the Mac owner's choice, so it holds
  /// whoever signs in or whichever server they use; anyone can Resume in Settings.
  /// Sync is otherwise on by default: no config, a sign-out's `enabled: false`
  /// and another person's config all start it. Added Claude folders carry over
  /// for the same person and server only.
  static func resuming(
    _ previous: SessionSyncConfig?, personID: String, baseURL: String,
    ignoringPause: Bool = false
  ) -> SessionSyncConfig? {
    if previous?.paused == true && !ignoringPause { return nil }
    let same = previous?.personID == personID && previous?.baseURL == baseURL
    // `rules` is not carried: only the notice answer writes it (`acceptingRules`).
    return SessionSyncConfig(
      enabled: true, personID: personID, baseURL: baseURL,
      sources: same ? previous?.sources ?? [] : [])
  }

  /// Configured sources plus everything detected now, deduped by resolved path.
  func effectiveSources(home: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> [SessionSyncSource]
  {
    var seen: Set<String> = []
    return (sources + Self.detectedSources(home: home)).compactMap { source in
      let path = URL(fileURLWithPath: source.path).resolvingSymlinksInPath().path
      guard seen.insert(path).inserted else { return nil }
      return SessionSyncSource(provider: source.provider, path: path)
    }
  }
}

struct SessionSyncStatus: Codable {
  var checkedAt: Date
  var synced: Int
  var pending: Int
  var errors: [String]
}

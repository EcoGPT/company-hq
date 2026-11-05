import AppKit
import Darwin
import Foundation

// The helper owns its Keychain item. Enrollment is passed over an anonymous
// pipe, never argv, environment, plist, disk, or logs. No new key is minted.
if CommandLine.arguments.contains("--configure") {
  do {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard data.count <= 16384,
      let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let token = request["bearer"] as? String, !token.isEmpty,
      let person = request["personID"] as? String,
      let base = request["baseURL"] as? String, SyncTransport.allowed(base)
    else { exit(1) }
    let config = SessionSyncConfig(enabled: false, personID: person, baseURL: base, sources: [])
    try SyncCredential.save(token, config: config)
    // One sign-in at a time: another person's or server's bearer is not kept.
    SyncCredential.forget(keeping: config)
    exit(0)
  } catch { exit(1) }
}

// Sign-out: the app cannot reach this Keychain item (it belongs to the helper), so it asks
// the helper to delete every sign-in it holds.
// Exits 0 only when nothing is left, so the app keeps asking until it is true.
if CommandLine.arguments.contains("--forget") {
  exit(SyncCredential.forget(keeping: nil) ? 0 : 1)
}

// Read-only preview of what the collector would send: titles and counts, no
// network, Keychain, status file or lock. Handled before the lock so it can run
// beside the installed helper. It previews the chats active in the last 7 days
// from any folder whether or not the notice has been answered, and says which.
func dryRun() -> Never {
  setvbuf(stdout, nil, _IOLBF, 0)
  let config = SessionSyncConfig.load()
  let sources = config?.effectiveSources() ?? SessionSyncConfig.detectedSources()
  // `--since-days N` looks back N days instead of the default window. Candidates
  // are chats active within the window of `now`, so the window moves by shifting `now`.
  var days = SessionCollector.activeWindow / 86400
  var now = Date()
  if let flag = CommandLine.arguments.firstIndex(of: "--since-days"),
    let given = CommandLine.arguments.dropFirst(flag + 1).first.flatMap(Double.init), given >= 0
  {
    days = given
    now = now.addingTimeInterval(SessionCollector.activeWindow - given * 86400)
  }
  let window = days == 1 ? "1 day" : "\(days.rounded() == days ? String(Int(days)) : String(days)) days"
  print("Previewing chats active in the last \(window), from any folder, in \(sources.count) source(s).")
  for source in sources {
    print("  \(source.provider)  \((source.path as NSString).abbreviatingWithTildeInPath)")
  }
  if let config {
    if !config.hasAcceptedRules {
      print("Notice: not answered on this Mac yet; nothing uploads until it is.")
    } else if config.paused == true {
      print("Notice: answered. Sync is paused in Settings.")
    } else if !config.enabled {
      print("Notice: answered. Sync is off until the app is signed in.")
    } else {
      print("Notice: answered. Sync is on.")
    }
  } else {
    print("Sync is not configured on this Mac. Once the app is signed in and the notice is answered, it would sync this.")
  }
  print("This mode never contacts the server.")
  var candidates = 0, skipped = 0
  for source in sources {
    var issues = 0
    var found: [SyncCandidate] = []
    do {
      found = try autoreleasepool {
        try SessionCollector.discover(source, now: now, onIssue: { _ in issues += 1 })
      }
    } catch {
      print("\n\(source.provider)  \(source.path)\n  source unavailable or unsupported")
      skipped += 1
      continue
    }
    var lines: [String] = []
    var empty = 0
    for candidate in found.sorted(by: { $0.key < $1.key }) {
      do {
        let snapshot = try SessionCollector.snapshot(candidate, credential: "")
        let shown = snapshot.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        lines.append("  \(candidate.key)  \(snapshot.messages.count) messages  \(shown.prefix(100))")
      } catch {
        empty += 1
        lines.append("  \(candidate.key)  skipped: \(SyncReason.of(error))")
      }
    }
    candidates += found.count - empty
    skipped += issues + empty
    print("\n\(source.provider)  \(source.path)\n  \(found.count - empty) candidates, \(issues + empty) skipped")
    lines.forEach { print($0) }
  }
  print("\nTotal: \(candidates) candidates, \(skipped) skipped")
  exit(0)
}
if CommandLine.arguments.contains("--dry-run") { dryRun() }

// flock prevents duplicate collectors during app upgrades or manual launches.
try FileManager.default.createDirectory(
  at: SessionSyncConfig.directory, withIntermediateDirectories: true,
  attributes: [.posixPermissions: 0o700])
let lock = open(
  SessionSyncConfig.directory.appendingPathComponent("helper.lock").path, O_CREAT | O_RDWR, 0o600)
guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }

// Record which code this helper runs. An app update replaces this bundle under
// the running process, so the app can only tell from this record whether the
// bundled helper's code differs (`HelperStamp`). Only the helper that holds the
// lock writes it.
let ownStamp = Bundle.main.object(forInfoDictionaryKey: HelperStamp.plistKey) as? String
if let ownStamp, !ownStamp.isEmpty {
  try? HelperStamp.write(stamp: ownStamp, pid: getpid())
}

// Give the helper its own application identity so the app can retire it on
// pause/sign-out/upgrades without touching the main app process.
NSApplication.shared.setActivationPolicy(.prohibited)

// Folding and hashing run below the person's foreground apps.
Task(priority: .utility) {
  var acknowledged: [String: String] = [:]
  var verification = SyncVerification()
  var refusals = RefusalMemo()
  var scope: Data?
  while true {
    guard let config = SessionSyncConfig.load() else {
      try? await Task.sleep(for: .seconds(15))
      continue
    }
    // A config the notice has not been answered for uploads nothing until the app
    // records the answer (`hasAcceptedRules`).
    if config.enabled && !config.hasAcceptedRules {
      try? await Task.sleep(for: .seconds(15))
      continue
    }
    guard config.isSyncing, let token = await SyncCredential.load(config) else {
      if config.enabled {
        let status = SessionSyncStatus(
          checkedAt: Date(), synced: 0, pending: 0,
          errors: ["Sign-in unavailable; open the app to reconnect"])
        try? SessionSyncConfig.write(JSONEncoder().encode(status), to: SessionSyncConfig.statusFile)
      }
      try? await Task.sleep(for: .seconds(15))
      continue
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let currentScope = try? encoder.encode(config)
    if currentScope != scope {
      acknowledged = [:]
      verification = SyncVerification()
      refusals = RefusalMemo()
      scope = currentScope
    }
    var status = SessionSyncStatus(checkedAt: Date(), synced: 0, pending: 0, errors: [])
    do {
      let transport = try verification.transport(config: config, token: token)
      defer { transport.close() }
      var candidates: [String: [SyncCandidate]] = [:]
      var unlisted: [String] = []
      for source in config.effectiveSources() {
        let label = "\(source.provider) · \(URL(fileURLWithPath: source.path).lastPathComponent)"
        do {
          let found = try autoreleasepool {
            try SessionCollector.discover(source, onIssue: { status.errors.append($0) })
          }
          for candidate in found { candidates[candidate.key, default: []].append(candidate) }
        } catch {
          unlisted.append(source.path)
          status.errors.append("\(label): source unavailable or unsupported")
        }
      }
      // Newest activity first: a restarted helper folds a week of chats on its
      // first pass, and the chat being written now should not wait behind them.
      var activity: [String: Date] = [:]
      for (key, matches) in candidates {
        let times = matches.flatMap { candidate -> [Date] in
          if candidate.source.provider == "codex" {
            return SessionCollector.activity(codex: candidate.metadata).map {
              [Date(timeIntervalSince1970: $0)]
            } ?? []
          }
          return candidate.paths.compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
          }
        }
        if let newest = times.max() { activity[key] = newest }
      }
      for key in SyncPassOrder.newestFirst(candidates.keys, activity: activity) {
        guard let matches = candidates[key], matches.count == 1, let candidate = matches.first
        else {
          // One folder joins a conversation's own files; the same conversation
          // in two folders is two copies, and the server cannot choose between them.
          let folders = (candidates[key] ?? []).map { ($0.source.path as NSString).abbreviatingWithTildeInPath }
          let provider = key.hasPrefix("codex/") ? "Codex" : "Claude"
          let count = folders.count == 2 ? "two" : "\(folders.count)"
          status.errors.append(
            "\(key): same conversation in \(count) \(provider) folders: " + folders.joined(separator: ", "))
          continue
        }
        // What identifies this conversation's content now; cheap when nothing changed.
        func fingerprint() -> String? {
          try? transport.acknowledgement(
            SessionCollector.snapshot(candidate, credential: token), key: key)
        }
        if refusals.isHeld(key, fingerprint: fingerprint) {
          status.errors.append("\(key): \(refusals.reason(key) ?? "The server refused this conversation")")
          continue
        }
        do {
          if candidate.archived {
            // Archived locally: hidden on the server, never uploaded.
            if acknowledged[key] != "archived" {
              try await transport.archive(candidate)
              acknowledged[key] = "archived"
            }
            continue
          }
          acknowledged[key] = try await transport.sync(
            candidate, acknowledged: acknowledged[key])
          status.synced += 1
          refusals.clear(key)
        } catch SyncFailure.empty {
          status.pending += 1
        } catch {
          let reason = SyncReason.of(error)
          if RefusalMemo.isRefusal(error) {
            // The content that was sent, not what the file holds now: lines added since
            // were never sent and must not be held.
            refusals.refuse(key, fingerprint: transport.attempted(key), reason: reason)
          }
          status.errors.append("\(key): \(reason)")
        }
      }
      refusals.keep(Set(candidates.keys))
      // Only now, never by the clock mid-pass: what this pass did not use is a chat
      // that left the window or a file that is gone. A source that could not be
      // listed keeps its own chats for the next pass; the others are still swept.
      SessionCollector.transcripts.endPass(keeping: unlisted)
    } catch { status.errors.append("The server address or a source folder is not valid") }
    // Status contains receipts/errors only, never conversation text.
    try? SessionSyncConfig.write(JSONEncoder().encode(status), to: SessionSyncConfig.statusFile)
    try? await Task.sleep(for: .seconds(15))
  }
}
NSApplication.shared.run()

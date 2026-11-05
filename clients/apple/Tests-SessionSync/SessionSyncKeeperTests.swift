import Foundation
import XCTest

/// HQ.app keeps the helper running: a dead one is relaunched, Pause and the
/// other off states are left alone, and a helper is retired only when its code
/// differs from the bundled helper's.
struct SessionSyncKeeperTests {
  static func check(_ condition: Bool, _ message: String) {
    guard !condition else { return }
    XCTFail(message)
  }

  /// A Mac with one helper slot. `start` behaves like `SessionSyncAgent.start`:
  /// it launches nothing while the config is paused or a helper is still listed.
  @MainActor final class FakeMac {
    var config: SessionSyncConfig? = SessionSyncConfig(
      enabled: true, personID: "p1", baseURL: "https://hq.example.com", sources: []
    ).acceptingRules()
    var personID: String? = "p1"
    var isNoticeAnswered = true
    var isAllowed = true
    var isLoginItemEnabled = true
    var isListed = true
    var launches = 0
    var events: [String] = []

    var observation: SessionSyncKeeper.Observation {
      SessionSyncKeeper.Observation(
        config: config, personID: personID, baseURL: "https://hq.example.com",
        isNoticeAnswered: isNoticeAnswered, isAllowed: isAllowed,
        isLoginItemEnabled: isLoginItemEnabled, isHelperRunning: isListed)
    }

    func start() async throws {
      events.append("start")
      if config?.paused == true || isListed { return }
      isListed = true
      launches += 1
    }
  }

  @MainActor static func didBecomeTrue(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
  }

  @MainActor static func run() async throws {
    try await relaunchesDeadHelper()
    try await pauseKeepsItStopped()
    offStatesNeverRelaunch()
    outdatedHelpers()
    stampedHelpers()
    helperStamps()
    passOrder()
  }

  @MainActor static func keeper(_ mac: FakeMac) -> Task<Void, Never> {
    Task { @MainActor in
      await SessionSyncKeeper.run(
        every: .milliseconds(10), observe: { mac.observation }, start: { try await mac.start() })
    }
  }

  @MainActor static func relaunchesDeadHelper() async throws {
    let mac = FakeMac()
    let loop = keeper(mac)
    defer { loop.cancel() }
    try await Task.sleep(for: .milliseconds(60))
    check(mac.launches == 0, "a running helper is left alone")
    // The helper stops without a trace, as on 2026-10-19.
    mac.isListed = false
    check(await didBecomeTrue { mac.isListed }, "a dead helper is relaunched on the next check")
    check(mac.launches == 1, "exactly one relaunch, got \(mac.launches)")
    try await Task.sleep(for: .milliseconds(60))
    check(mac.launches == 1, "a relaunched helper is not launched again")
    print("PASS a dead helper is relaunched within one check")
  }

  @MainActor static func pauseKeepsItStopped() async throws {
    let mac = FakeMac()
    let loop = keeper(mac)
    defer { loop.cancel() }
    // Settings → Pause: the config says paused and the helper is stopped.
    mac.config = mac.config?.pausedByPerson()
    mac.isListed = false
    try await Task.sleep(for: .milliseconds(100))
    check(!mac.isListed && mac.events.isEmpty, "Pause is never answered by a relaunch")
    // Resume: `restore` clears the pause; the keeper takes over again.
    mac.config = SessionSyncConfig.resuming(
      mac.config, personID: "p1", baseURL: "https://hq.example.com", ignoringPause: true)?
      .acceptingRules()
    check(await didBecomeTrue { mac.isListed }, "after Resume a dead helper is relaunched again")
    print("PASS Pause keeps a stopped helper stopped")
  }

  @MainActor static func offStatesNeverRelaunch() {
    func relaunches(_ change: (FakeMac) -> Void) -> Bool {
      let mac = FakeMac()
      mac.isListed = false
      change(mac)
      return SessionSyncKeeper.shouldRelaunch(mac.observation)
    }
    check(relaunches { _ in }, "the baseline: sync on, no helper")
    check(!relaunches { $0.config = $0.config?.pausedByPerson() }, "paused")
    check(!relaunches { $0.config = $0.config?.signedOut() }, "signed out (config)")
    check(!relaunches { $0.personID = nil }, "signed out (no session)")
    check(!relaunches { $0.isNoticeAnswered = false }, "notice unanswered for this person")
    check(
      !relaunches { $0.config?.rules = nil }, "notice unanswered (a previous client's config, no rules)")
    check(!relaunches { $0.config = nil }, "no config yet")
    check(!relaunches { $0.personID = "p2" }, "another person signed in before restore rewrote the config")
    check(
      !relaunches { $0.config?.baseURL = "https://hq.dev.example.com" }, "a config for another hub")
    check(!relaunches { $0.isLoginItemEnabled = false }, "Login Items not approved")
    check(!relaunches { $0.isAllowed = false }, "a worktree, test host or Debug build")
    check(!relaunches { $0.isListed = true }, "a helper is already running")
    print("PASS sign-out, an unanswered notice, another person or hub, Login Items and blocked builds never relaunch")
  }

  /// An app launch retires a helper only when it is older than the installed
  /// binary. The times are a build and the install that followed it.
  static func outdatedHelpers() {
    let built = Date(timeIntervalSince1970: 1_793_230_906)
    let installed = built.addingTimeInterval(9_861)
    func isOutdatedHelper(_ started: Date?) -> Bool {
      SessionSyncKeeper.isOutdated(started: started, modified: built, changed: installed)
    }
    check(isOutdatedHelper(built.addingTimeInterval(-12 * 86_400)), "a helper from an earlier build is outdated")
    check(
      isOutdatedHelper(built.addingTimeInterval(3_600)),
      "a helper started after the build but before the install is outdated")
    check(!isOutdatedHelper(installed.addingTimeInterval(204)), "a helper started after the install is current")
    check(!isOutdatedHelper(installed), "a helper started the instant of the install is current")
    check(isOutdatedHelper(nil), "a helper with no start time is outdated, as before")
    check(
      !SessionSyncKeeper.isOutdated(
        started: installed, modified: installed.addingTimeInterval(600), changed: installed),
      "a build stamped ahead of this Mac's clock does not make a fresh helper outdated")
    check(
      !SessionSyncKeeper.isOutdated(started: installed, modified: built, changed: nil),
      "without a status-change time the modification time decides")
    check(
      SessionSyncKeeper.isOutdated(started: installed, modified: nil, changed: nil),
      "an unreadable binary makes the helper outdated, as before")
    print("PASS only a helper older than the installed binary is retired")
  }

  /// An update replaces the helper's bundle, so a running helper is judged by
  /// the stamp it recorded when it launched, not by file times: one that
  /// started before the install is kept when its code is the bundled code.
  static func stampedHelpers() {
    let built = Date(timeIntervalSince1970: 1_793_230_906)
    let installed = built.addingTimeInterval(9_861)
    let before = installed.addingTimeInterval(-86_400)  // started a day before the update
    let after = installed.addingTimeInterval(204)  // started after the update
    func isOutdatedHelper(
      started: Date? = before, _ recorded: HelperStamp.Record?, bundled: String? = "a1b2c3d",
      pid: Int32 = 4242
    ) -> Bool {
      SessionSyncKeeper.isOutdated(
        started: started, modified: built, changed: installed, recorded: recorded, pid: pid,
        bundled: bundled)
    }
    let same = HelperStamp.Record(pid: 4242, stamp: "a1b2c3d")
    check(
      !isOutdatedHelper(same),
      "an update that left the helper's code alone keeps a helper that started before it")
    check(
      !SessionSyncKeeper.isOutdated(
        started: nil, modified: nil, changed: nil, recorded: same, pid: 4242, bundled: "a1b2c3d"),
      "the same stamp is kept whatever the file times say")
    check(
      isOutdatedHelper(HelperStamp.Record(pid: 4242, stamp: "9f8e7d6")),
      "a different stamp retires the helper")
    check(
      isOutdatedHelper(started: after, HelperStamp.Record(pid: 4242, stamp: "9f8e7d6")),
      "a different stamp retires even a helper that started after the install")
    // No record, or one that cannot be read (a helper from before stamps, or one
    // that could not replace the file): today's time rule, so a broken record
    // never kills a healthy helper on every launch.
    check(isOutdatedHelper(nil), "no record, started before the install: retired")
    check(!isOutdatedHelper(started: after, nil), "no record, started after the install: kept")
    // Another process's record says nothing about this one.
    check(
      isOutdatedHelper(HelperStamp.Record(pid: 777, stamp: "a1b2c3d")),
      "a record from another process falls back to the time rule: before the install")
    check(
      !isOutdatedHelper(started: after, HelperStamp.Record(pid: 777, stamp: "9f8e7d6")),
      "a record from another process falls back to the time rule: after the install")
    // A stamp that cannot name code decides nothing.
    for unnamed in ["dev", "a1b2c3d-dirty", ""] {
      check(
        isOutdatedHelper(HelperStamp.Record(pid: 4242, stamp: "a1b2c3d"), bundled: unnamed),
        "a bundled stamp of '\(unnamed)' falls back to the time rule: before")
      check(
        !isOutdatedHelper(started: after, HelperStamp.Record(pid: 4242, stamp: "a1b2c3d"), bundled: unnamed),
        "a bundled stamp of '\(unnamed)' falls back to the time rule: after")
    }
    for unnamed in ["dev", "a1b2c3d-dirty"] {
      check(
        isOutdatedHelper(HelperStamp.Record(pid: 4242, stamp: unnamed)),
        "a recorded stamp of '\(unnamed)' falls back to the time rule: before")
      check(
        !isOutdatedHelper(started: after, HelperStamp.Record(pid: 4242, stamp: unnamed)),
        "a recorded stamp of '\(unnamed)' falls back to the time rule: after")
    }
    check(
      isOutdatedHelper(same, bundled: nil),
      "no bundled stamp falls back to the time rule: before")
    check(
      !isOutdatedHelper(started: after, same, bundled: nil),
      "no bundled stamp falls back to the time rule: after")
    print("PASS an update keeps a helper whose code is unchanged and retires one whose code differs")
  }

  /// The record a helper leaves, and the stamp the build puts in its bundle.
  static func helperStamps() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("hq-helper-stamp-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("helper.stamp")
    check(HelperStamp.read(from: file) == nil, "no file is no record")
    func put(_ text: String) { try? Data(text.utf8).write(to: file) }
    for broken in ["", "garbage", "4242", "4242 ", "x a1b2c3d", "4242 a1b2c3d extra"] {
      put(broken)
      check(HelperStamp.read(from: file) == nil, "'\(broken)' is no record")
    }
    try? Data([0xff, 0xfe, 0x20, 0x31]).write(to: file)
    check(HelperStamp.read(from: file) == nil, "bytes that are not text are no record")
    // The helper's own write: readable, and private to the person.
    try? FileManager.default.removeItem(at: file)
    do { try HelperStamp.write(stamp: "a1b2c3d", pid: 4242, to: file) } catch {
      check(false, "writing the record failed: \(error)")
    }
    check(
      HelperStamp.read(from: file) == HelperStamp.Record(pid: 4242, stamp: "a1b2c3d"),
      "a written record reads back")
    let mode = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int
    check(mode == 0o600, "the record is 0600, got \(String(describing: mode))")
    check(HelperStamp.identifiesCode("a1b2c3d"), "a short commit names code")
    for unnamed in [nil, "", "dev", "a1b2c3d-dirty"] as [String?] {
      check(!HelperStamp.identifiesCode(unnamed), "\(unnamed ?? "nil") does not name code")
    }
    // The bundled stamp is read from disk each time, so a replaced bundle shows its new value.
    let helper = root.appendingPathComponent("HQSessionSync.app")
    func bundle(_ info: [String: Any]) {
      try? FileManager.default.createDirectory(
        at: helper.appendingPathComponent("Contents"), withIntermediateDirectories: true)
      try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: helper.appendingPathComponent("Contents/Info.plist"))
    }
    check(HelperStamp.bundled(in: helper) == nil, "a helper with no bundle has no stamp")
    bundle(["CFBundleIdentifier": "t"])
    check(HelperStamp.bundled(in: helper) == nil, "a helper whose plist has no stamp has none")
    bundle(["CFBundleIdentifier": "t", HelperStamp.plistKey: "a1b2c3d"])
    check(HelperStamp.bundled(in: helper) == "a1b2c3d", "the bundled stamp is read")
    bundle(["CFBundleIdentifier": "t", HelperStamp.plistKey: "9f8e7d6"])
    check(HelperStamp.bundled(in: helper) == "9f8e7d6", "a replaced bundle shows its new stamp")
    print("PASS the helper's launch record and the bundled stamp read back, and broken records read as none")
  }

  /// A pass folds the newest conversations first.
  static func passOrder() {
    let now = Date(timeIntervalSince1970: 1_793_230_906)
    let activity: [String: Date] = [
      "claude/aaa": now.addingTimeInterval(-6 * 86_400),
      "claude/zzz": now,
      "codex/mmm": now.addingTimeInterval(-60),
      "claude/ccc": now.addingTimeInterval(-6 * 86_400),
    ]
    let keys = ["claude/aaa", "claude/zzz", "codex/mmm", "claude/ccc", "claude/ddd", "claude/bbb"]
    let order = SyncPassOrder.newestFirst(keys, activity: activity)
    check(
      order == ["claude/zzz", "codex/mmm", "claude/aaa", "claude/ccc", "claude/bbb", "claude/ddd"],
      "newest first, ties and unknown times by key: \(order)")
    check(
      SyncPassOrder.newestFirst(keys.reversed(), activity: activity) == order,
      "input order does not matter")
    check(SyncPassOrder.newestFirst([String](), activity: [:]).isEmpty, "no conversations, no order")
    print("PASS a pass walks the newest conversations first")
  }
}

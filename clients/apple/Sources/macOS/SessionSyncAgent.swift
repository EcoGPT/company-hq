import AppKit
import Darwin
import ServiceManagement
import SwiftUI

enum SessionSyncAgent {
  /// The helper's bundle id: the app's plus `.session-sync` (`SessionSyncIdentity`).
  static var identifier: String { SessionSyncIdentity.helperBundleID }
  static var helper: URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/HQSessionSync.app")
  }
  static var binary: URL { helper.appendingPathComponent("Contents/MacOS/HQSessionSync") }

  /// Session sync runs only in a build signed with an Apple team (`HQ_SIGNING_MODE=team`).
  /// The helper keeps the sign-in in its own Keychain item, which the Keychain ties to the
  /// code that made it; an ad-hoc build has a new identity each time it is built, so after
  /// a rebuild the helper's read of the item waits on a system prompt nobody can answer
  /// (docs/session-sync.md). A local build leaves sync off and says so in Settings.
  #if HQ_SESSION_SYNC
  static let isBuilt = true
  #else
  static let isBuilt = false
  #endif

  /// Hand-offs of the sign-in and the helper's deletes of it run one at a time, in order, so a
  /// delete that is still waiting from a sign-out can never land after the next sign-in's save.
  static let signInGate = SerialGate()

  static func configure(
    _ session: StoredSession, base: String, directory: URL = SessionSyncConfig.directory,
    run: @escaping @Sendable (Data) async throws -> Void = { try await runHelper(["--configure"], input: $0) }
  ) async throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "bearer": session.bearer,
      "personID": session.person.id, "baseURL": base,
    ])
    try await signInGate.run {
      // The helper replaces every other saved sign-in with this one, so a delete still owed
      // from a sign-out is no longer owed.
      ForgetPending.clear(in: directory)
      try await run(data)
    }
  }

  /// Sign-out: has the helper delete the sign-in it holds (its Keychain item belongs to the
  /// helper's code identity, so only the helper can). `ForgetPending` is set first and cleared
  /// only when the helper reports success, so a failure is retried (`retryPendingForget`).
  /// Does nothing when no delete is owed: a sign-in since then has replaced the sign-in.
  static func forgetSignIn(
    directory: URL = SessionSyncConfig.directory,
    run: @escaping @Sendable () async throws -> Void = { try await runHelper(["--forget"], input: Data()) }
  ) async {
    await signInGate.run {
      guard ForgetPending.isSet(in: directory) else { return }
      do {
        try await run()
        ForgetPending.clear(in: directory)
      } catch {}
    }
  }

  /// At launch: finishes a delete a sign-out could not.
  @MainActor
  static func retryPendingForget(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async {
    guard !isBlocked(environment), ForgetPending.isSet() else { return }
    await forgetSignIn()
  }

  struct HelperFailure: Error, Equatable {
    var status: Int32
  }

  /// Runs the helper with `arguments`, gives it `input` on stdin, and returns when it exits 0.
  /// Waits for the process to end, not on a thread: a helper that never answers (a Keychain
  /// read on a prompt) is stopped after `timeout`. A helper that exits before reading its
  /// input is a failure, not a crash of the app (no SIGPIPE on the pipe).
  static func runHelper(
    executable: URL = binary, _ arguments: [String], input: Data, timeout: TimeInterval = 20,
    writingAfter delay: TimeInterval = 0
  ) async throws {
    let child = Child()
    child.process.executableURL = executable
    child.process.arguments = arguments
    child.process.standardInput = child.pipe
    child.process.standardOutput = FileHandle.nullDevice
    child.process.standardError = FileHandle.nullDevice
    // A write to a pipe nobody reads raises EPIPE instead of killing this process.
    _ = fcntl(child.pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      child.process.terminationHandler = {
        child.cancelStop()
        continuation.resume(returning: $0.terminationStatus)
      }
      do { try child.process.run() } catch {
        child.process.terminationHandler = nil
        continuation.resume(throwing: error)
        return
      }
      child.stop(after: timeout)
      child.feed(input, after: delay)
    }
    guard status == 0 else { throw HelperFailure(status: status) }
  }

  /// A running helper, its stdin, and the timer that stops it.
  private final class Child: @unchecked Sendable {
    let process = Process()
    let pipe = Pipe()
    private let lock = NSLock()
    private var timer: DispatchWorkItem?
    func stop(after seconds: TimeInterval) {
      let item = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
      lock.withLock { timer?.cancel(); timer = item }
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }
    func cancelStop() { lock.withLock { timer?.cancel() } }
    /// Writes `data` to the helper's stdin and closes it, off the caller's thread. A helper that
    /// is gone makes the write fail; it is stopped, and its exit status is the result.
    func feed(_ data: Data, after delay: TimeInterval) {
      DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
        do {
          try pipe.fileHandleForWriting.write(contentsOf: data)
          try pipe.fileHandleForWriting.close()
        } catch {
          try? pipe.fileHandleForWriting.close()
          stop(after: 0)
        }
      }
    }
  }

  /// Every method below that registers the login item, retires or launches
  /// the helper, or rewrites its settings returns false and touches nothing
  /// when this process must not alter the system (HQ_NO_SYSTEM_REGISTRATION
  /// or a unit-test host): a worktree or test build would otherwise retire
  /// the installed app's sync helper and start one from its build folder.
  private static func isBlocked(_ environment: [String: String]) -> Bool {
    !isBuilt || SessionSyncGate.isSystemTouchBlocked(environment: environment)
  }

  enum StartFailure: Error {
    /// macOS lists the login item under Login Items & Extensions as waiting for the person.
    case needsApproval
  }

  /// What turning sync on did. `unanswered`: the notice was closed without a
  /// button, so nothing was recorded, written or started. `unavailable`: this build
  /// is not signed with a team (`isBuilt`).
  enum Outcome: Equatable {
    case blocked, signedOut, paused, running, needsApproval, failed, unanswered, unavailable
  }

  /// What turning sync on does to the Mac, behind one seam so a test can record
  /// the order of the steps (the notice, then the sign-in, then the start)
  /// without touching the real config, Keychain, login item or helper.
  struct Effects {
    var loadConfig: () -> SessionSyncConfig? = { SessionSyncConfig.load() }
    var saveConfig: (SessionSyncConfig) throws -> Void = { try $0.save() }
    /// Shows the notice for a server address and returns the person's answer.
    var showNotice: @MainActor (SessionSyncNotice.Kind, String) async -> SessionSyncNotice.Choice = {
      await SessionSyncNotice.present($0, server: $1)
    }
    /// Retires any running helper while the notice is unanswered, and returns
    /// once it has exited so a later start launches a fresh one.
    var retireHelpers: @MainActor () async -> Void = { await SessionSyncAgent.retireAndWait() }
    var configure: (StoredSession, String) async throws -> Void = {
      try await SessionSyncAgent.configure($0, base: $1)
    }
    var start: @MainActor () async throws -> Void = { _ = try await SessionSyncAgent.start() }
    var halt: @MainActor () -> Void = { SessionSyncAgent.haltHelper() }
    var writeStatus: (SessionSyncStatus) -> Void = {
      try? SessionSyncConfig.write(JSONEncoder().encode($0), to: SessionSyncConfig.statusFile)
    }
    var openLoginItems: @MainActor () -> Void = { SMAppService.openSystemSettingsLoginItems() }
  }

  /// Sync is on whenever the app has a signed-in session, unless the person paused
  /// it: a missing config, a sign-out's `enabled: false` and a revoked and
  /// renewed sign-in all start it. Runs on each launch and device change
  /// (`MenuBarIcon`). `isCurrent` says whether `session` is still the signed-in
  /// one, so a sign-out during the awaits below cannot be undone. A Debug
  /// build (DerivedData, a worktree) stays off unless HQ_ALLOW_SYSTEM_REGISTRATION=1:
  /// it would otherwise upload and register a login item of its own beside the
  /// installed app's.
  @MainActor @discardableResult
  static func restore(
    _ session: StoredSession?,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard,
    isDebugBuild: Bool = SessionSyncGate.isDebugBuild,
    effects: Effects = Effects(),
    isCurrent: () -> Bool = { true }
  ) async -> Bool {
    let outcome = await turnOn(
      session, isAutomatic: true, environment: environment, defaults: defaults,
      isDebugBuild: isDebugBuild, effects: effects, isCurrent: isCurrent)
    return ![.blocked, .signedOut, .paused, .unanswered, .unavailable].contains(outcome)
  }

  /// Settings → Resume: clears Pause, then the same as `restore`.
  @MainActor @discardableResult
  static func resume(
    _ session: StoredSession?,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard,
    effects: Effects = Effects(),
    isCurrent: () -> Bool = { true }
  ) async -> Outcome {
    await turnOn(
      session, ignoringPause: true, environment: environment, defaults: defaults,
      isDebugBuild: SessionSyncGate.isDebugBuild, effects: effects, isCurrent: isCurrent)
  }

  /// The order matters: the notice is answered before the first start, so
  /// nothing is uploaded that the person has not been told about (only the OK
  /// button accepts; a closed panel is `.unanswered` and asks again next launch), and the
  /// saved config is read again after every wait so a Pause made meanwhile
  /// (here or in Settings) is never overwritten.
  @MainActor
  static func turnOn(
    _ session: StoredSession?, isAutomatic: Bool = false, ignoringPause: Bool = false,
    environment: [String: String], defaults: UserDefaults, isDebugBuild: Bool,
    effects: Effects, isCurrent: () -> Bool, isBuilt: Bool = SessionSyncAgent.isBuilt
  ) async -> Outcome {
    guard isBuilt else { return .unavailable }
    guard !SessionSyncGate.isSystemTouchBlocked(environment: environment) else { return .blocked }
    if isAutomatic,
      !SessionSyncGate.isRegistrationAllowed(environment: environment, isDebugBuild: isDebugBuild)
    {
      return .blocked
    }
    // Sign-out already stopped sync; there is nothing to turn on without a sign-in.
    guard let session else { return .signedOut }
    let person = session.person.id
    let base = HQConfig.baseURLString
    func plan() -> SessionSyncConfig? {
      SessionSyncConfig.resuming(
        effects.loadConfig(), personID: person, baseURL: base, ignoringPause: ignoringPause)
    }
    guard plan() != nil else { return .paused }
    let isFirstStart = SessionSyncNotice.shouldShow(
      defaults: defaults, personID: person, baseURL: base)
    if isFirstStart {
      // A helper from before the notice runs on old rules until something stops
      // it: stop it now, and the new one idles until the answer.
      await effects.retireHelpers()
      let choice = await effects.showNotice(.intro, base)
      // Only a button answers. A close, ⌘W, Escape or any other value leaves
      // the notice unrecorded and the config as it was.
      guard choice == .ok || choice == .pause else { return .unanswered }
      SessionSyncNotice.markShown(defaults: defaults, personID: person, baseURL: base)
      if choice == .pause {
        // The person's own choice, kept even if they signed out meanwhile.
        if let next = plan() { try? effects.saveConfig(next.pausedByPerson()) }
        effects.halt()
        return .paused
      }
      guard isCurrent() else { return .signedOut }
    }
    var outcome = Outcome.running
    do {
      guard plan() != nil else { return .paused }
      try await effects.configure(session, base)
      guard isCurrent() else { return .signedOut }
      // Read again: a Pause during the awaits above stands.
      guard let config = plan() else { return .paused }
      // The one place `rules` is written: the notice has been answered (just
      // now, or on an earlier launch), so the helper may upload under the
      // current rules. A file without it stays idle until it gets here.
      try effects.saveConfig(config.acceptingRules())
      try await effects.start()
    } catch StartFailure.needsApproval {
      outcome = .needsApproval
      effects.writeStatus(
        SessionSyncStatus(
          checkedAt: Date(), synced: 0, pending: 0,
          errors: ["Allow HQ in System Settings → General → Login Items & Extensions"]))
    } catch {
      effects.writeStatus(
        SessionSyncStatus(
          checkedAt: Date(), synced: 0, pending: 0,
          errors: ["Background sync needs attention in Settings → Coding"]))
      return .failed
    }
    // Asked once, with the notice; Settings keeps saying it afterwards.
    if outcome == .needsApproval, isFirstStart,
      await effects.showNotice(.loginItems, base) == .openLoginItems
    {
      effects.openLoginItems()
    }
    return outcome
  }

  /// Retires the running helpers and waits (up to two seconds) for them to
  /// exit, so the `start()` that may follow sees none left and launches one.
  @MainActor
  static func retireAndWait(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async {
    let running = runningHelpers()
    guard retireRunningHelpers(environment: environment) else { return }
    for _ in 0..<20 {
      if !running.contains(where: isAlive) { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  /// Helpers whose process still exists. NSWorkspace drops an exited app only
  /// once its notification is handled, so its list alone can name a helper
  /// that is already gone, and `start()` would then launch none.
  @MainActor
  static func runningHelpers() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == identifier && isAlive($0) }
  }

  private static func isAlive(_ app: NSRunningApplication) -> Bool {
    !app.isTerminated && kill(app.processIdentifier, 0) == 0
  }

  /// When a process started, from the kernel.
  private static func processStart(_ pid: pid_t) -> Date? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    let seconds = TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
    return Date(timeIntervalSince1970: seconds)
  }

  /// Relaunches a helper that stopped while sync is on, for as long as HQ
  /// runs (`MenuBarIcon`). Pause, sign-out, an unanswered notice, a
  /// Login Items refusal and a worktree or Debug build all leave it stopped
  /// (`SessionSyncKeeper.shouldRelaunch`).
  @MainActor
  static func keepAlive(
    session: @escaping @MainActor () -> StoredSession?,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async {
    await retryPendingForget(environment: environment)
    await SessionSyncKeeper.run(
      observe: {
        let person = session()?.person.id
        let base = HQConfig.baseURLString
        return SessionSyncKeeper.Observation(
          config: SessionSyncConfig.load(), personID: person, baseURL: base,
          isNoticeAnswered: person.map {
            !SessionSyncNotice.shouldShow(defaults: .standard, personID: $0, baseURL: base)
          } ?? false,
          isAllowed: !isBlocked(environment)
            && SessionSyncGate.isRegistrationAllowed(
              environment: environment, isDebugBuild: SessionSyncGate.isDebugBuild),
          isLoginItemEnabled: SMAppService.loginItem(identifier: identifier).status == .enabled,
          isHelperRunning: !runningHelpers().isEmpty)
      },
      start: { _ = try await start(environment: environment) })
  }

  /// SIGTERMs every running helper.
  @MainActor @discardableResult
  static func retireRunningHelpers(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    guard !isBlocked(environment) else { return false }
    NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == identifier }
      .forEach { _ = kill($0.processIdentifier, SIGTERM) }
    return true
  }

  @MainActor @discardableResult
  static func start(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> Bool {
    guard !isBlocked(environment) else { return false }
    // Pause unregisters the login item; nothing else may bring it back.
    if SessionSyncConfig.load()?.paused == true { return false }
    let service = SMAppService.loginItem(identifier: identifier)
    // A newly embedded helper can have no background-item record yet (.notFound).
    // Registration creates that record; the enabled check still honors user approval.
    if service.status != .enabled {
      do { try service.register() } catch {
        if service.status != .requiresApproval { throw error }
      }
    }
    if service.status == .requiresApproval { throw StartFailure.needsApproval }
    guard service.status == .enabled else {
      throw NSError(domain: "Allow HQ in macOS Login Items", code: 1)
    }
    // A running helper whose code differs from the bundled one is retired; its
    // config survives upgrades. An update that left the helper's code alone
    // leaves it running, since a restarted helper refolds a week of chats.
    // launchd starts the login item without LaunchServices, so its launchDate
    // is nil and the kernel's start time stands in (the time rule, used when
    // the helper recorded no stamp at launch).
    let times = try? binary.resourceValues(
      forKeys: [.contentModificationDateKey, .attributeModificationDateKey])
    let running = runningHelpers()
    let recorded = HelperStamp.read()
    let bundled = HelperStamp.bundled(in: helper)
    let stale = running.filter { app in
      guard app.bundleURL == helper else { return true }
      return SessionSyncKeeper.isOutdated(
        started: app.launchDate ?? processStart(app.processIdentifier),
        modified: times?.contentModificationDate, changed: times?.attributeModificationDate,
        recorded: recorded, pid: app.processIdentifier, bundled: bundled)
    }
    stale.forEach { _ = kill($0.processIdentifier, SIGTERM) }
    for _ in 0..<20 {
      if !stale.contains(where: { kill($0.processIdentifier, 0) == 0 }) { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    // A Pause during the waits above must not be answered by a launch.
    if SessionSyncConfig.load()?.paused == true { return false }
    if running.isEmpty || !stale.isEmpty {
      let process = Process()
      process.executableURL = binary
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
    }
    return true
  }

  /// Sign-out: stops the helper but leaves `paused` as it was,
  /// so the next sign-in turns sync back on unless the person had paused it.
  @MainActor @discardableResult
  static func disable(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    stop(environment: environment, forgetsSignIn: true) { $0.signedOut() }
  }

  /// Settings → Pause: the same stop, and sync stays off across sign-ins until Resume.
  @MainActor @discardableResult
  static func pause(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    stop(environment: environment) { $0.pausedByPerson() }
  }

  @MainActor
  private static func stop(
    environment: [String: String], forgetsSignIn: Bool = false,
    _ change: (SessionSyncConfig) -> SessionSyncConfig
  ) -> Bool {
    // A Debug build never started sync, so its sign-out must not stop the helper of
    // an installed app that shares its bundle id.
    guard
      isBuilt,
      SessionSyncGate.isRegistrationAllowed(
        environment: environment, isDebugBuild: SessionSyncGate.isDebugBuild)
    else { return false }
    if let config = SessionSyncConfig.load() {
      try? change(config).save()
    }
    haltHelper()
    if forgetsSignIn {
      ForgetPending.set()
      Task { await forgetSignIn() }
    }
    return true
  }

  /// Stops the process as well as future login launches, including when the
  /// disk is full and the settings write could not persist.
  @MainActor
  static func haltHelper() {
    NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == identifier }
      .forEach { _ = kill($0.processIdentifier, SIGTERM) }
    Task { try? await SMAppService.loginItem(identifier: identifier).unregister() }
  }
}

/// Settings → Coding → Session sync: this Mac's own sync. The helper writes
/// config.json and status.json; the card re-reads them every 5 seconds only
/// while its window is on screen, and decodes and redraws only when their bytes
/// changed. The folder list is worked out on load and after Add Folder, not in
/// `body`.
struct SessionSyncCard: View {
  @Environment(AppStore.self) private var store
  @State private var config: SessionSyncConfig?
  @State private var configData: Data?
  @State private var hasReadConfig = false
  @State private var status: SessionSyncStatus?
  @State private var statusData: Data?
  @State private var sources: [SessionSyncSource] = []
  @State private var error: String?
  @State private var busy = false
  /// The one-time notice has not been answered for this person: nothing syncs yet.
  @State private var isAwaitingNotice = false

  var body: some View {
    WindowVisibilityReader { isVisible in
      card.task(id: isVisible) {
        // Sign-in turns sync on without this card open; a hidden window needs no answer.
        guard isVisible else { return }
        while !Task.isCancelled {
          refresh()
          try? await Task.sleep(for: .seconds(5))
        }
      }
    }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.x2) {
      SectionLabel("Session sync")
      if !SessionSyncAgent.isBuilt {
        Text(SessionSyncCard.unavailableLine)
          .font(Tokens.Typography.caption)
          .foregroundStyle(Tokens.Palette.inkSecondary)
          .padding(Tokens.Space.x4)
          .frame(maxWidth: .infinity, alignment: .leading)
          .hqCard()
      } else {
      VStack(alignment: .leading, spacing: Tokens.Space.x3) {
        Text(
          isPaused
            ? "Session sync is paused."
            : isWaiting
              ? "Session sync is waiting for your answer."
              : "Your Claude Code and Codex conversations sync to \(SessionSyncNotice.host(HQConfig.baseURLString))."
        )
        .font(Tokens.Typography.row)
        Text(
          isWaiting
            ? "The app asks before it uploads your coding conversations, and nothing is uploaded until you answer."
            : "Conversations from the last 7 days, and new ones, are uploaded as text. "
              + "Everyone on this server and the person who runs it can read them. "
              + "Secrets are hidden on a best-effort basis, so keep them out of prompts. "
              + "Sync runs in the background, even when the app is closed."
        )
        .font(Tokens.Typography.caption)
        .foregroundStyle(Tokens.Palette.inkSecondary)
        HStack {
          if isWaiting {
            // Never disabled by `busy`: a Turn On waiting on a lost panel
            // is exactly when the person needs this.
            Button("Show notice") { resume() }.disabled(store.session == nil)
          } else if isRunning {
            Button("Pause") { pause() }.disabled(busy || store.session == nil)
          } else {
            Button(isPaused ? "Resume" : "Turn On") { resume() }
              .disabled(busy || store.session == nil)
          }
          Button("Add Claude Folder…") { addClaudeFolder() }
            .disabled(busy || store.session == nil)
        }
        if let status, isRunning {
          let checked = status.checkedAt.formatted(date: .omitted, time: .shortened)
          Text("\(status.synced) synced · \(status.pending) waiting · checked \(checked)")
          .font(Tokens.Typography.caption)
          ForEach(Array(status.errors.prefix(5).enumerated()), id: \.offset) { _, message in
            Text(message).font(Tokens.Typography.caption).foregroundStyle(Tokens.Palette.danger)
          }
        }
        if let error {
          Text(error).font(Tokens.Typography.caption).foregroundStyle(Tokens.Palette.danger)
        }
        if !sources.isEmpty {
          DisclosureGroup("Folders (\(sources.count))") {
            VStack(alignment: .leading, spacing: Tokens.Space.x1) {
              ForEach(sources, id: \.path) { source in
                Text("\(Self.name(source)) · \(source.path)")
                  .font(Tokens.Typography.caption).foregroundStyle(Tokens.Palette.inkSecondary)
                  .textSelection(.enabled)
              }
            }
            .padding(.top, Tokens.Space.x1)
          }
          .font(Tokens.Typography.caption)
        }
      }
      .padding(Tokens.Space.x4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .hqCard()
      }
    }
  }

  /// The one line a build without a team shows instead of the controls.
  static let unavailableLine =
    "Session sync is off in this build: it needs the app signed with your Apple team "
    + "(HQ_SIGNING_MODE=team). See docs/session-sync.md."

  /// Re-reads the helper's two files; state changes only when their bytes did.

  private func refresh() {
    if !busy { readConfig() }
    refreshNotice()
    let data = try? Data(contentsOf: SessionSyncConfig.statusFile)
    if data != statusData {
      statusData = data
      status = data.flatMap { try? Self.decoder.decode(SessionSyncStatus.self, from: $0) }
    }
  }

  private static let decoder = JSONDecoder()

  private func readConfig() {
    let data = try? Data(contentsOf: SessionSyncConfig.file)
    guard data != configData || !hasReadConfig else { return }
    hasReadConfig = true
    configData = data
    show(data.flatMap { try? Self.decoder.decode(SessionSyncConfig.self, from: $0) })
  }

  /// The config shown, and the folders it syncs: the one place either changes.
  private func show(_ next: SessionSyncConfig?) {
    config = next
    sources = next?.effectiveSources() ?? SessionSyncConfig.detectedSources()
  }

  private func folder(_ title: String) -> URL? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.showsHiddenFiles = true
    return panel.runModal() == .OK ? panel.url : nil
  }
  private var isPaused: Bool { config?.paused == true }
  private var isWaiting: Bool { isAwaitingNotice && !isPaused }
  /// Syncing now: on, and its notice answered (the helper idles without it).
  private var isRunning: Bool { config?.isSyncing == true && !isWaiting }
  private func awaitsNotice(_ session: StoredSession) -> Bool {
    SessionSyncNotice.shouldShow(
      defaults: .standard, personID: session.person.id, baseURL: HQConfig.baseURLString)
  }
  private func refreshNotice() {
    let next = store.session.map(awaitsNotice) ?? false
    if next != isAwaitingNotice { isAwaitingNotice = next }
  }
  private static func name(_ source: SessionSyncSource) -> String {
    source.provider == "codex" ? "Codex" : "Claude"
  }
  private func pause() {
    SessionSyncAgent.pause()
    readConfig()
  }
  private func resume() {
    guard let session = store.session else { return }
    busy = true
    error = nil
    Task { @MainActor in
      defer { busy = false }
      let outcome = await SessionSyncAgent.resume(
        session, isCurrent: { store.session?.deviceId == session.deviceId })
      config = SessionSyncConfig.load()
      refreshNotice()
      if outcome == .failed || outcome == .needsApproval {
        error =
          "Could not start sync. Check your sign-in and allow HQ in System Settings → General → Login Items & Extensions."
      }
    }
  }
  private func addClaudeFolder() {
    guard let session = store.session,
      var next = config
        ?? SessionSyncConfig.resuming(
          nil, personID: session.person.id, baseURL: HQConfig.baseURLString),
      let url = folder("Choose a Claude config folder containing projects")
    else { return }
    guard FileManager.default.fileExists(atPath: url.appendingPathComponent("projects").path) else {
      error = "Choose the Claude data folder that contains a projects folder."
      return
    }
    let path = url.resolvingSymlinksInPath().path
    if !next.sources.contains(where: { $0.path == path }) {
      next.sources.append(SessionSyncSource(provider: "claude", path: path))
    }
    if next.paused == true || awaitsNotice(session) {
      // Paused stays paused, and an unanswered notice keeps sync off: the
      // folder is remembered for Resume or for the answer.
      if config == nil { next.enabled = false }
      try? next.save()
      configData = try? Data(contentsOf: SessionSyncConfig.file)
      show(next)
      return
    }
    enable(next, session: session)
  }
  private func enable(_ next: SessionSyncConfig, session: StoredSession) {
    busy = true
    error = nil
    Task { @MainActor in
      defer { busy = false }
      do {
        try await SessionSyncAgent.configure(session, base: next.baseURL)
        guard store.session?.deviceId == session.deviceId,
          HQConfig.baseURLString == next.baseURL
        else { return }
        try next.save()
        configData = try? Data(contentsOf: SessionSyncConfig.file)
        show(next)
        try await SessionSyncAgent.start()
      } catch {
        self.error =
          "Could not start sync. Check your sign-in and allow HQ in System Settings → General → Login Items & Extensions."
      }
    }
  }
}

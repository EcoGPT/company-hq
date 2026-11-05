import Foundation

/// What this helper process has verified against the server: transcripts (session
/// path → sha256). Lives with the collector loop, reset on a scope change, never
/// written to disk: a restarted helper verifies the server again.
final class SyncVerification {
  var transcripts: [String: String] = [:]
  /// Past this many entries a map is cleared: it costs one re-verify per entry.
  static let limit = 8192
  func transport(
    config: SessionSyncConfig, token: String,
    settings: URLSessionConfiguration = .ephemeral, scopeCheck: (() -> Bool)? = nil
  ) throws -> SyncTransport {
    try SyncTransport(
      config: config, token: token, settings: settings, scopeCheck: scopeCheck,
      verification: self)
  }
}

final class SyncTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let config: SessionSyncConfig
  let token: String
  private let settings: URLSessionConfiguration
  private let scopeCheck: () -> Bool
  private let timeout: TimeInterval
  private let verification: SyncVerification
  private lazy var session: URLSession = {
    settings.timeoutIntervalForRequest = timeout
    settings.timeoutIntervalForResource = timeout * 2
    return URLSession(configuration: settings, delegate: self, delegateQueue: nil)
  }()
  init(
    config: SessionSyncConfig, token: String,
    settings: URLSessionConfiguration = .ephemeral, scopeCheck: (() -> Bool)? = nil,
    timeout: TimeInterval = 30, verification: SyncVerification = SyncVerification()
  ) throws {
    guard Self.allowed(config.baseURL) else { throw SyncFailure.destination }
    self.config = config
    self.token = token
    self.settings = settings
    self.timeout = timeout
    self.verification = verification
    self.scopeCheck =
      scopeCheck ?? {
        guard let live = SessionSyncConfig.load() else { return false }
        return live.isSyncing && live.personID == config.personID && live.baseURL == config.baseURL
          && live.sources == config.sources
      }
  }

  /// The server addresses the helper will send a conversation to: `https://` anywhere,
  /// or plain `http://` on this Mac only (`localhost`, `127.0.0.1`, `::1`). No sign-in
  /// details, query or fragment in the address, so it is exactly where the app signed in.
  static func allowed(_ base: String) -> Bool {
    guard let url = URLComponents(string: base), let scheme = url.scheme,
      let host = url.host?.lowercased().trimmingCharacters(in: ["[", "]"]), !host.isEmpty,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      !url.path.hasSuffix("/")
    else { return false }
    switch scheme {
    case "https": return true
    case "http": return ["127.0.0.1", "localhost", "::1"].contains(host)
    default: return false
    }
  }

  /// Never follows a redirect: the bearer goes only to the address the app signed in to.
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
  func close() { session.invalidateAndCancel() }

  /// One request in flight: its body so far and who waits for it.
  private final class Load {
    let continuation: CheckedContinuation<(Data, URLResponse), Error>
    var data = Data()
    var oversized = false
    init(_ continuation: CheckedContinuation<(Data, URLResponse), Error>) { self.continuation = continuation }
  }
  private let loadsLock = NSLock()
  private var loads: [Int: Load] = [:]
  private func load(_ task: URLSessionTask) -> Load? { loadsLock.withLock { loads[task.taskIdentifier] } }

  /// `data(for:)` holds the whole body before its size is known; this data task refuses a
  /// declared length over the cap before the body and stops an undeclared one once it passes.
  private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let task = session.dataTask(with: request)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        loadsLock.withLock { loads[task.taskIdentifier] = Load(continuation) }
        task.resume()
      }
    } onCancel: { task.cancel() }
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    // Only a 200 body is ever read; other statuses are judged by their code.
    let refuse =
      (response as? HTTPURLResponse)?.statusCode == 200
      && response.expectedContentLength > Int64(SessionCollector.maxBytes)
    if refuse { load(dataTask)?.oversized = true }
    completionHandler(refuse ? .cancel : .allow)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard (dataTask.response as? HTTPURLResponse)?.statusCode == 200, let load = load(dataTask) else { return }
    load.data.append(data)
    if load.data.count > SessionCollector.maxBytes {
      load.oversized = true
      dataTask.cancel()
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let load = loadsLock.withLock({ loads.removeValue(forKey: task.taskIdentifier) }) else { return }
    if load.oversized {
      load.continuation.resume(throwing: SyncFailure.oversized)
    } else if let error {
      load.continuation.resume(throwing: error)
    } else if let response = task.response {
      load.continuation.resume(returning: (load.data, response))
    } else {
      load.continuation.resume(throwing: SyncFailure.receipt)
    }
  }
  func scopeIsCurrent() -> Bool { scopeCheck() }

  func request(_ method: String, _ path: String, body: Any? = nil, missing: Bool = false)
    async throws -> [String: Any]?
  {
    guard let url = URL(string: config.baseURL + path) else { throw SyncFailure.destination }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("hq-session-sync/0.1", forHTTPHeaderField: "User-Agent")
    if let body { request.httpBody = try syncJSON(body) }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await fetch(request)
    } catch let error as URLError where error.code != .cancelled {
      throw SyncTransportError.network(error.code)
    }
    guard let response = response as? HTTPURLResponse else { throw SyncFailure.receipt }
    if response.statusCode == 404 && missing { return nil }
    guard response.statusCode == 200 else { throw SyncTransportError.http(response.statusCode) }
    guard data.count <= SessionCollector.maxBytes else { throw SyncFailure.oversized }
    guard let json = try autoreleasepool(invoking: { try JSONSerialization.jsonObject(with: data) }) as? [String: Any]
    else { throw SyncFailure.receipt }
    return json
  }

  /// The server stored exactly what was sent: it says so, and its hash is the one
  /// computed here. Then the upload needs no read back.
  private static func storedAsSent(_ reply: [String: Any]?, sha256: Any?, hash: String) -> Bool {
    reply?["stored_verbatim"] as? Bool == true && sha256 as? String == hash
  }

  private let attemptLock = NSLock()
  private var attempts: [String: String] = [:]

  /// The acknowledgement (hash and activity time) of the snapshot the last `sync` of `key`
  /// built for upload, whether or not the server took it; nil if it got no further than asking.
  func attempted(_ key: String) -> String? { attemptLock.withLock { attempts[key] } }

  func sync(_ candidate: SyncCandidate, acknowledged: String? = nil) async throws -> String {
    attemptLock.withLock { attempts[candidate.key] = nil }
    // Only verified receipts enter this in-memory cache. Re-read local
    // text every pass (streaming items can change without index mtimes).
    // A restart verifies the server again; an outage never advances a checkpoint.
    // Unchanged JSONL transcripts cost a stat here and unchanged paginated Codex
    // threads one marker read: the collector reuses the finished snapshot and
    // its acknowledgement (for JSONL, after folding only appended records).
    // A chat idle long enough is parked: a stat of each file stands in for its fold.
    let path = "/v1/agent-sessions/" + candidate.key
    if let acknowledged {
      if SessionCollector.parkedAcknowledgement(candidate, credential: token) == acknowledged {
        return acknowledged
      }
      let local = try SessionCollector.snapshot(candidate, credential: token)
      if try acknowledgement(local, key: candidate.key) == acknowledged {
        park(candidate, acknowledgement: acknowledged)
        return acknowledged
      }
    }
    let found = try await request("GET", path, missing: true)
    // No such session on the server: nothing verified for it still holds.
    if found == nil { verification.transcripts[path] = nil }
    var current = found?["session"] as? [String: Any]
    // Un-archived locally: restore it on the server before syncing as usual.
    if let archived = current?["archived_at"], !(archived is NSNull) {
      guard scopeCheck() else { throw SyncFailure.scope }
      current =
        try await request("PUT", path + "/archive", body: ["archived": false], missing: true)?["session"]
        as? [String: Any] ?? current
    }
    return try await upload(candidate, path: path, current: current)
  }

  /// One upload against `current`, the server's session as just read. The whole
  /// snapshot goes only when its text differs; a newer activity time or file list
  /// alone goes to the small activity route.
  private func upload(_ candidate: SyncCandidate, path: String, current: [String: Any]?)
    async throws -> String
  {
    let snapshot = try SessionCollector.snapshot(candidate, credential: token)
    let hash = try snapshot.hash
    let sent = try acknowledgement(snapshot, key: candidate.key)
    attemptLock.withLock { attempts[candidate.key] = sent }
    var receipt = current
    var stored = false
    let activityChanged = (snapshot.activityAt ?? 0) > (current?["activity_at"] as? Double ?? 0)
    let filesChanged = (current?["files_touched"] as? [String] ?? []) != snapshot.filesTouched
    let textChanged = current?["sha256"] as? String != hash
    if textChanged || activityChanged || filesChanged {
      // Recheck the one-time scope after reading source files and after
      // network awaits: sign-out/disable must prevent new uploads.
      guard scopeCheck() else { throw SyncFailure.scope }
      if !textChanged {
        var body: [String: Any] = ["sha256": hash, "files_touched": snapshot.filesTouched]
        if let activityAt = snapshot.activityAt { body["activity_at"] = activityAt }
        receipt = try await request("PUT", path + "/activity", body: body)?["session"] as? [String: Any]
      } else {
        var body: [String: Any] = [
          "base_revision": current?["revision"] ?? 0, "snapshot": snapshot.json,
          "files_touched": snapshot.filesTouched,
        ]
        if let activityAt = snapshot.activityAt { body["activity_at"] = activityAt }
        let reply = try await request("PUT", path, body: body)
        receipt = reply?["session"] as? [String: Any]
        stored = Self.storedAsSent(reply, sha256: receipt?["sha256"], hash: hash)
      }
    }
    guard receipt?["sha256"] as? String == hash,
      receipt?["message_count"] as? Int == snapshot.messages.count
    else { throw SyncFailure.receipt }
    // The receipt above is checked every pass. Content the server already held under a
    // sha this process read back is not downloaded again; content just uploaded is,
    // unless its receipt shows the server stored it as sent.
    if textChanged || verification.transcripts[path] != hash {
      if !stored {
        guard let downloaded = try await request("GET", path + "/transcript"),
          autoreleasepool(invoking: { NSDictionary(dictionary: downloaded).isEqual(to: snapshot.json) })
        else { throw SyncFailure.receipt }
      }
      if verification.transcripts.count >= SyncVerification.limit { verification.transcripts = [:] }
      verification.transcripts[path] = hash
    }
    // Parked now, not a pass later, so a restarted helper's first pass holds only
    // the chats still changing, not every chat it has folded so far.
    let acknowledged = try acknowledgement(snapshot, key: candidate.key)
    park(candidate, acknowledgement: acknowledged)
    return acknowledged
  }

  /// Parks an idle chat (`SessionCollector.park`).
  private func park(_ candidate: SyncCandidate, acknowledgement: String) {
    _ = SessionCollector.park(candidate, credential: token, acknowledgement: acknowledgement)
  }

  /// Archived locally: hide it on the server, never upload. Unknown sessions need nothing.
  func archive(_ candidate: SyncCandidate) async throws {
    let path = "/v1/agent-sessions/" + candidate.key
    guard let current = try await request("GET", path, missing: true)?["session"] as? [String: Any],
      current["archived_at"] is NSNull
    else { return }
    guard scopeCheck() else { throw SyncFailure.scope }
    _ = try await request("PUT", path + "/archive", body: ["archived": true], missing: true)
  }

  func acknowledgement(_ snapshot: SyncSnapshot, key: String) throws -> String {
    if let revision = snapshot.revision, let known = Self.acknowledgements.value(key, revision: revision) {
      return known
    }
    #if DEBUG
      Self.acknowledgements.hashed()
    #endif
    let value = try autoreleasepool { try snapshot.hash + ":" + String(snapshot.activityAt ?? 0) }
    if let revision = snapshot.revision { Self.acknowledgements.set(key, revision: revision, value) }
    return value
  }

  /// Each candidate's latest acknowledgement, shared by every pass's transport.
  private static let acknowledgements = AcknowledgementMemo()
  #if DEBUG
    /// Acknowledgements computed rather than remembered, for tests.
    static var acknowledgementHashes: Int { acknowledgements.hashes }
  #endif
}

/// One entry per candidate, so a pass over more chats than any fixed capacity
/// still finds every unchanged one. A new revision replaces the candidate's entry;
/// a chat unused for longer than the sync window is dropped by an hourly sweep.
final class AcknowledgementMemo: @unchecked Sendable {
  private struct Entry {
    var revision: String
    var ack: String
    var used: Date
  }
  private let lock = NSLock()
  private var values: [String: Entry] = [:]
  private var swept = Date()
  func value(_ key: String, revision: String, now: Date = Date()) -> String? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = values[key], entry.revision == revision else { return nil }
    values[key]?.used = now
    return entry.ack
  }
  func set(_ key: String, revision: String, _ ack: String, now: Date = Date()) {
    lock.lock()
    defer { lock.unlock() }
    values[key] = Entry(revision: revision, ack: ack, used: now)
    guard now.timeIntervalSince(swept) >= 3600 else { return }
    swept = now
    let stale = now.addingTimeInterval(-SessionCollector.activeWindow)
    values = values.filter { $0.value.used >= stale }
  }
  #if DEBUG
    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return values.count
    }
    private var hashCount = 0
    var hashes: Int {
      lock.lock()
      defer { lock.unlock() }
      return hashCount
    }
    func hashed() {
      lock.lock()
      defer { lock.unlock() }
      hashCount += 1
    }
  #endif
}

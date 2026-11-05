import Foundation

/// Conversations the server refused. A refusal is about the conversation's content (too big,
/// over a quota, a field it will not take), so sending the same bytes again every 15 seconds
/// cannot succeed. A refused conversation is held until its content changes, and tried once
/// more after an hour in case the server's limits or clock changed.
struct RefusalMemo {
  struct Entry: Equatable {
    var fingerprint: String
    var reason: String
    var retryAt: Date
  }

  static let backoff: TimeInterval = 3600
  private(set) var entries: [String: Entry] = [:]

  /// The errors that name this conversation as the problem: the server's 400 (a field it
  /// will not take) and 413 (`payload_too_large`, `quota_exceeded` or `session_limit`: over
  /// its size, the person's storage, or the 5,000-conversation cap). Everything else (sign-in, a
  /// busy server, a lost connection, a changed revision) is worth another try next pass.
  static func isRefusal(_ error: Error) -> Bool {
    if case SyncTransportError.http(let status) = error { return status == 400 || status == 413 }
    return false
  }

  /// True while `key` is held: refused, the hour not over, and its content unchanged.
  /// `fingerprint` is asked only when there is something held to compare with.
  func isHeld(_ key: String, now: Date = Date(), fingerprint: () -> String?) -> Bool {
    guard let entry = entries[key], now < entry.retryAt else { return false }
    return fingerprint() == entry.fingerprint
  }

  func reason(_ key: String) -> String? { entries[key]?.reason }

  mutating func refuse(_ key: String, fingerprint: String?, reason: String, now: Date = Date()) {
    guard let fingerprint else { return }
    entries[key] = Entry(fingerprint: fingerprint, reason: reason, retryAt: now.addingTimeInterval(Self.backoff))
  }

  mutating func clear(_ key: String) { entries[key] = nil }

  /// Drops what is no longer a candidate (it left the window or was deleted).
  mutating func keep(_ keys: Set<String>) {
    entries = entries.filter { keys.contains($0.key) }
  }
}

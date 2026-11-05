import Foundation
import LocalAuthentication
import Security

/// The sign-in the app hands the helper: one Keychain item the helper owns, named
/// from the app's bundle id and keyed by server and person, so it can only be
/// read back for the server it was saved for.
///
/// The Keychain ties an item to the code that made it. A build signed with a team keeps
/// the same identity across updates; an ad-hoc build (`HQ_SIGNING_MODE=local`) has a new
/// identity each time it is built, so an item from an earlier build can no longer be read
/// without a prompt. The helper cannot show one: it stops waiting after a few seconds and
/// reports that the sign-in is unavailable. That is why session sync is built only with a
/// team (`HQ_SESSION_SYNC`, docs/session-sync.md).
enum SyncCredential {
  static var service: String { SessionSyncIdentity.helperBundleID }
  static func query(_ config: SessionSyncConfig) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: config.baseURL + "/" + config.personID,
    ]
  }
  /// Never prompts: an item this build may not read comes back nil.
  private static func quiet(_ query: [String: Any]) -> [String: Any] {
    let context = LAContext()
    context.interactionNotAllowed = true
    return query.merging([kSecUseAuthenticationContext as String: context]) { _, new in new }
  }
  /// The saved sign-in, or nil when there is none, it is not readable by this build, or the
  /// Keychain does not answer within `timeout` (a read that waits on a prompt can wait
  /// forever). One read at a time: while a stuck one is outstanding the next returns nil.
  /// Waits without holding a thread of the concurrency pool: the read runs on a dispatch
  /// queue and a timer answers nil if it has not finished.
  static func load(_ config: SessionSyncConfig, timeout: TimeInterval = 5) async -> String? {
    guard reading.begin() else { return nil }
    return await withCheckedContinuation { continuation in
      let answer = OneShot(continuation)
      DispatchQueue.global().async {
        let value = read(config)
        reading.end()
        answer.resume(value)
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { answer.resume(nil) }
    }
  }

  /// Resumes a continuation once: the first of the read and the timer wins.
  final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    func resume(_ value: Value) {
      let waiting = lock.withLock { () -> CheckedContinuation<Value, Never>? in
        defer { continuation = nil }
        return continuation
      }
      waiting?.resume(returning: value)
    }
  }

  private final class Flight: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    func begin() -> Bool { lock.withLock { busy ? false : { busy = true; return true }() } }
    func end() { lock.withLock { busy = false } }
  }
  private static let reading = Flight()

  private static func read(_ config: SessionSyncConfig) -> String? {
    var request = quiet(query(config))
    request[kSecReturnData as String] = true
    var result: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
  /// The accounts of this helper's items that are not `keeping`'s: another person's or
  /// another server's sign-in, which the helper no longer needs.
  static func staleAccounts(_ accounts: [String], keeping config: SessionSyncConfig?) -> [String] {
    let keep = config.flatMap { query($0)[kSecAttrAccount as String] as? String }
    return accounts.filter { $0 != keep }
  }

  /// Deletes every sign-in this helper holds, except `config`'s (none kept when nil). Sign-out
  /// leaves no live bearer behind, and a second person or server on this Mac leaves none of
  /// the first's. Never prompts. False when something is left: an item this build may not
  /// delete (one made by a differently signed build), or a Keychain that did not answer.
  @discardableResult
  static func forget(keeping config: SessionSyncConfig?) -> Bool {
    var request = quiet([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service])
    request[kSecReturnAttributes as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: CFTypeRef?
    let found = SecItemCopyMatching(request as CFDictionary, &result)
    if found == errSecItemNotFound { return true }
    guard found == errSecSuccess, let items = result as? [[String: Any]] else { return false }
    var gone = true
    for account in staleAccounts(items.compactMap { $0[kSecAttrAccount as String] as? String }, keeping: config) {
      let item = quiet([
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ])
      let deleted = SecItemDelete(item as CFDictionary)
      if deleted != errSecSuccess && deleted != errSecItemNotFound { gone = false }
    }
    return gone
  }

  /// Updates the item, or replaces it when this build may not change the one an earlier
  /// build made. Never prompts.
  static func save(_ token: String, config: SessionSyncConfig) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: Data(token.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    var result = SecItemUpdate(quiet(query(config)) as CFDictionary, attributes as CFDictionary)
    if result != errSecSuccess && result != errSecItemNotFound {
      _ = SecItemDelete(quiet(query(config)) as CFDictionary)
      result = errSecItemNotFound
    }
    if result == errSecItemNotFound {
      result = SecItemAdd(query(config).merging(attributes) { _, new in new } as CFDictionary, nil)
    }
    guard result == errSecSuccess else { throw SyncFailure.source }
  }
}

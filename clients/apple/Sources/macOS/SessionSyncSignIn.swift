import Foundation

/// Runs one piece of work at a time, in the order it asked. Unlike an actor's own methods,
/// work that awaits does not let the next piece start in between.
actor SerialGate {
  private var busy = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
    if busy {
      await withCheckedContinuation { waiting.append($0) }
    } else {
      busy = true
    }
    defer {
      if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
    return try await work()
  }
}

/// The helper still has to delete the sign-in it holds after a sign-out. This marker (an empty
/// file, nothing secret) says so, and stays until the helper has done it, so a timeout, a
/// missing helper or a failed delete is retried at the next launch instead of forgotten.
/// A new sign-in clears it: it replaces what the old one left.
enum ForgetPending {
  static func file(in directory: URL = SessionSyncConfig.directory) -> URL {
    directory.appendingPathComponent("forget-pending")
  }

  static func isSet(in directory: URL = SessionSyncConfig.directory) -> Bool {
    FileManager.default.fileExists(atPath: file(in: directory).path)
  }

  static func set(in directory: URL = SessionSyncConfig.directory) {
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: file(in: directory).path, contents: Data(), attributes: [.posixPermissions: 0o600])
  }

  static func clear(in directory: URL = SessionSyncConfig.directory) {
    try? FileManager.default.removeItem(at: file(in: directory))
  }
}

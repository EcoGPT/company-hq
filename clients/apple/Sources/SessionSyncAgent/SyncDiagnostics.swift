import Foundation

/// What a failed request to the server was: the HTTP status it answered with, or the
/// URLError kind that stopped it from answering.
enum SyncTransportError: Error, Equatable {
  case http(Int)
  case network(URLError.Code)

  /// A plain reason for the status file and the person; no jargon, no response body.
  var reason: String {
    switch self {
    case .http(401): return "Sign-in expired or was revoked; open the app to sign in again"
    case .http(403): return "The server refused this Mac's sign-in"
    case .http(400): return "The server rejected this conversation's data"
    case .http(409): return "Conversation changed on the server; will retry"
    case .http(413): return "The server will not take this conversation (over its size, storage or conversation-count limit)"
    case .http(404): return "The server does not support session sync"
    case .http(let status) where (500..<600).contains(status):
      return "The server is having trouble (HTTP \(status)); will retry"
    case .http(let status): return "The server answered with an unexpected status (HTTP \(status)); will retry"
    case .network: return "Can't reach the server; will retry"
    }
  }
}

enum SyncReason {
  /// The reason to show for any error a sync step threw. An error that is not one
  /// of ours keeps the generic wording, since nothing more is known.
  static func of(_ error: Error, fallback: String = "Server unavailable; will retry") -> String {
    if let failure = error as? SyncFailure { return failure.rawValue }
    let transport = error as? SyncTransportError ?? (error as? URLError).map { .network($0.code) }
    // A cancelled request is a pause or a change of configuration, not a network fault.
    guard let transport, transport != .network(.cancelled) else { return fallback }
    return transport.reason
  }
}

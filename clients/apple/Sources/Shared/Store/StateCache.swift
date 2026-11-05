import CryptoKit
import Foundation

/// Last-known state persisted across launches so a cold open renders the
/// sidebar and transcripts instantly, before the network answers. The server
/// stays the authority: refresh and live sync overwrite everything here.
struct StateSnapshot: Codable {
    var schemaVersion: Int
    var people: [String: Person]
    var conversations: [Conversation]
    var messagesByConversation: [String: [Message]]
    var lastSeenMessageId: String?
    /// The Agents list, so a cold open draws the page before the hub answers.
    /// Optional, and read leniently: it is a wire type, and one a later build
    /// reads differently is dropped rather than costing the chats.
    var agentSessions: [CodingThread]?
}

extension StateSnapshot {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, people, conversations, messagesByConversation, lastSeenMessageId
        case agentSessions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        people = try c.decode([String: Person].self, forKey: .people)
        conversations = try c.decode([Conversation].self, forKey: .conversations)
        messagesByConversation = try c.decode([String: [Message]].self, forKey: .messagesByConversation)
        lastSeenMessageId = try c.decodeIfPresent(String.self, forKey: .lastSeenMessageId)
        agentSessions = try? c.decodeIfPresent([CodingThread].self, forKey: .agentSessions)
    }
}

/// One value, produced once on a background task and read from the main actor
/// without awaiting: `start()` takes the launch cache synchronously when the
/// decode has already finished, and waits a short bounded time when it has
/// not. Safe to call from any thread.
final class OneShotBox<Value>: @unchecked Sendable {
    enum Poll {
        case pending
        case landed(Value)
    }

    private let condition = NSCondition()
    private var state = Poll.pending

    /// Stores the value and wakes anyone waiting. Only the first call counts.
    func fill(_ value: Value) {
        condition.lock()
        defer { condition.unlock() }
        guard case .pending = state else { return }
        state = .landed(value)
        condition.broadcast()
    }

    /// The value if it is there, waiting up to `seconds` for it first.
    func poll(waitingUpTo seconds: TimeInterval = 0) -> Poll {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(seconds)
        while case .pending = state, seconds > 0, condition.wait(until: deadline) {}
        return state
    }
}

/// Writes the snapshot file. Encoding is deterministic (sorted keys), so the
/// encoded bytes can be hashed: a snapshot identical to the last one written
/// is not written again. A save that finishes late never replaces a newer one
/// (`sequence`), and every write is atomic. Safe to call from any thread.
final class StateCacheWriter: @unchecked Sendable {
    enum Outcome: Equatable {
        /// The file now holds this snapshot.
        case wrote
        /// The file already holds exactly this; nothing was written.
        case unchanged
        /// A newer snapshot was written first; this one was dropped.
        case stale
        /// The encode or the write failed; the file is as it was.
        case failed
    }

    private let url: URL
    private let lock = NSLock()
    private var lastDigest: Data?
    private var lastSequence: UInt64 = 0

    init(url: URL) {
        self.url = url
    }

    /// Remembers what the file on disk holds, so the first save after launch
    /// of an unchanged state is skipped too.
    func noteLoaded(_ data: Data) {
        let digest = Data(SHA256.hash(data: data))
        lock.lock()
        defer { lock.unlock() }
        if lastDigest == nil { lastDigest = digest }
    }

    @discardableResult
    func save(_ snapshot: StateSnapshot, sequence: UInt64 = 0) -> Outcome {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return .failed }
        let digest = Data(SHA256.hash(data: data))
        lock.lock()
        defer { lock.unlock() }
        if sequence != 0, sequence < lastSequence { return .stale }
        if digest == lastDigest {
            lastSequence = max(lastSequence, sequence)
            return .unchanged
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            return .failed
        }
        lastDigest = digest
        lastSequence = max(lastSequence, sequence)
        return .wrote
    }

    /// Removes the file. Saves still in flight from before (`sequence` below
    /// `atSequence`) are dropped when they finish, so a sign-out is not undone
    /// by a write that was already on its way.
    func clear(atSequence sequence: UInt64 = 0) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        lastDigest = nil
        lastSequence = sequence
    }
}

enum StateCache {
    static let schemaVersion = 2
    /// Trailing messages kept per conversation — enough to fill a viewport;
    /// scrolling up pages the rest from the server as usual.
    static let messagesKept = 80

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(HQIdentity.bundleID)/state-cache\(HQConfig.storeSuffix).json")
    }

    private static let writer = StateCacheWriter(url: fileURL)

    static func load() -> StateSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(StateSnapshot.self, from: data)
        else { return nil }
        writer.noteLoaded(data)
        return upgraded(snapshot)
    }

    /// A cache from another schema is dropped, never half-read.
    static func upgraded(_ snapshot: StateSnapshot) -> StateSnapshot? {
        snapshot.schemaVersion == schemaVersion ? snapshot : nil
    }

    @discardableResult
    static func save(_ snapshot: StateSnapshot, sequence: UInt64 = 0) -> StateCacheWriter.Outcome {
        writer.save(snapshot, sequence: sequence)
    }

    static func clear(atSequence sequence: UInt64 = 0) {
        writer.clear(atSequence: sequence)
    }
}

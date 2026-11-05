import Foundation

/// One agent session as `/v1/agent-sessions/active` and `/by-id` send it.
/// Foundation only, so the Live list's model runs in hostless tests.
struct CodingThread: Codable, Identifiable, Equatable {
    let sessionId: String
    let intent: String
    let state: String
    let lastSeenAt: Double
    let lastActivityAt: Double?
    let title: String?
    let ownerPersonId: String
    let ownerName: String
    let provider: String
    let tasks: [TaskReference]
    let projects: [ProjectReference]
    /// The session's git branch. Optional so an older or newer server both
    /// decode. (`repo` is the cwd's folder, often a random worktree name:
    /// never read.)
    let gitBranch: String?
    var id: String { sessionId }
    var activityDate: Date { Date(timeIntervalSince1970: (lastActivityAt ?? lastSeenAt) / 1000) }
    struct TaskReference: Codable, Identifiable, Equatable { let id: String; let ref: String; let title: String }
    struct ProjectReference: Codable, Identifiable, Equatable { let id: String; let name: String }
    enum CodingKeys: String, CodingKey {
        case intent, state, provider, tasks, projects, title
        case gitBranch = "git_branch"
        case lastActivityAt = "last_activity_at"
        case sessionId = "session_id", lastSeenAt = "last_seen_at", ownerPersonId = "owner_person_id", ownerName = "owner_name"
    }
}

/// A session's conversation as `GET /v1/agent-sessions/by-id/:id/transcript` sends it:
/// the text of the messages the person and the agent exchanged, nothing else.
struct CodingTranscript: Decodable, Equatable {
    let messages: [Entry]
    struct Entry: Decodable, Identifiable, Equatable {
        let id: String
        let role: String
        let text: String
        let timestamp: String?

        /// When the message was written, if the stamp is ISO 8601 (with or without fractions).
        var date: Date? {
            guard let timestamp else { return nil }
            return CodingTranscript.fractional.date(from: timestamp) ?? CodingTranscript.plain.date(from: timestamp)
        }
    }
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()
}

/// Where a thread's detail and conversation are read from.
enum CodingThreadRoutes {
    /// A thread's detail. The app adds `?open=1` once the server says `open_transcripts`;
    /// this server returns `session` to any member either way.
    static func detail(id: String, openTranscripts: Bool) -> String {
        "/v1/agent-sessions/by-id/\(id)" + (openTranscripts ? "?open=1" : "")
    }

    /// A thread's conversation. The server hides secret-looking strings from everyone
    /// but its owner, and answers only for a session the asker may open.
    static func transcript(id: String) -> String {
        "/v1/agent-sessions/by-id/\(id)/transcript"
    }
}

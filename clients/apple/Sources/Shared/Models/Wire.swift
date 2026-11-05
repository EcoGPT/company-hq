import Foundation
import os

// Mirrors the server's wire protocol (version 1). The wire evolves
// additively; unknown frame types decode to .unknown and are ignored.

/// A frame of a known type whose payload this build cannot read is dropped;
/// the drop is logged with its type (never its content) so a lost replay
/// shows in the same bundle-id sync log as the socket's own drops.
private let frameLog = Logger(subsystem: HQIdentity.logSubsystem, category: "sync")

struct Person: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: String
    let isAdmin: Bool
    /// The current profile picture's id; optional so cached state from older
    /// builds still decodes.
    let avatarId: String?
    /// When they were removed from the team. The row outlives the removal
    /// so history still names them; optional for the same reason as
    /// `avatarId`.
    let removedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, kind
        case isAdmin = "is_admin"
        case avatarId = "avatar_id"
        case removedAt = "removed_at"
    }

    init(id: String, name: String, kind: String, isAdmin: Bool, avatarId: String?, removedAt: String?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isAdmin = isAdmin
        self.avatarId = avatarId
        self.removedAt = removedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(String.self, forKey: .kind)
        isAdmin = try c.decode(Bool.self, forKey: .isAdmin)
        avatarId = try c.decodeIfPresent(String.self, forKey: .avatarId)
        removedAt = try c.decodeIfPresent(String.self, forKey: .removedAt)
    }

    /// Off the roster: they appear in history and nowhere new activity starts.
    var isRemoved: Bool { removedAt != nil }

    /// A machine credential that acts as itself. Not a teammate and not an
    /// agent, so it holds no roster seat.
    var isService: Bool { kind == "service" }

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }
}

struct Attachment: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let fileName: String
    let contentType: String
    let byteSize: Int
    let width: Int?
    let height: Int?

    var isImage: Bool { contentType.hasPrefix("image/") }

    var isMarkdown: Bool {
        contentType == "text/markdown" || fileName.lowercased().hasSuffix(".md")
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    enum CodingKeys: String, CodingKey {
        case id, width, height
        case fileName = "file_name"
        case contentType = "content_type"
        case byteSize = "byte_size"
    }
}

struct Reaction: Codable, Hashable, Sendable {
    let emoji: String
    let personIds: [String]

    enum CodingKeys: String, CodingKey {
        case emoji
        case personIds = "person_ids"
    }
}

/// One superseded version of an edited message, oldest first on the wire.
struct EditRevision: Codable, Hashable, Sendable {
    let content: String
    let editedAt: String

    enum CodingKeys: String, CodingKey {
        case content
        case editedAt = "edited_at"
    }
}

struct ReplyStub: Codable, Hashable, Sendable {
    let id: String
    let content: String
    let senderName: String

    enum CodingKeys: String, CodingKey {
        case id, content
        case senderName = "sender_name"
    }
}

struct Message: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let conversationId: String
    let senderPersonId: String
    let senderName: String
    let content: String
    let createdAt: String
    let editedAt: String?
    let deletedAt: String?
    let isHidden: Bool?
    let replyTo: ReplyStub?
    let reactions: [Reaction]
    let attachments: [Attachment]
    // Optional so frames from a server predating edit history still decode;
    // absent is not the same as empty here.
    // swiftlint:disable:next discouraged_optional_collection
    let editHistory: [EditRevision]?
    /// A group event ("member_added", "member_left", "conversation_renamed"),
    /// rendered as a centered transcript row; nil is an ordinary message.
    let kind: String?
    /// "mcp" when an external agent sent this as its person — the
    /// "via agent" chip. Optional for cached state and old frames.
    let via: String?

    init(
        id: String,
        conversationId: String,
        senderPersonId: String,
        senderName: String,
        content: String,
        createdAt: String,
        editedAt: String? = nil,
        deletedAt: String? = nil,
        isHidden: Bool? = nil,
        replyTo: ReplyStub? = nil,
        reactions: [Reaction] = [],
        attachments: [Attachment] = [],
        // swiftlint:disable:next discouraged_optional_collection
        editHistory: [EditRevision]? = nil,
        kind: String? = nil,
        via: String? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.senderPersonId = senderPersonId
        self.senderName = senderName
        self.content = content
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.deletedAt = deletedAt
        self.isHidden = isHidden
        self.replyTo = replyTo
        self.reactions = reactions
        self.attachments = attachments
        self.editHistory = editHistory
        self.kind = kind
        self.via = via
    }

    enum CodingKeys: String, CodingKey {
        case id, content, reactions, attachments, kind, via
        case conversationId = "conversation_id"
        case senderPersonId = "sender_person_id"
        case senderName = "sender_name"
        case createdAt = "created_at"
        case editedAt = "edited_at"
        case deletedAt = "deleted_at"
        case isHidden = "is_hidden"
        case replyTo = "reply_to"
        case editHistory = "edit_history"
    }

    var createdDate: Date { ISO8601.parse(createdAt) }
    var transcriptDate: Date { createdDate }
    var isDeleted: Bool { deletedAt != nil }
    var isEdited: Bool { editedAt != nil }
    var isPending: Bool { id.hasPrefix("pending-") }
    /// A centered group-event row. Work rows carry a kind too, but they are a
    /// bot's turn record in its own lane, not something that happened to the
    /// group.
    var isSystem: Bool { kind != nil && !isWork }
    var isWork: Bool { kind == "work" || kind == "agent_job" }
    var isAgentJob: Bool { kind == "agent_job" }

    /// A work row's first content line is its headline — "Working…" while the
    /// turn runs, "Worked for 3m 50s" once it lands — and every line after it
    /// is one step the bot took.
    var workHeadline: String { content.split(separator: "\n", omittingEmptySubsequences: false)
        .first.map(String.init) ?? ""
    }
    var workSteps: [String] {
        Array(content.split(separator: "\n", omittingEmptySubsequences: false).dropFirst())
            .map(String.init)
    }
    var isWorking: Bool {
        isWork && (workHeadline == "Working…" || workHeadline.contains(" queued · ")
            || workHeadline.contains(" working · "))
    }
    func agentJobHeadline(at date: Date) -> String {
        guard isAgentJob, isWorking else { return workHeadline }
        let seconds = max(1, Int(date.timeIntervalSince(createdDate).rounded()))
        let elapsed = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        return "\(workHeadline.split(separator: "·").first?.trimmingCharacters(in: .whitespaces) ?? workHeadline) · \(elapsed)"
    }
    var isViaAgent: Bool { via == "mcp" }
    var editRevisions: [EditRevision] { editHistory ?? [] }

    var previewText: String {
        if isDeleted { return "Message unsent" }
        // A work row's trail is for the transcript; the sidebar gets its
        // headline alone.
        if isWork { return workHeadline }
        if !content.isEmpty { return content }
        guard let first = attachments.first else { return "" }
        return attachments.count == 1 ? first.fileName : "\(attachments.count) attachments"
    }
}

struct ReadMark: Codable, Hashable, Sendable {
    let personId: String
    let lastReadMessageId: String

    enum CodingKeys: String, CodingKey {
        case personId = "person_id"
        case lastReadMessageId = "last_read_message_id"
    }
}

struct Conversation: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let kind: String
    let title: String?
    let memberIds: [String]
    let createdAt: String
    let lastMessage: Message?
    let unreadCount: Int
    let readMarks: [ReadMark]
    let roomSlug: String?
    /// The group photo's id; optional for cached state.
    let avatarId: String?

    init(
        id: String,
        kind: String,
        title: String?,
        memberIds: [String],
        createdAt: String,
        lastMessage: Message?,
        unreadCount: Int,
        readMarks: [ReadMark] = [],
        roomSlug: String? = nil,
        avatarId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.memberIds = memberIds
        self.createdAt = createdAt
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
        self.readMarks = readMarks
        self.roomSlug = roomSlug
        self.avatarId = avatarId
    }

    var isStandingRoom: Bool { roomSlug != nil }

    enum CodingKeys: String, CodingKey {
        case id, kind, title
        case memberIds = "member_ids"
        case createdAt = "created_at"
        case lastMessage = "last_message"
        case unreadCount = "unread_count"
        case readMarks = "read_marks"
        case roomSlug = "room_slug"
        case avatarId = "avatar_id"
    }
}

struct CallTrack: Codable, Hashable, Identifiable, Sendable {
    let trackName: String
    let sessionId: String
    let deviceId: String
    let personId: String
    let source: String
    let createdAt: String
    let endedAt: String?

    var id: String { trackName }

    enum CodingKeys: String, CodingKey {
        case source
        case trackName = "track_name"
        case sessionId = "session_id"
        case deviceId = "device_id"
        case personId = "person_id"
        case createdAt = "created_at"
        case endedAt = "ended_at"
    }
}

struct CallParticipant: Codable, Hashable, Identifiable, Sendable {
    let deviceId: String
    let personId: String
    let sessionId: String?
    let isMuted: Bool
    let isCameraOn: Bool
    let isScreenSharing: Bool
    let isHandRaised: Bool
    let joinedAt: String
    let leftAt: String?

    var id: String { deviceId }
    var isPresent: Bool { leftAt == nil }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case personId = "person_id"
        case sessionId = "session_id"
        case isMuted = "is_muted"
        case isCameraOn = "is_camera_on"
        case isScreenSharing = "is_screen_sharing"
        case isHandRaised = "is_hand_raised"
        case joinedAt = "joined_at"
        case leftAt = "left_at"
    }
}

struct Call: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let conversationId: String
    let kind: String
    let meetingId: String?
    let title: String?
    let startedByPersonId: String
    let startedAt: String
    let endedAt: String?
    let participants: [CallParticipant]
    let tracks: [CallTrack]

    var isLive: Bool { endedAt == nil }
    var presentParticipants: [CallParticipant] { participants.filter(\.isPresent) }
    var startedDate: Date { ISO8601.parse(startedAt) }
    var endedDate: Date? { endedAt.map { ISO8601.parse($0) } }

    var duration: TimeInterval {
        (endedDate ?? Date()).timeIntervalSince(startedDate)
    }

    func liveTracks(from source: String) -> [CallTrack] {
        tracks.filter { $0.source == source && $0.endedAt == nil }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, participants, tracks
        case conversationId = "conversation_id"
        case meetingId = "meeting_id"
        case startedByPersonId = "started_by_person_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

// What a finished call left behind: the summary the assistant wrote, the whole
// speaker-attributed transcript, and which microphones are on file. Fetched
// on demand — none of this rides the call frames.
struct CallRecord: Codable, Sendable {
    let call: Call
    let summary: String?
    let recapAt: String?
    let transcript: [TranscriptLine]
    let recordings: [CallRecording]
    let health: CallHealth?

    /// The call was processed and had nothing to write down, as opposed to
    /// never having been processed at all.
    var wasProcessed: Bool { recapAt != nil }
    var hasAudio: Bool { !recordings.isEmpty }

    enum CodingKeys: String, CodingKey {
        case call, summary, transcript, recordings, health
        case recapAt = "recap_at"
    }
}

/// The call's flight recorder, summed: all zeroes means it was clean.
struct CallHealth: Codable, Sendable {
    let joins: Int
    let rejoins: Int
    let sweeps: Int
    let socketLosses: Int
    let sfuFailures: Int
    let refusedTracks: Int
    let transcriptionFailures: Int
    let recordingFailures: Int
    let ringFailures: Int

    /// Every trouble `troubles` can name, so the Reliability section is shown
    /// exactly when there is something in it. `socketLosses` belongs here: it
    /// is half of the "dropout" count, and leaving it out hid a call whose
    /// only fault was that the hub dropped every socket at once.
    var isClean: Bool { troubles.isEmpty }

    /// Label + count for everything nonzero and worth a person's glance.
    var troubles: [(label: String, count: Int)] {
        [
            ("reconnect", rejoins), ("dropout", sweeps + socketLosses),
            ("media failure", sfuFailures + refusedTracks),
            ("transcription failure", transcriptionFailures),
            ("recording failure", recordingFailures), ("missed ring", ringFailures),
        ].filter { $0.1 > 0 }
    }

    enum CodingKeys: String, CodingKey {
        case joins, rejoins, sweeps
        case socketLosses = "socket_losses"
        case sfuFailures = "sfu_failures"
        case refusedTracks = "refused_tracks"
        case transcriptionFailures = "transcription_failures"
        case recordingFailures = "recording_failures"
        case ringFailures = "ring_failures"
    }
}

struct TranscriptLine: Codable, Hashable, Identifiable, Sendable {
    let personId: String
    let name: String
    let atMs: Double
    let text: String

    var id: String { "\(personId)-\(atMs)-\(text.hashValue)" }

    enum CodingKeys: String, CodingKey {
        case name, text
        case personId = "person_id"
        case atMs = "at_ms"
    }
}

struct CallRecording: Codable, Hashable, Identifiable, Sendable {
    let deviceId: String
    let personId: String
    let name: String
    let seconds: Int

    var id: String { deviceId }

    enum CodingKeys: String, CodingKey {
        case name, seconds
        case deviceId = "device_id"
        case personId = "person_id"
    }
}

// A call ringing right now. The frame carries the whole call so the ring can
// name who is calling and from where without waiting on a roster.
struct IncomingCall: Codable, Equatable, Identifiable, Sendable {
    let call: Call
    let callerName: String
    let conversationTitle: String?
    let expiresAt: String

    var id: String { call.id }
    var expiresDate: Date { ISO8601.parse(expiresAt) }
    /// "Bo" for a DM, "Bo · Engineering" for a group.
    var fromLine: String {
        conversationTitle.map { "\(callerName) · \($0)" } ?? callerName
    }

    enum CodingKeys: String, CodingKey {
        case call
        case callerName = "caller_name"
        case conversationTitle = "conversation_title"
        case expiresAt = "expires_at"
    }
}

// A created or scheduled meeting that hasn't finished yet; once its call ends
// the row disappears and the ended call is the record. A nil scheduledAt is an
// open room someone created but nobody has joined.
struct Meeting: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let scheduledAt: String?
    let createdByPersonId: String
    let createdAt: String
    /// The meeting's own thread. An occurrence of a series points at the
    /// SERIES' thread, which every occurrence shares.
    let conversationId: String?
    /// Who it is for. Everyone still sees every meeting; being invited is what
    /// gets you the thread, the reminder, and a place in your own Up next.
    let inviteePersonIds: [String]
    /// The cadence, already written out by the hub ("Weekly on Mon at 10:00").
    /// Nil for a one-off.
    let recurrence: String?
    /// The series this is one occurrence of. Canceling by this id ends the
    /// whole thing; canceling the meeting skips just this one.
    let seriesId: String?

    enum CodingKeys: String, CodingKey {
        case id, title, recurrence
        case scheduledAt = "scheduled_at"
        case createdByPersonId = "created_by_person_id"
        case createdAt = "created_at"
        case conversationId = "conversation_id"
        case inviteePersonIds = "invitee_person_ids"
        case seriesId = "series_id"
    }

    // Decoded leniently: a hub that predates v63 sends none of the new fields,
    // and an old meeting should still render rather than drop out of the list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        scheduledAt = try container.decodeIfPresent(String.self, forKey: .scheduledAt)
        createdByPersonId = try container.decode(String.self, forKey: .createdByPersonId)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
        inviteePersonIds = try container.decodeIfPresent([String].self, forKey: .inviteePersonIds) ?? []
        recurrence = try container.decodeIfPresent(String.self, forKey: .recurrence)
        seriesId = try container.decodeIfPresent(String.self, forKey: .seriesId)
    }

    var scheduledDate: Date? { scheduledAt.map { ISO8601.parse($0) } }
    var isRecurring: Bool { seriesId != nil }
}

/// A library folder; 'archive' system_slug marks the standing Archive.
struct Folder: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let parentFolderId: String?
    let systemSlug: String?
    let createdAt: String

    var isArchive: Bool { systemSlug == "archive" }

    enum CodingKeys: String, CodingKey {
        case id, name
        case parentFolderId = "parent_folder_id"
        case systemSlug = "system_slug"
        case createdAt = "created_at"
    }
}

/// A file as the Files surface lists it: an attachment plus where it lives.
struct HubFile: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let fileName: String
    let contentType: String
    let byteSize: Int
    let conversationId: String
    let conversationTitle: String?
    let uploaderName: String
    let createdAt: String
    let folderId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
        case contentType = "content_type"
        case byteSize = "byte_size"
        case conversationId = "conversation_id"
        case conversationTitle = "conversation_title"
        case uploaderName = "uploader_name"
        case createdAt = "created_at"
        case folderId = "folder_id"
    }
}

struct ShelfDocumentSummary: Codable, Hashable, Identifiable, Sendable {
    let slug: String
    let title: String
    let updatedAt: String
    let updatedByName: String
    let folderId: String?

    var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug, title
        case updatedAt = "updated_at"
        case updatedByName = "updated_by_name"
        case folderId = "folder_id"
    }
}

struct ShelfDocument: Codable, Hashable, Sendable {
    let slug: String
    let title: String
    let content: String
    let updatedAt: String
    let updatedByName: String

    enum CodingKeys: String, CodingKey {
        case slug, title, content
        case updatedAt = "updated_at"
        case updatedByName = "updated_by_name"
    }
}

/// The bundle of work a task belongs to: a block on the Tasks
/// surface, with an owner and one line on what done looks like.
struct Project: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let body: String?
    let ownerPersonId: String
    let ownerName: String
    let status: String
    let openTasks: Int
    let createdAt: String
    let closedAt: String?

    var tags: [String]? = nil
    var effectiveTags: [String] { tags ?? planningCategory.map { [$0] } ?? [] }
    var activityTitle: String { planningState == "Now" ? "Active" : planningState == "Backlog" ? "Paused" : "Maintained" }
    var totalTasks: Int? = nil
    var lastTaskResolvedAt: String? = nil
    var planningCategory: String? = nil
    var planningState: String? = nil
    var planningOrder: Double? = nil
    var dueAt: String? = nil
    var archivedAt: String? = nil
    /// "work" or "objective". Nil on a hub that does not send it, which reads
    /// as work.
    var kind: String? = nil
    var commentCount: Int? = nil
    /// The server's own marker on a project it keeps for itself. Not sent by every server.
    var systemKey: String? = nil

    var isActive: Bool { status != "done" && archivedAt == nil }
    /// An objective: hidden from every project list. Tasks still link to it
    /// through their project ids.
    var isObjective: Bool { kind == "objective" }
    /// A project the server keys itself: never a graph hub on the Agents canvas.
    var isSystem: Bool { systemKey != nil }
    // Backlog ideas have no assignment. Keep the stored roadmap owner so
    // returning a card to the roadmap does not lose its previous owner.
    var planningOwnerPersonId: String? { planningState == "Backlog" ? nil : ownerPersonId }

    enum CodingKeys: String, CodingKey {
        case id, name, body, status, tags
        case planningCategory = "planning_category"
        case planningState = "planning_state"
        case planningOrder = "planning_order"
        case dueAt = "due_at"
        case archivedAt = "archived_at"
        case ownerPersonId = "owner_person_id"
        case ownerName = "owner_name"
        case openTasks = "open_tasks"
        case totalTasks = "total_tasks"
        case lastTaskResolvedAt = "last_task_resolved_at"
        case createdAt = "created_at"
        case closedAt = "closed_at"
        case kind
        case commentCount = "comment_count"
        case systemKey = "system_key"
    }
}

struct TeamTask: Codable, Hashable, Identifiable, Sendable {
    let recurrence: TaskRecurrence?
    let nextTaskId: String?
    let id: String
    /// Monotonic, never reused: the task is `HQ-<number>`. Optional
    /// because an older hub or a cached snapshot has none.
    let number: Int?
    let title: String
    // The context an agent needs to start from the row alone.
    let body: String?
    let status: String
    let ownerPersonId: String
    let ownerName: String
    let dueAt: String?
    let originConversationId: String?
    let createdByPersonId: String
    let createdAt: String
    let resolvedByPersonId: String?
    let resolvedAt: String?
    let projectId: String?
    let projectIds: [String]?
    var associatedProjectIds: [String] { Array(Set((projectIds ?? []) + (projectId.map { [$0] } ?? []))) }
    /// The last time anyone moved it: status, owner, project, schedule.
    /// Optional because nothing decoded it before this build, so a cached
    /// task has none; `touchedDate` falls back to creation.
    let touchedAt: String?
    /// How many comments it has, for the row's count. Zero on an older hub.
    let commentCount: Int

    var dueDate: TaskDueDate? {
        dueAt.map { TaskDueDate(date: ISO8601.parse($0), timezone: recurrence?.timezone) }
    }

    /// Anything not done is live on the board — in_progress and blocked
    /// count as open, never as completed.
    var isOpen: Bool { status != "done" }

    var touchedDate: Date { ISO8601.parse(touchedAt ?? createdAt) }

    /// "HQ-<number>" — what a branch, a PR body and a teammate call it.
    var ref: String? { number.map { "HQ-\($0)" } }

    enum CodingKeys: String, CodingKey {
        case id, number, title, body, status, recurrence
        case nextTaskId = "next_task_id"
        case ownerPersonId = "owner_person_id"
        case ownerName = "owner_name"
        case dueAt = "due_at"
        case originConversationId = "origin_conversation_id"
        case createdByPersonId = "created_by_person_id"
        case createdAt = "created_at"
        case resolvedByPersonId = "resolved_by_person_id"
        case resolvedAt = "resolved_at"
        case projectId = "project_id"
        case projectIds = "project_ids"
        case touchedAt = "touched_at"
        case commentCount = "comment_count"
    }

    init(
        recurrence: TaskRecurrence? = nil,
        nextTaskId: String? = nil,
        id: String,
        number: Int? = nil,
        title: String,
        body: String? = nil,
        status: String,
        ownerPersonId: String,
        ownerName: String,
        dueAt: String? = nil,
        originConversationId: String? = nil,
        createdByPersonId: String,
        createdAt: String,
        resolvedByPersonId: String? = nil,
        resolvedAt: String? = nil,
        projectId: String? = nil,
        projectIds: [String]? = nil,
        touchedAt: String? = nil,
        commentCount: Int = 0
    ) {
        self.recurrence = recurrence
        self.nextTaskId = nextTaskId
        self.id = id
        self.number = number
        self.title = title
        self.body = body
        self.status = status
        self.ownerPersonId = ownerPersonId
        self.ownerName = ownerName
        self.dueAt = dueAt
        self.originConversationId = originConversationId
        self.createdByPersonId = createdByPersonId
        self.createdAt = createdAt
        self.resolvedByPersonId = resolvedByPersonId
        self.resolvedAt = resolvedAt
        self.projectId = projectId
        self.projectIds = projectIds
        self.touchedAt = touchedAt
        self.commentCount = commentCount
    }

    /// Hand-written for the same reason `Project`'s is: every field added
    /// since is additive, so a task out of a cached snapshot or an older hub
    /// decodes without them rather than failing outright.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recurrence = try container.decodeIfPresent(TaskRecurrence.self, forKey: .recurrence)
        nextTaskId = try container.decodeIfPresent(String.self, forKey: .nextTaskId)
        id = try container.decode(String.self, forKey: .id)
        number = try container.decodeIfPresent(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        status = try container.decode(String.self, forKey: .status)
        ownerPersonId = try container.decode(String.self, forKey: .ownerPersonId)
        ownerName = try container.decode(String.self, forKey: .ownerName)
        dueAt = try container.decodeIfPresent(String.self, forKey: .dueAt)
        originConversationId = try container.decodeIfPresent(String.self, forKey: .originConversationId)
        createdByPersonId = try container.decode(String.self, forKey: .createdByPersonId)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        resolvedByPersonId = try container.decodeIfPresent(String.self, forKey: .resolvedByPersonId)
        resolvedAt = try container.decodeIfPresent(String.self, forKey: .resolvedAt)
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
        projectIds = try container.decodeIfPresent([String].self, forKey: .projectIds)
        touchedAt = try container.decodeIfPresent(String.self, forKey: .touchedAt)
        // Additive fields: one this build cannot read costs that field,
        // never the task.
        commentCount = (try? container.decodeIfPresent(Int.self, forKey: .commentCount)) ?? 0
    }
}

/// A comment on a task or a project: progress, research, a handoff, or an
/// automated event line.
struct HQComment: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let authorName: String
    let authorPersonId: String
    let body: String
    let createdAt: String
    /// Nil when typed in an app; "mcp" when a session spoke as its person
    /// (the "via agent" chip).
    var via: String? = nil

    var isViaAgent: Bool { via == "mcp" }

    enum CodingKeys: String, CodingKey {
        case id, body, via
        case authorName = "author_name"
        case authorPersonId = "author_person_id"
        case createdAt = "created_at"
    }
}

/// One element of a list, decoded on its own and allowed to fail. Decoding
/// never throws out of here, so the array around it always finishes — a row the
/// hub shipped in a shape this build cannot read simply drops out.
private struct LossyElement<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

private extension KeyedDecodingContainer {
    /// `decodeIfPresent` for a list whose elements are each allowed to fail.
    func decodeLossyArray<Value: Decodable>(
        _ type: Value.Type, forKey key: Key
    ) throws -> [Value]? {
        try decodeIfPresent([LossyElement<Value>].self, forKey: key)?.compactMap(\.value)
    }
}

enum ServerFrame: Sendable {
    case hello(deviceId: String, personId: String, onlinePersonIds: [String])
    case message(Message)
    case messageUpdated(Message)
    case conversationUpdated(Conversation)
    case conversationRemoved(conversationId: String)
    /// A person changed shape (today: their avatar) — the whole person, re-stated.
    case personUpdated(Person)
    case presence(personId: String, isOnline: Bool)
    case typing(conversationId: String, personId: String, expiresAt: String)
    case botState(conversationId: String, personId: String, label: String?, expiresAt: String)
    case read(conversationId: String, personId: String, lastReadMessageId: String)
    case syncBatch([Message])
    case syncComplete(isPartial: Bool)
    case serverError(code: String)
    case callState(Call)
    case callEnded(callId: String, endedAt: String)
    /// Someone is calling a thread this person is in. It rings until
    /// expiresAt and then stops on its own.
    case callRing(IncomingCall)
    /// Stop ringing: answered here or on another Mac, declined, expired, or
    /// the caller gave up.
    case callRingEnded(callId: String)
    case meetings([Meeting])
    /// A meeting this person is invited to is about to start. A nudge, not a
    /// ring — meetings never ring.
    case meetingReminder(meeting: Meeting, minutesUntil: Int)
    case tasks([TeamTask])
    /// Messages left this thread for another — drop them here; the
    /// destination receives them as ordinary message frames.
    case messagesMoved(fromConversationId: String, messageIds: [String])
    case unknown

    // One decoder per frame type, keyed by the wire's `type`. A frame whose
    // payload does not decode is ignored rather than defaulted, and an
    // unrecognized type is simply absent from the table — which is exactly what
    // additive wire evolution needs from an older client.
    private static let decoders: [String: @Sendable (Decoder) -> Self?] = [
        "hello": { payload(HelloPayload.self, $0).map {
            .hello(deviceId: $0.deviceId, personId: $0.personId, onlinePersonIds: $0.onlinePersonIds)
        } },
        "message": { payload(MessagePayload.self, $0).map { .message($0.message) } },
        "message_updated": { payload(MessagePayload.self, $0).map { .messageUpdated($0.message) } },
        "conversation_updated": { payload(ConversationPayload.self, $0).map {
            .conversationUpdated($0.conversation)
        } },
        "conversation_removed": { payload(ConversationRemovedPayload.self, $0).map {
            .conversationRemoved(conversationId: $0.conversationId)
        } },
        "person_updated": { payload(PersonPayload.self, $0).map { .personUpdated($0.person) } },
        "presence": { payload(PresencePayload.self, $0).map {
            .presence(personId: $0.personId, isOnline: $0.isOnline)
        } },
        "typing": { payload(TypingPayload.self, $0).map {
            .typing(conversationId: $0.conversationId, personId: $0.personId, expiresAt: $0.expiresAt)
        } },
        "bot_state": { payload(BotStatePayload.self, $0).map {
            .botState(
                conversationId: $0.conversationId,
                personId: $0.personId,
                label: $0.label,
                expiresAt: $0.expiresAt
            )
        } },
        "read": { payload(ReadPayload.self, $0).map {
            .read(
                conversationId: $0.conversationId,
                personId: $0.personId,
                lastReadMessageId: $0.lastReadMessageId
            )
        } },
        "sync_batch": { payload(SyncBatchPayload.self, $0).map { .syncBatch($0.messages) } },
        "sync_complete": { payload(SyncCompletePayload.self, $0).map {
            .syncComplete(isPartial: $0.isPartial)
        } },
        "error": { payload(ErrorPayload.self, $0).map { .serverError(code: $0.code) } },
        "call_state": { payload(CallStatePayload.self, $0).map { .callState($0.call) } },
        "call_ended": { payload(CallEndedPayload.self, $0).map {
            .callEnded(callId: $0.callId, endedAt: $0.endedAt)
        } },
        "call_ring": { payload(IncomingCall.self, $0).map { .callRing($0) } },
        "call_ring_ended": { payload(CallRingEndedPayload.self, $0).map {
            .callRingEnded(callId: $0.callId)
        } },
        "meetings": { payload(MeetingsPayload.self, $0).map { .meetings($0.meetings) } },
        "meeting_reminder": {
            payload(MeetingReminderPayload.self, $0).map {
                .meetingReminder(meeting: $0.meeting, minutesUntil: $0.minutesUntil)
            }
        },
        "tasks": { payload(TasksPayload.self, $0).map { .tasks($0.tasks) } },
        "messages_moved": { payload(MessagesMovedPayload.self, $0).map {
            .messagesMoved(fromConversationId: $0.fromConversationId, messageIds: $0.messageIds)
        } },
    ]

    /// One parse per frame. The wrapper reads `type` from the top-level object
    /// and hands the same decoder to the payload struct, whose fields sit
    /// beside `type` — so the bytes are parsed once, not once for an envelope
    /// and again for the payload. Pure and nonisolated: the socket calls it
    /// from the URLSession callback, off the main actor.
    nonisolated static func decode(_ data: Data) -> Self {
        (try? JSONDecoder().decode(Wrapper.self, from: data))?.frame ?? .unknown
    }

    private static func payload<T: Decodable>(_ type: T.Type, _ decoder: Decoder) -> T? {
        try? T(from: decoder)
    }

    private struct Wrapper: Decodable {
        let frame: ServerFrame

        enum CodingKeys: String, CodingKey { case type }

        init(from decoder: Decoder) throws {
            let type = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .type)
            guard let decode = ServerFrame.decoders[type] else {
                frame = .unknown
                return
            }
            guard let decoded = decode(decoder) else {
                frameLog.warning("frame dropped: \(type, privacy: .public) payload did not decode")
                frame = .unknown
                return
            }
            frame = decoded
        }
    }

    private struct HelloPayload: Decodable {
        let deviceId: String
        let personId: String
        let onlinePersonIds: [String]

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case personId = "person_id"
            case onlinePersonIds = "online_person_ids"
        }
    }

    private struct MessagePayload: Decodable {
        let message: Message
    }

    private struct PersonPayload: Decodable {
        let person: Person
    }

    private struct ConversationPayload: Decodable {
        let conversation: Conversation
    }

    private struct ConversationRemovedPayload: Decodable {
        let conversationId: String

        enum CodingKeys: String, CodingKey {
            case conversationId = "conversation_id"
        }
    }

    private struct PresencePayload: Decodable {
        let personId: String
        let isOnline: Bool

        enum CodingKeys: String, CodingKey {
            case personId = "person_id"
            case isOnline = "is_online"
        }
    }

    private struct MessagesMovedPayload: Decodable {
        let fromConversationId: String
        let messageIds: [String]

        enum CodingKeys: String, CodingKey {
            case fromConversationId = "from_conversation_id"
            case messageIds = "message_ids"
        }
    }

    private struct BotStatePayload: Decodable {
        let conversationId: String
        let personId: String
        let label: String?
        let expiresAt: String

        enum CodingKeys: String, CodingKey {
            case label
            case conversationId = "conversation_id"
            case personId = "person_id"
            case expiresAt = "expires_at"
        }
    }

    private struct TypingPayload: Decodable {
        let conversationId: String
        let personId: String
        let expiresAt: String

        enum CodingKeys: String, CodingKey {
            case conversationId = "conversation_id"
            case personId = "person_id"
            case expiresAt = "expires_at"
        }
    }

    private struct ReadPayload: Decodable {
        let conversationId: String
        let personId: String
        let lastReadMessageId: String

        enum CodingKeys: String, CodingKey {
            case conversationId = "conversation_id"
            case personId = "person_id"
            case lastReadMessageId = "last_read_message_id"
        }
    }

    private struct SyncBatchPayload: Decodable {
        let messages: [Message]

        enum CodingKeys: String, CodingKey { case messages }

        // Element by element: one message in a shape this build cannot read
        // drops alone, not with the up to 100 replayed beside it.
        init(from decoder: Decoder) throws {
            messages = try decoder.container(keyedBy: CodingKeys.self)
                .decode([LossyElement<Message>].self, forKey: .messages).compactMap(\.value)
        }
    }

    private struct SyncCompletePayload: Decodable {
        let isPartial: Bool

        enum CodingKeys: String, CodingKey {
            case isPartial = "is_partial"
        }
    }

    private struct ErrorPayload: Decodable {
        let code: String
    }

    private struct CallStatePayload: Decodable {
        let call: Call
    }

    private struct CallRingEndedPayload: Decodable {
        let callId: String

        enum CodingKeys: String, CodingKey { case callId = "call_id" }
    }

    private struct CallEndedPayload: Decodable {
        let callId: String
        let endedAt: String

        enum CodingKeys: String, CodingKey {
            case callId = "call_id"
            case endedAt = "ended_at"
        }
    }

    private struct TasksPayload: Decodable { let tasks: [TeamTask] }

    private struct MeetingsPayload: Decodable {
        let meetings: [Meeting]
    }

    private struct MeetingReminderPayload: Decodable {
        let meeting: Meeting
        let minutesUntil: Int

        enum CodingKeys: String, CodingKey {
            case meeting
            case minutesUntil = "minutes_until"
        }
    }
}

/// Calendar days on the wire. The hub writes a day as midnight UTC
/// ("2026-10-06T00:00:00.000Z"); reading it back through the local time zone
/// moves it a day west of Greenwich, so days are read and written in UTC and
/// only the picker sees local time.
enum DayStamp {
    private static let utc = TimeZone(identifier: "UTC") ?? .current
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private static func components(_ iso: String) -> DateComponents? {
        let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    /// "Oct 6", read in UTC so the day the hub named is the day shown.
    static func label(_ iso: String) -> String {
        guard let components = components(iso),
              let date = utcCalendar.date(from: components) else { return iso }
        return date.formatted(
            Date.FormatStyle(calendar: utcCalendar, timeZone: utc).month(.abbreviated).day()
        )
    }
}

enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    // Parsed dates are memoized: ISO8601DateFormatter costs microseconds per
    // call, `createdDate` re-parses on every ask, and the transcript's layout
    // arithmetic asks for every row on every pass — the same few hundred
    // strings, hundreds of times a second while a chat animates. The lock,
    // not an actor, because callers are synchronous computed properties on
    // wire structs decoded from any thread.
    private static let cacheLock = NSLock()
    private static var cache: [String: Date] = [:]

    static func parse(_ value: String) -> Date {
        cacheLock.lock()
        if let known = cache[value] {
            cacheLock.unlock()
            return known
        }
        cacheLock.unlock()
        let parsed = fractional.date(from: value) ?? plain.date(from: value) ?? Date()
        cacheLock.lock()
        if cache.count > 8192 { cache.removeAll(keepingCapacity: true) }
        cache[value] = parsed
        cacheLock.unlock()
        return parsed
    }
}


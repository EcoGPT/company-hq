import CoreGraphics
import Foundation
import os

private struct ErrorBody: Codable {
    let error: String
}

struct APIError: Error, LocalizedError {
    let status: Int
    let code: String

    var errorDescription: String? {
        switch code {
        case "invalid_key": return "That access key isn't valid."
        case "person_name_required": return "Enter your name to finish enrolling."
        case "not_configured": return "The server isn't set up yet."
        case "unauthorized": return "This device's access was revoked."
        case "forbidden", "admin_only": return "Only an admin can change this."
        case "person_exists": return "They already have an account. Ask your server admin to run `bun hq invite <handle>`."
        case "last_admin": return "HQ needs at least one admin."
        case "invite_expired": return "This key has expired. Ask an admin for a new one."
        case "rate_limited": return "Too many tries. Wait a few minutes."
        case "quota_exceeded": return "You've used your storage on this server."
        case "too_many_uploads": return "Too many files waiting to send."
        case "payload_too_large", "file_too_large": return "That file is too large for this server."
        default: return "Request failed (\(code), HTTP \(status))."
        }
    }
}

#if DEBUG && (os(macOS) || targetEnvironment(simulator))
/// Every request a fixture run sends, counted where the client picks its
/// session (one pick per request), so a probe can say how many a screen asked for.
enum HubRequestCount {
    private static let count = OSAllocatedUnfairLock(initialState: 0)
    static var value: Int { count.withLock { $0 } }
    static func note() { count.withLock { $0 += 1 } }
}
#endif

// Thin typed REST client; every call carries the device bearer.
struct HQClient: Sendable {
    let bearer: String

    private static var transport: URLSession {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        if HQSimulatorFixture.isEnabled { HubRequestCount.note(); return HQFixtureProtocol.session }
        #endif
        return .shared
    }

    private static func session(for path: String) -> URLSession {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        if HQSimulatorFixture.isEnabled { HubRequestCount.note(); return HQFixtureProtocol.session }
        #endif
        return transport
    }

    struct EnrollResponse: Codable {
        let bearer: String
        let deviceId: String
        let person: Person

        enum CodingKeys: String, CodingKey {
            case bearer, person
            case deviceId = "device_id"
        }
    }

    static func enroll(key: String, personName: String?, deviceName: String) async throws -> EnrollResponse {
        var body: [String: String] = ["key": key, "device_name": deviceName]
        if let personName, !personName.isEmpty { body["person_name"] = personName }
        return try await Self.request(bearer: nil, method: "POST", path: "/v1/enroll", body: body)
    }

    func people() async throws -> [Person] {
        struct Envelope: Codable { let people: [Person] }
        let envelope: Envelope = try await Self.request(bearer: bearer, method: "GET", path: "/v1/people")
        return envelope.people
    }

    func conversations() async throws -> [Conversation] {
        struct Envelope: Codable { let conversations: [Conversation] }
        let envelope: Envelope = try await Self.request(bearer: bearer, method: "GET", path: "/v1/conversations")
        return envelope.conversations
    }

    func conversation(id: String) async throws -> Conversation {
        struct Envelope: Codable { let conversation: Conversation }
        let envelope: Envelope = try await Self.request(bearer: bearer, method: "GET", path: "/v1/conversations/\(id)")
        return envelope.conversation
    }

    func createDM(personId: String) async throws -> Conversation {
        struct Envelope: Codable { let conversation: Conversation }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/conversations",
            body: ["kind": "dm", "person_id": personId]
        )
        return envelope.conversation
    }

    func createGroup(title: String?, personIds: [String]) async throws -> Conversation {
        struct Body: Codable {
            let kind: String
            let title: String?
            let personIds: [String]
            enum CodingKeys: String, CodingKey {
                case kind, title
                case personIds = "person_ids"
            }
        }
        struct Envelope: Codable { let conversation: Conversation }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/conversations",
            body: Body(kind: "group", title: title, personIds: personIds)
        )
        return envelope.conversation
    }

    func messages(conversationId: String, before: String?, limit: Int = 50) async throws -> [Message] {
        struct Envelope: Codable { let messages: [Message] }
        var path = "/v1/conversations/\(conversationId)/messages?limit=\(limit)"
        if let before { path += "&before=\(before)" }
        let envelope: Envelope = try await Self.request(bearer: bearer, method: "GET", path: path)
        return envelope.messages
    }

    func send(
        conversationId: String,
        clientMsgId: String,
        content: String,
        replyToMessageId: String? = nil,
        attachmentIds: [String] = []
    ) async throws -> Message {
        struct Body: Codable {
            let clientMsgId: String
            let content: String
            let replyToMessageId: String?
            let attachmentIds: [String]
            enum CodingKeys: String, CodingKey {
                case content
                case clientMsgId = "client_msg_id"
                case replyToMessageId = "reply_to_message_id"
                case attachmentIds = "attachment_ids"
            }
        }
        struct Envelope: Codable { let message: Message }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/conversations/\(conversationId)/messages",
            body: Body(
                clientMsgId: clientMsgId, content: content,
                replyToMessageId: replyToMessageId, attachmentIds: attachmentIds
            )
        )
        return envelope.message
    }

    func react(messageId: String, emoji: String) async throws -> Message {
        struct Envelope: Codable { let message: Message }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/messages/\(messageId)/reactions",
            body: ["emoji": emoji]
        )
        return envelope.message
    }

    func edit(messageId: String, content: String) async throws -> Message {
        struct Envelope: Codable { let message: Message }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "PATCH", path: "/v1/messages/\(messageId)",
            body: ["content": content]
        )
        return envelope.message
    }

    func unsend(messageId: String) async throws -> Message {
        struct Envelope: Codable { let message: Message }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "DELETE", path: "/v1/messages/\(messageId)"
        )
        return envelope.message
    }

    func search(query: String) async throws -> [Message] {
        struct Envelope: Codable { let messages: [Message] }
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "GET", path: "/v1/search?q=\(escaped)"
        )
        return envelope.messages
    }

    func rename(conversationId: String, title: String?) async throws -> Conversation {
        struct Body: Codable { let title: String? }
        struct Envelope: Codable { let conversation: Conversation }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "PATCH", path: "/v1/conversations/\(conversationId)",
            body: Body(title: title)
        )
        return envelope.conversation
    }

    func addMembers(conversationId: String, personIds: [String]) async throws -> Conversation {
        struct Body: Codable {
            let personIds: [String]
            enum CodingKeys: String, CodingKey { case personIds = "person_ids" }
        }
        struct Envelope: Codable { let conversation: Conversation }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/conversations/\(conversationId)/members",
            body: Body(personIds: personIds)
        )
        return envelope.conversation
    }

    func leave(conversationId: String) async throws {
        struct Envelope: Codable { let ok: Bool }
        let _: Envelope = try await Self.request(
            bearer: bearer, method: "DELETE", path: "/v1/conversations/\(conversationId)/members/me"
        )
    }

    /// Delete = archive: the server freezes and hides the group.
    func deleteConversation(id: String) async throws {
        struct Envelope: Codable { let ok: Bool }
        let _: Envelope = try await Self.request(
            bearer: bearer, method: "DELETE", path: "/v1/conversations/\(id)"
        )
    }

    // Attachments go up as raw bytes with the name in a header — no multipart
    // parser on either end for what is always exactly one file.
    func upload(
        conversationId: String,
        data: Data,
        fileName: String,
        contentType: String,
        pixelSize: CGSize?
    ) async throws -> Attachment {
        guard let url = HQConfig.url(path: "/v1/conversations/\(conversationId)/attachments") else {
            throw APIError(status: 0, code: "bad_url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // Header values are ASCII on the wire — CFNetwork silently truncates
        // at the first character it can't carry, and macOS names every
        // screenshot and screen recording with U+202F before "AM"/"PM", so an
        // unencoded name loses its extension mid-flight. The hub decodes.
        request.setValue(Self.encodedFileName(fileName), forHTTPHeaderField: "x-hq-file-name")
        if let pixelSize {
            request.setValue(String(Int(pixelSize.width)), forHTTPHeaderField: "x-hq-image-width")
            request.setValue(String(Int(pixelSize.height)), forHTTPHeaderField: "x-hq-image-height")
        }
        let (responseData, response) = try await Self.transport.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            let body = try? JSONDecoder().decode(ErrorBody.self, from: responseData)
            throw APIError(status: status, code: body?.error ?? "unknown")
        }
        struct Envelope: Codable { let attachment: Attachment }
        return try JSONDecoder().decode(Envelope.self, from: responseData).attachment
    }

    // Printable ASCII minus '%', so any name round-trips decodeURIComponent.
    private static let fileNameHeaderAllowed = CharacterSet(
        charactersIn: UnicodeScalar(0x20) ... UnicodeScalar(0x7E)
    ).subtracting(CharacterSet(charactersIn: "%"))

    private static func encodedFileName(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: fileNameHeaderAllowed) ?? "file"
    }

    // Avatars: same raw-bytes shape as attachments. The path names the owner;
    // a change mints a new id server-side, so the returned model carries it.
    func setMyAvatar(data: Data, contentType: String) async throws -> Person {
        struct Envelope: Codable { let person: Person }
        let envelope: Envelope = try await Self.upload(
            bearer: bearer, method: "PUT", path: "/v1/me/avatar",
            data: data, contentType: contentType
        )
        return envelope.person
    }

    func clearMyAvatar() async throws -> Person {
        struct Envelope: Codable { let person: Person }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "DELETE", path: "/v1/me/avatar"
        )
        return envelope.person
    }

    func setConversationImage(
        conversationId: String, data: Data, contentType: String
    ) async throws -> Conversation {
        struct Envelope: Codable { let conversation: Conversation }
        let envelope: Envelope = try await Self.upload(
            bearer: bearer, method: "PUT", path: "/v1/conversations/\(conversationId)/image",
            data: data, contentType: contentType
        )
        return envelope.conversation
    }

    func clearConversationImage(conversationId: String) async throws -> Conversation {
        struct Envelope: Codable { let conversation: Conversation }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "DELETE", path: "/v1/conversations/\(conversationId)/image"
        )
        return envelope.conversation
    }

    func avatarData(kind: AvatarKind, ownerId: String, avatarId: String) async throws -> Data {
        guard let url = HQConfig.url(path: "/v1/avatars/\(kind.rawValue)/\(ownerId)/\(avatarId)") else {
            throw APIError(status: 0, code: "bad_url")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await Self.transport.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 { throw APIError(status: status, code: "unknown") }
        return data
    }

    private static func upload<T: Decodable>(
        bearer: String, method: String, path: String, data: Data, contentType: String
    ) async throws -> T {
        guard let url = HQConfig.url(path: path) else { throw APIError(status: 0, code: "bad_url") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await Self.transport.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            let body = try? JSONDecoder().decode(ErrorBody.self, from: responseData)
            throw APIError(status: status, code: body?.error ?? "unknown")
        }
        return try JSONDecoder().decode(T.self, from: responseData)
    }

    func attachmentData(id: String) async throws -> Data {
        guard let url = HQConfig.url(path: "/v1/attachments/\(id)") else {
            throw APIError(status: 0, code: "bad_url")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await Self.transport.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 { throw APIError(status: status, code: "unknown") }
        return data
    }

    /// The same bytes as `attachmentData`, streamed to a temporary file instead
    /// of buffered whole in memory. The caller owns the file: move it into
    /// place or delete it (a refusal deletes it here).
    func attachmentFile(id: String) async throws -> URL {
        guard let url = HQConfig.url(path: "/v1/attachments/\(id)") else {
            throw APIError(status: 0, code: "bad_url")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (fileURL, response) = try await Self.transport.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            try? FileManager.default.removeItem(at: fileURL)
            throw APIError(status: status, code: "unknown")
        }
        return fileURL
    }

    /// One person's microphone for a whole call, as a WAV.
    func recordingData(callId: String, deviceId: String) async throws -> Data {
        guard let url = HQConfig.url(path: "/v1/calls/\(callId)/recording/\(deviceId)") else {
            throw APIError(status: 0, code: "bad_url")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await Self.transport.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 { throw APIError(status: status, code: "unknown") }
        return data
    }

    func markRead(conversationId: String, messageId: String) async throws {
        struct Envelope: Codable { let lastReadMessageId: String
            enum CodingKeys: String, CodingKey { case lastReadMessageId = "last_read_message_id" }
        }
        let _: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/conversations/\(conversationId)/read",
            body: ["message_id": messageId]
        )
    }

    func markUnread(conversationId: String) async throws -> Conversation {
        struct Envelope: Codable { let conversation: Conversation }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/conversations/\(conversationId)/unread"
        )
        return envelope.conversation
    }

    func library() async throws -> [Folder] {
        struct Envelope: Codable { let folders: [Folder] }
        let envelope: Envelope = try await Self.request(bearer: bearer, method: "GET", path: "/v1/library")
        return envelope.folders
    }

    func files() async throws -> [HubFile] {
        struct Envelope: Codable { let files: [HubFile] }
        let envelope: Envelope = try await Self.request(bearer: bearer, method: "GET", path: "/v1/files")
        return envelope.files
    }

    func documents() async throws -> [ShelfDocumentSummary] {
        struct Envelope: Codable { let documents: [ShelfDocumentSummary] }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "GET", path: "/v1/documents"
        )
        return envelope.documents
    }

    func document(slug: String) async throws -> ShelfDocument {
        struct Envelope: Codable { let document: ShelfDocument }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "GET", path: "/v1/documents/\(slug)"
        )
        return envelope.document
    }

    /// The projects and what this hub serves: the envelope's `"open_transcripts": true` is a
    /// capability flag, read from the read the store already makes, so a hub without it answers
    /// false. `openTranscripts`: every member may open any synced session's conversation.
    func projects() async throws -> (projects: [Project], openTranscripts: Bool) {
        struct Envelope: Decodable {
            let projects: [Project]
            let openTranscripts: Bool?
            enum CodingKeys: String, CodingKey { case projects, openTranscripts = "open_transcripts" }
        }
        let envelope: Envelope = try await Self.request(bearer: bearer, method: "GET", path: "/v1/projects")
        return (envelope.projects, envelope.openTranscripts == true)
    }

    func createProject(name: String, body: String?, ownerPersonId: String) async throws -> Project {
        struct Body: Encodable {
            let name: String
            let body: String?
            let ownerPersonId: String

            enum CodingKeys: String, CodingKey {
                case name, body
                case ownerPersonId = "owner_person_id"
            }

            /// Written out by hand for one reason: a project created without a
            /// line on what done looks like says so with an explicit null,
            /// which synthesized encoding would omit instead.
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
                try container.encode(body, forKey: .body)
                try container.encode(ownerPersonId, forKey: .ownerPersonId)
            }
        }
        struct Envelope: Codable { let project: Project }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/projects",
            body: Body(name: name, body: body, ownerPersonId: ownerPersonId)
        )
        return envelope.project
    }

    func closeProject(id: String) async throws -> Project {
        struct Envelope: Codable { let project: Project }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "PATCH", path: "/v1/projects/\(id)", body: ["status": "done"]
        )
        return envelope.project
    }

    func assignTask(id: String, ownerPersonId: String) async throws -> TeamTask {
        struct Envelope: Codable { let task: TeamTask }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "PATCH", path: "/v1/tasks/\(id)",
            body: ["owner_person_id": ownerPersonId]
        )
        return envelope.task
    }

    func moveTaskToProject(id: String, projectId: String?) async throws -> TeamTask {
        struct Envelope: Codable { let task: TeamTask }
        // A [String: String?] value encodes nil as JSON null — leaves the project.
        let body: [String: String?] = ["project_id": projectId]
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "PATCH", path: "/v1/tasks/\(id)", body: body
        )
        return envelope.task
    }

    /// Hand order: the dragged row lands against a
    /// neighbour, above it or below it. What comes back is the whole list in
    /// its new order — one row moving reorders every block that shows it.
    func reorderTask(id: String, anchorId: String, isAfter: Bool) async throws -> [TeamTask] {
        struct Envelope: Codable { let tasks: [TeamTask] }
        let body = [isAfter ? "after_task_id" : "before_task_id": anchorId]
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/tasks/\(id)/order", body: body
        )
        return envelope.tasks
    }

  // Do not let an older server silently discard planning fields.
  func requirePlanning() async throws {
    struct Capability: Decodable { let planning: Bool? }
    let capability: Capability = try await Self.request(
      bearer: bearer, method: "GET", path: "/v1/projects")
    guard capability.planning == true else { throw PlanningError.serverUpdateRequired }
  }

  func createPlanningProject(
    name: String, body: String?, owner: String, category: String, state: String, tags: [String]? = nil
  ) async throws -> Project {
    if tags != nil { try await requireProjectLinks() } else { try await requirePlanning() }
    struct Body: Encodable {
        let name: String
        let body: String?
        let owner_person_id: String
        let planning_category: String?
        let planning_state: String
        let tags: [String]?
    }
    struct Envelope: Decodable { let project: Project }
    let result: Envelope = try await Self.request(
      bearer: bearer, method: "POST", path: "/v1/projects",
      body: Body(name: name, body: body, owner_person_id: owner, planning_category: tags == nil ? category : nil, planning_state: state, tags: tags))
    return result.project
  }

  private func requireProjectLinks() async throws {
    struct Capability: Decodable { let project_task_links: Bool? }
    let capability: Capability = try await Self.request(bearer: bearer, method: "GET", path: "/v1/projects")
    guard capability.project_task_links == true else { throw PlanningError.serverUpdateRequired }
  }

  func patchPlanningProject(id: String, fields: [String: String?]) async throws -> Project {
    try await requirePlanning()
    struct Envelope: Decodable { let project: Project }
    let result: Envelope = try await Self.request(
      bearer: bearer, method: "PATCH", path: "/v1/projects/\(id)", body: fields)
    return result.project
  }

  func archivePlanningProject(id: String, archived: Bool) async throws {
    try await requirePlanning()
    struct Envelope: Decodable { let project: Project }
    let _: Envelope = try await Self.request(
      bearer: bearer, method: "PATCH", path: "/v1/projects/\(id)", body: ["archived": archived])
  }

  /// A task's comments, oldest first.
  func taskComments(id: String) async throws -> [HQComment] {
    struct Envelope: Decodable { let comments: [HQComment] }
    let result: Envelope = try await Self.request(
      bearer: bearer, method: "GET", path: "/v1/tasks/\(id)/comments")
    return result.comments
  }

  func projectComments(id: String) async throws -> [HQComment] {
    struct Envelope: Decodable { let comments: [HQComment] }
    let result: Envelope = try await Self.request(
      bearer: bearer, method: "GET", path: "/v1/projects/\(id)/comments")
    return result.comments
  }

  /// `kind` is "tasks" or "projects" — the route the comment lands under.
  func addComment(kind: String, id: String, body: String) async throws {
    struct Envelope: Decodable { let comment: HQComment }
    let _: Envelope = try await Self.request(
      bearer: bearer, method: "POST", path: "/v1/\(kind)/\(id)/comments", body: ["body": body])
  }

  @discardableResult
  func editPlanningTask(id: String, fields: [String: String?]) async throws -> TeamTask {
    try await requirePlanning()
    struct Envelope: Decodable { let task: TeamTask }
    let envelope: Envelope = try await Self.request(
      bearer: bearer, method: "PATCH", path: "/v1/tasks/\(id)", body: fields)
    return envelope.task
  }

    func tasks() async throws -> [TeamTask] {
        struct Envelope: Codable { let tasks: [TeamTask] }
        let envelope: Envelope = try await Self.request(bearer: bearer, method: "GET", path: "/v1/tasks")
        return envelope.tasks
    }

    func createTask(
        title: String, body: String? = nil, ownerPersonId: String, projectId: String? = nil,
        recurrence: TaskRecurrence? = nil, dueAt: Date? = nil
    ) async throws -> TeamTask {
        if recurrence != nil { try await requireRecurringTasks() }
        struct Body: Codable {
            let recurrence: TaskRecurrence?
            let dueAt: String?
            let title: String
            let body: String?
            let ownerPersonId: String
            let projectId: String?

            enum CodingKeys: String, CodingKey {
                case title, body, recurrence
                case dueAt = "due_at"
                case ownerPersonId = "owner_person_id"
                case projectId = "project_id"
            }
        }
        struct Envelope: Codable { let task: TeamTask }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/tasks",
            body: Body(
                recurrence: recurrence,
                dueAt: dueAt.map { ISO8601DateFormatter().string(from: $0) },
                title: title, body: body, ownerPersonId: ownerPersonId, projectId: projectId
            )
        )
        return envelope.task
    }

    private func requireRecurringTasks() async throws {
        // Mac releases and server promotion have separate lanes. Older servers
        // silently ignore unknown fields, so check before any task is written.
        struct Capability: Decodable { let recurring_tasks: Bool? }
        let capability: Capability = try await Self.request(
            bearer: bearer, method: "GET", path: "/v1/tasks"
        )
        guard capability.recurring_tasks == true else { throw TaskScheduleError.serverUpdateRequired }
    }

    func setTaskRecurrence(id: String, recurrence: TaskRecurrence?) async throws -> TeamTask {
        try await requireRecurringTasks()
        struct Body: Encodable {
            let recurrence: TaskRecurrence?
            enum CodingKeys: String, CodingKey { case recurrence }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                // Explicit null stops repetition; an omitted field leaves it alone.
                try container.encode(recurrence, forKey: .recurrence)
            }
        }
        struct Envelope: Codable { let task: TeamTask }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "PATCH", path: "/v1/tasks/\(id)",
            body: Body(recurrence: recurrence)
        )
        return envelope.task
    }

    func deleteTask(id: String) async throws {
        struct Envelope: Codable { let ok: Bool }
        let _: Envelope = try await Self.request(
            bearer: bearer, method: "DELETE", path: "/v1/tasks/\(id)"
        )
    }

    func setProjectTags(id: String, tags: [String]) async throws -> Project {
        try await requireProjectLinks()
        struct Envelope: Decodable { let project: Project }
        let result: Envelope = try await Self.request(bearer: bearer, method: "PATCH", path: "/v1/projects/\(id)", body: ["tags": tags])
        guard result.project.tags != nil else { throw TaskScheduleError.serverUpdateRequired }
        return result.project
    }

    func setTaskProjects(id: String, projectIds: [String]) async throws -> TeamTask {
        try await requireProjectLinks()
        struct Envelope: Decodable { let task: TeamTask }
        let result: Envelope = try await Self.request(bearer: bearer, method: "PATCH", path: "/v1/tasks/\(id)", body: ["project_ids": projectIds])
        guard result.task.projectIds != nil else { throw TaskScheduleError.serverUpdateRequired }
        return result.task
    }

    func codingSessions(taskId: String? = nil, before: String? = nil) async throws -> CodingSessionPage {
        var query: [String] = []
        if let taskId { query.append("task_id=\(taskId)") }
        if let before { query.append("before=\(before)") }
        let suffix = query.isEmpty ? "" : "?" + query.joined(separator: "&")
        return try await Self.request(bearer: bearer, method: "GET", path: "/v1/agent-sessions\(suffix)")
    }

    /// One page of `/v1/agent-sessions/active`. `sinceMinutes` widens the
    /// hub's window (it takes 1...1440; the default is 10).
    func activeCodingThreads(cursor: String? = nil, sinceMinutes: Int? = nil) async throws -> CodingThreadPage {
        var query: [String] = []
        if let sinceMinutes { query.append("since_minutes=\(sinceMinutes)") }
        if let cursor { query.append("cursor=\(cursor)") }
        let suffix = query.isEmpty ? "" : "?" + query.joined(separator: "&")
        return try await Self.request(bearer: bearer, method: "GET", path: "/v1/agent-sessions/active\(suffix)")
    }

    /// Every session in the window: pages of 50 (the hub orders them by id,
    /// not by recency, so the first page alone is an arbitrary slice) until
    /// `next_cursor` is null or repeats (`LiveThreadsModel.walk`). The walk
    /// comes back whole, failure included, so the caller decides what a
    /// partial result is worth (`LiveThreadsModel.resolve`).
    func walkActiveCodingThreads(sinceMinutes: Int) async -> LiveThreadsModel.Walk {
        await LiveThreadsModel.walk { cursor in
            let page = try await self.activeCodingThreads(cursor: cursor, sinceMinutes: sinceMinutes)
            return (page.sessions, page.nextCursor)
        }
    }

    func codingThread(id: String, openTranscripts: Bool = false) async throws -> CodingThreadDetail {
        try await Self.request(bearer: bearer, method: "GET", path: CodingThreadRoutes.detail(id: id, openTranscripts: openTranscripts))
    }

    /// The conversation of a session the server lets this person open.
    func codingTranscript(id: String) async throws -> CodingTranscript {
        try await Self.request(bearer: bearer, method: "GET", path: CodingThreadRoutes.transcript(id: id))
    }

    func updateTaskStatus(id: String, status: String) async throws -> TeamTask {
        struct Envelope: Codable { let task: TeamTask }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "PATCH", path: "/v1/tasks/\(id)",
            body: ["status": status]
        )
        return envelope.task
    }

    struct McpKeySummary: Codable, Identifiable, Sendable {
        let id: String
        let label: String
        let scopes: String
        let createdAt: Int
        let revokedAt: Int?
        /// Stamped at most once a minute; absent on older hubs.
        var lastUsedAt: Int?

        enum CodingKeys: String, CodingKey {
            case id, label, scopes
            case createdAt = "created_at"
            case revokedAt = "revoked_at"
            case lastUsedAt = "last_used_at"
        }
    }

    struct MintedMcpKey: Codable, Sendable {
        let id: String
        let key: String
        let label: String
    }

    func mcpKeys() async throws -> [McpKeySummary] {
        struct Envelope: Codable { let keys: [McpKeySummary] }
        let envelope: Envelope = try await Self.request(bearer: bearer, method: "GET", path: "/v1/mcp-keys")
        return envelope.keys
    }

    func createMcpKey(label: String, scopes: [String] = ["read", "send"]) async throws -> MintedMcpKey {
        struct Body: Codable { let label: String; let scopes: [String] }
        let minted: MintedMcpKey = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/mcp-keys",
            body: Body(label: label, scopes: scopes)
        )
        return minted
    }

    func revokeMcpKey(id: String) async throws {
        struct Envelope: Codable { let ok: Bool }
        let _: Envelope = try await Self.request(
            bearer: bearer, method: "DELETE", path: "/v1/mcp-keys/\(id)"
        )
    }

    /// A sign-in key for a new teammate. The server makes the key and returns it
    /// once; the body carries only the name, because the server refuses a key it did not make.
    func mintKey(personName: String) async throws -> MintedKey {
        try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/keys",
            body: ["person_name": personName]
        )
    }

    struct MintedKey: Decodable, Sendable {
        let ok: Bool
        let personName: String
        let key: String

        enum CodingKeys: String, CodingKey {
            case ok, key
            case personName = "person_name"
        }
    }

    // MARK: - Members (admin)

    /// Promote or demote someone. The hub refuses your own seat, which is what
    /// keeps the company from ending up with no admin at all.
    func setPersonRole(id: String, isAdmin: Bool) async throws -> Person {
        struct Body: Codable { let isAdmin: Bool
            enum CodingKeys: String, CodingKey { case isAdmin = "is_admin" }
        }
        struct Envelope: Codable { let person: Person }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/people/\(id)/role", body: Body(isAdmin: isAdmin)
        )
        return envelope.person
    }

    /// Removing freezes: the person keeps their place in history, and
    /// their devices and keys stop working the same second.
    func removePerson(id: String) async throws -> Person {
        struct Envelope: Codable { let person: Person }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/people/\(id)/remove"
        )
        return envelope.person
    }

    /// Puts the seat back. Access does not come back with it — that needs a
    /// fresh access key.
    func restorePerson(id: String) async throws -> Person {
        struct Envelope: Codable { let person: Person }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/people/\(id)/restore"
        )
        return envelope.person
    }

    // MARK: - Calls

    struct SessionDescriptionWire: Codable, Sendable {
        let sdp: String
        let type: String
    }

    struct JoinedCall: Codable, Sendable {
        let call: Call
        let sessionId: String
        let generation: Int
        /// What the hub supports beyond the original call protocol; absent
        /// from an older hub. `quiet_tracks`: tracks can be published
        /// switched off and toggled by flag.
        var capabilities: [String]?

        enum CodingKeys: String, CodingKey {
            case call, generation, capabilities
            case sessionId = "session_id"
        }
    }

    struct SubscribeResult: Codable, Sendable {
        let sessionDescription: SessionDescriptionWire?
        let shouldRenegotiate: Bool
        let tracks: [SubscribedTrack]

        enum CodingKeys: String, CodingKey {
            case tracks
            case sessionDescription = "session_description"
            case shouldRenegotiate = "requires_immediate_renegotiation"
        }
    }

    struct SubscribedTrack: Codable, Sendable {
        let mid: String?
        let trackName: String?
        let errorCode: String?

        enum CodingKeys: String, CodingKey {
            case mid
            case trackName = "track_name"
            case errorCode = "error_code"
        }
    }

    struct CallsSnapshot: Codable, Sendable {
        let calls: [Call]
        let meetings: [Meeting]
        /// Anything ringing for this person right now. A Mac that was
        /// closed when the call started never saw the frame; the push that
        /// woke it lands here.
        var ringing: [IncomingCall] = []
    }

    func calls() async throws -> CallsSnapshot {
        try await Self.request(bearer: bearer, method: "GET", path: "/v1/calls")
    }

    /// One call's roster. Reading it also vouches for this device's seat —
    /// the hub touches it — so it doubles as the call heartbeat over HTTP,
    /// which still arrives while the event socket is down or half-open.
    func callRoster(callId: String) async throws -> Call {
        struct Envelope: Codable { let call: Call }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "GET", path: "/v1/calls/\(callId)"
        )
        return envelope.call
    }

    func startCall(kind: String, conversationId: String?, meetingId: String?) async throws -> JoinedCall {
        var body: [String: String] = ["client_build": HQBuildInfo.hash, "kind": kind]
        if let conversationId { body["conversation_id"] = conversationId }
        if let meetingId { body["meeting_id"] = meetingId }
        return try await Self.request(bearer: bearer, method: "POST", path: "/v1/calls", body: body)
    }

    /// How a meeting repeats. `weekdays` is 0=Sunday…6=Saturday and applies to
    /// weekly and biweekly only; empty means the first occurrence's own
    /// weekday. The timezone travels with it so the meeting keeps its wall
    /// clock across daylight saving.
    struct RecurrenceBody: Codable, Sendable {
        let freq: String
        let timezone: String
        let weekdays: [Int]
    }

    func createMeeting(
        title: String,
        scheduledAt: Date?,
        inviteePersonIds: [String] = [],
        recurrence: RecurrenceBody? = nil
    ) async throws -> Meeting {
        struct Body: Codable {
            let title: String
            let scheduledAt: String?
            let inviteePersonIds: [String]
            let recurrence: RecurrenceBody?
            enum CodingKeys: String, CodingKey {
                case title, recurrence
                case scheduledAt = "scheduled_at"
                case inviteePersonIds = "invitee_person_ids"
            }
        }
        struct Envelope: Codable { let meeting: Meeting }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/meetings",
            body: Body(
                title: title,
                scheduledAt: scheduledAt.map { ISO8601DateFormatter().string(from: $0) },
                inviteePersonIds: inviteePersonIds,
                recurrence: recurrence
            )
        )
        return envelope.meeting
    }

    /// The whole invite list, not a delta — anyone left out is uninvited. The
    /// creator always stays, whatever is sent.
    func setMeetingInvitees(id: String, personIds: [String]) async throws -> Meeting {
        struct Body: Codable {
            let personIds: [String]
            enum CodingKeys: String, CodingKey { case personIds = "person_ids" }
        }
        struct Envelope: Codable { let meeting: Meeting }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "PUT", path: "/v1/meetings/\(id)/invitees",
            body: Body(personIds: personIds)
        )
        return envelope.meeting
    }

    /// A finished call's record: summary, transcript, and what audio is on
    /// file. Nothing here rides the call frames — it is read when someone
    /// opens the call.
    func callRecord(callId: String) async throws -> CallRecord {
        try await Self.request(bearer: bearer, method: "GET", path: "/v1/calls/\(callId)/record")
    }

    /// Replays a call's saved audio through transcription and rebuilds the
    /// transcript — the recovery path for a call that ended with nothing
    /// written down.
    func retranscribe(callId: String) async throws {
        struct Envelope: Codable { let ok: Bool }
        let _: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/calls/\(callId)/retranscribe",
            body: [String: String]()
        )
    }

    /// Cancels ONE meeting. On a repeating one this skips that occurrence and
    /// the next takes its place — `cancelMeetingSeries` is what stops it.
    func cancelMeeting(id: String) async throws {
        struct Envelope: Codable { let ok: Bool }
        let _: Envelope = try await Self.request(
            bearer: bearer, method: "DELETE", path: "/v1/meetings/\(id)"
        )
    }

    /// Stops a repeating meeting for good. Past occurrences and the thread
    /// survive — nothing is destroyed.
    func cancelMeetingSeries(id: String) async throws {
        struct Envelope: Codable { let ok: Bool }
        let _: Envelope = try await Self.request(
            bearer: bearer, method: "DELETE", path: "/v1/meeting-series/\(id)"
        )
    }

    struct RefusedTrack: Codable, Sendable {
        let mid: String
        let source: String
        let errorCode: String
        enum CodingKeys: String, CodingKey {
            case mid, source
            case errorCode = "error_code"
        }
    }

    struct PublishAnswer: Sendable {
        let sessionDescription: SessionDescriptionWire
        let refused: [RefusedTrack]
    }

    func publish(
        callId: String,
        offer: SessionDescriptionWire,
        tracks: [(mid: String, source: String, isEnabled: Bool?)]
    ) async throws -> PublishAnswer {
        struct Track: Codable {
            let mid: String
            let source: String
            let isEnabled: Bool?
            enum CodingKeys: String, CodingKey {
                case mid, source
                case isEnabled = "is_enabled"
            }
        }
        struct Body: Codable {
            let sessionDescription: SessionDescriptionWire
            let tracks: [Track]
            enum CodingKeys: String, CodingKey {
                case tracks
                case sessionDescription = "session_description"
            }
        }
        struct Envelope: Codable {
            let sessionDescription: SessionDescriptionWire
            // Additive on the wire: an older hub simply omits it.
            let refused: [RefusedTrack]?
            enum CodingKeys: String, CodingKey {
                case refused
                case sessionDescription = "session_description"
            }
        }
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/calls/\(callId)/publish",
            body: Body(
                sessionDescription: offer,
                tracks: tracks.map { Track(mid: $0.mid, source: $0.source, isEnabled: $0.isEnabled) }
            )
        )
        return PublishAnswer(
            sessionDescription: envelope.sessionDescription,
            refused: envelope.refused ?? []
        )
    }

    func subscribe(
        callId: String,
        tracks: [(sessionId: String, trackName: String)]
    ) async throws -> SubscribeResult {
        struct Track: Codable {
            let sessionId: String
            let trackName: String
            enum CodingKeys: String, CodingKey {
                case sessionId = "session_id"
                case trackName = "track_name"
            }
        }
        struct Body: Codable { let tracks: [Track] }
        return try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/calls/\(callId)/subscribe",
            body: Body(tracks: tracks.map { Track(sessionId: $0.sessionId, trackName: $0.trackName) })
        )
    }

    func renegotiate(callId: String, answer: SessionDescriptionWire) async throws {
        struct Body: Codable {
            let sessionDescription: SessionDescriptionWire
            enum CodingKeys: String, CodingKey { case sessionDescription = "session_description" }
        }
        struct Envelope: Codable { let ok: Bool }
        let _: Envelope = try await Self.request(
            bearer: bearer, method: "PUT", path: "/v1/calls/\(callId)/renegotiate",
            body: Body(sessionDescription: answer)
        )
    }

    /// Closes this device's own receive mids on the server for subscriptions it
    /// dropped, so the old copy stops being forwarded. An older hub has no
    /// such route; the caller treats any failure as harmless.
    func unsubscribe(callId: String, mids: [String]) async throws {
        struct Body: Codable { let mids: [String] }
        struct Envelope: Codable { let ok: Bool }
        let _: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/calls/\(callId)/unsubscribe",
            body: Body(mids: mids)
        )
    }

    func unpublish(callId: String, mids: [String], sources: [String]) async throws {
        struct Body: Codable { let mids: [String]; let sources: [String] }
        struct Envelope: Codable { let ok: Bool }
        let _: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/calls/\(callId)/unpublish",
            body: Body(mids: mids, sources: sources)
        )
    }

    // The wire leaves any flag it is not told about alone, so changes travel as
    // a list rather than as a wall of optional booleans.
    enum CallStateChange: Sendable {
        case muted(Bool)
        case cameraOn(Bool)
        case screenSharing(Bool)
        case handRaised(Bool)

        var pair: (key: String, value: Bool) {
            switch self {
            case .muted(let value): return ("is_muted", value)
            case .cameraOn(let value): return ("is_camera_on", value)
            case .screenSharing(let value): return ("is_screen_sharing", value)
            case .handRaised(let value): return ("is_hand_raised", value)
            }
        }
    }

    @discardableResult
    func setCallState(callId: String, changes: [CallStateChange]) async throws -> Call {
        struct Envelope: Codable { let call: Call }
        let body = Dictionary(uniqueKeysWithValues: changes.map(\.pair))
        let envelope: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/calls/\(callId)/state", body: body
        )
        return envelope.call
    }

    /// Turning a ring down. It stops on every Mac this person has.
    func declineCall(callId: String) async throws {
        struct Envelope: Codable { let ok: Bool }
        let _: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/calls/\(callId)/decline",
            body: [String: String]()
        )
    }

    func leaveCall(callId: String) async throws {
        struct Envelope: Codable { let ok: Bool }
        let _: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/calls/\(callId)/leave", body: [String: String]()
        )
    }

    /// This device's push standing: the token when Apple issued one, and always
    /// the reason when it did not, so a server that only heard about successes
    /// could never explain a silent device. `environment` rides along with
    /// either token and only then: a phone that refused notifications still has
    /// a VoIP token, and the server needs to know which of Apple's hosts it
    /// belongs to. A server without push answers 404; callers ignore the error.
    func reportPush(
        status: String, token: String?, voipToken: String?, environment: String
    ) async throws {
        struct Body: Encodable {
            let environment: String?
            let status: String
            let token: String?
            let voipToken: String?

            enum CodingKeys: String, CodingKey {
                case environment, status, token
                case voipToken = "voip_token"
            }
        }
        struct Envelope: Codable { let ok: Bool }
        let _: Envelope = try await Self.request(
            bearer: bearer, method: "POST", path: "/v1/devices/apns-token",
            body: Body(
                environment: token == nil && voipToken == nil ? nil : environment, status: status, token: token,
                voipToken: voipToken
            )
        )
    }

    /// Stops this device hearing pushes (sign-out).
    func unregisterPushToken() async throws {
        struct Envelope: Codable { let ok: Bool }
        let _: Envelope = try await Self.request(
            bearer: bearer, method: "DELETE", path: "/v1/devices/apns-token"
        )
    }

    private static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? value
    }

    private static func request<Body: Encodable, Out: Decodable>(
        bearer: String?, method: String, path: String, body: Body
    ) async throws -> Out {
        try await perform(bearer: bearer, method: method, path: path, bodyData: JSONEncoder().encode(body))
    }

    private static func request<Out: Decodable>(
        bearer: String?, method: String, path: String
    ) async throws -> Out {
        try await perform(bearer: bearer, method: method, path: path, bodyData: nil)
    }

    private static func perform<Out: Decodable>(
        bearer: String?, method: String, path: String, bodyData: Data?
    ) async throws -> Out {
        guard let url = HQConfig.url(path: path) else {
            throw APIError(status: 0, code: "bad_url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await Self.session(for: path).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw APIError(status: status, code: body?.error ?? "unknown")
        }
        return try JSONDecoder().decode(Out.self, from: data)
    }
}

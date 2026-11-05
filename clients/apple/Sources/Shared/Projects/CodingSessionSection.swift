import SwiftUI

/// One agent session linked to a task, as `GET /v1/agent-sessions?task_id=` lists it.
struct CodingSession: Decodable, Identifiable, Sendable {
    let id: String
    let provider: String
    let sourceId: String
    let title: String
    let taskId: String?
    let taskIds: [String]?
    let messageCount: Int
    let revision: Int?
    let toolHistory: Bool?
    let updatedAt: String
    enum CodingKeys: String, CodingKey {
        case id, provider, title, revision
        case toolHistory = "tool_history"
        case sourceId = "source_id"
        case taskId = "task_id"
        case taskIds = "task_ids"
        case messageCount = "message_count"
        case updatedAt = "updated_at"
    }
}

struct CodingSessionPage: Decodable {
    let sessions: [CodingSession]
    let nextBefore: String?
    enum CodingKeys: String, CodingKey {
        case sessions
        case nextBefore = "next_before"
    }
}

/// The agent sessions linked to a task, read-only: each opens its thread.
struct CodingSessionSection: View {
    @Environment(AppStore.self) private var store
    let task: TeamTask
    let actions: ProjectsActions
    @State private var sessions: [CodingSession] = []
    @State private var nextBefore: String?
    @State private var error: String?

    var body: some View {
        CardSection(title: "Agent sessions") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sessions) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Button(session.title.isEmpty ? "Untitled thread" : session.title) { actions.open(.thread(session.id)) }.buttonStyle(.borderless)
                        Text("\(session.provider.capitalized) · Updated \(ISO8601.parse(session.updatedAt).formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    }
                }
                if let nextBefore { Button("Load more") { Task { await load(before: nextBefore) } } }
                if let error {
                    Text(error).foregroundStyle(Tokens.Palette.inkSecondary)
                    Button("Retry") { Task { await load() } }
                } else if sessions.isEmpty {
                    Text("No agent sessions linked yet.").foregroundStyle(.secondary)
                }
            }.font(Tokens.Projects.quiet)
        }
        .task(id: task.id) { await load() }
    }

    private func load(before: String? = nil) async {
        guard let client = store.client else { return }
        do {
            let page = try await client.codingSessions(taskId: task.id, before: before)
            guard !Task.isCancelled else { return }
            sessions = before == nil ? page.sessions : sessions + page.sessions
            nextBefore = page.nextBefore
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Agent sessions could not be loaded. \(error.localizedDescription)"
        }
    }
}

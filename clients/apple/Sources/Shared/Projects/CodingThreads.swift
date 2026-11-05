import SwiftUI

struct CodingThreadPage: Decodable {
    let sessions: [CodingThread]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey { case sessions; case nextCursor = "next_cursor" }
}
struct CodingThreadDetail: Decodable {
    let thread: CodingThread
    let session: CodingSession?
}
enum CodingThreadLink {
    static func url(_ id: String) -> String { "hq://thread/\(id)" }
    static func id(from url: URL) -> String? {
        guard url.scheme == "hq", url.host == "thread", url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let id = String(url.path.dropFirst())
        guard id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { return nil }
        return id
    }
}

/// A task's team-only link, `<server>/HQ-<n>`, which opens here when the
/// server's host is the one this app is signed in to.
enum TaskLink {
    static func url(_ number: Int) -> String { HQConfig.baseURLString + "/HQ-\(number)" }
    static func number(from url: URL) -> Int? {
        guard HQConfig.isServerURL(url),
              url.query == nil, url.fragment == nil, url.pathComponents.count == 2,
              url.lastPathComponent.range(of: "^[Hh][Qq]-[0-9]{1,9}$", options: .regularExpression) != nil
        else { return nil }
        return Int(url.lastPathComponent.dropFirst(3))
    }
}

/// One agent session, read-only: who runs it, what it is for, the projects and tasks it is
/// linked to, and its conversation as text. Kept fresh by a poll while it is open and on screen.
struct CodingThreadView: View {
    @Environment(AppStore.self) private var store
    let id: String
    let actions: ProjectsActions
    @State private var detail: CodingThreadDetail?
    @State private var failure: String?
    @State private var transcript: CodingTranscript?
    @State private var transcriptFailure: String?
    @State private var loadingTranscript = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                BarCircleButton(symbol: "chevron.left", label: "Back", action: actions.back)
                Text("Thread").font(Tokens.Projects.barTitle)
                Spacer()
                Button { ProjectsPasteboard.copy(CodingThreadLink.url(id)); actions.toast("Thread link copied") } label: { Label("Copy link", systemImage: "link") }
                    .buttonStyle(.borderless).help("Copy this thread’s address")
            }.padding(.horizontal, 20).frame(height: Tokens.Projects.boardBarHeight)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let detail {
                        let headline = LiveThreadsModel.headerName(for: detail.thread, sessionTitle: detail.session?.title)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(headline).font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
                            if !detail.thread.intent.isEmpty && detail.thread.intent != headline {
                                Text(detail.thread.intent).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Text("\(detail.thread.ownerName) · \(detail.thread.provider.capitalized) · \(LiveThreadsModel.activityLine(for: detail.thread, now: Date()))")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if !detail.thread.projects.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Projects").font(.subheadline).foregroundStyle(.secondary)
                                ForEach(detail.thread.projects) { project in
                                    Button { actions.open(.project(project.id)) } label: { Label(project.name, systemImage: "folder") }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                        if !detail.thread.tasks.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Tasks").font(.subheadline).foregroundStyle(.secondary)
                                ForEach(detail.thread.tasks) { task in
                                    Button { actions.open(.task(task.id)) } label: { Text("\(task.ref) · \(task.title)").multilineTextAlignment(.leading) }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                        Divider()
                        conversation(detail)
                    } else if let failure {
                        ContentUnavailableView { Label("Thread unavailable", systemImage: "bubble.left") } description: { Text(failure) } actions: { Button("Retry") { Task { await load() } } }
                    } else { ProgressView("Loading thread") }
                }.frame(maxWidth: 820, alignment: .leading).padding(24).frame(maxWidth: .infinity)
            }
        }.task(id: id) {
            detail = nil; failure = nil; transcript = nil; transcriptFailure = nil
            await load()
        }
        // Keep titles and activity fresh while the thread is open and on screen.
        .background {
            VisiblePoll(key: id, interval: .seconds(15)) { await load() }
        }
    }

    private func load() async {
        guard let client = store.client else { return }
        do { let result = try await client.codingThread(id: id, openTranscripts: store.supportsOpenTranscripts); try Task.checkCancellation(); detail = result; failure = nil }
        catch { if !Task.isCancelled { failure = "This thread is unavailable or you don’t have access. Try again." } }
    }

    /// The conversation: a button until it is opened, then the messages as plain selectable text.
    @ViewBuilder private func conversation(_ detail: CodingThreadDetail) -> some View {
        if detail.session == nil {
            Label("This conversation is private to \(detail.thread.ownerName).", systemImage: "lock").foregroundStyle(.secondary)
        } else {
            HStack {
                Text("Conversation").font(.headline)
                Spacer()
                if transcript != nil { Button("Refresh") { Task { await readTranscript() } }.disabled(loadingTranscript) }
            }
            if detail.session?.revision == 0 {
                Text("Waiting for the first sync.").foregroundStyle(.secondary)
            } else if transcript == nil {
                Button("View full conversation", systemImage: "text.bubble") { Task { await readTranscript() } }.disabled(loadingTranscript)
            }
            if loadingTranscript { ProgressView("Loading conversation") }
            if let transcriptFailure { Text(transcriptFailure).foregroundStyle(.secondary) }
            if let transcript {
                ForEach(transcript.messages) { message in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(message.role == "user" ? detail.thread.ownerName : detail.thread.provider.capitalized).font(.subheadline.weight(.semibold))
                            if let date = message.date { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
                        }
                        // Plain text: nothing in a transcript is rendered as a link or markup.
                        Text(message.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                    .background(message.role == "user" ? Color.accentColor.opacity(0.07) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                }
                if transcript.messages.isEmpty { Text("No conversation text yet.").foregroundStyle(.secondary) }
                Text("Only the text of the messages is shown. Secrets are hidden on a best-effort basis; tool calls, reasoning and attachments are not included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func readTranscript() async {
        guard let client = store.client else { return }
        loadingTranscript = true
        defer { loadingTranscript = false }
        do { let result = try await client.codingTranscript(id: id); try Task.checkCancellation(); transcript = result; transcriptFailure = nil }
        catch { if !Task.isCancelled { transcriptFailure = "Couldn’t load the conversation. Please try again." } }
    }
}

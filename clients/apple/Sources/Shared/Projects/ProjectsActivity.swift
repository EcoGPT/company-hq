import Observation
import SwiftUI

// A card's or a board's comments, read
// when the card or panel opens, after each post, and when the hub's comment
// count on the card or board moves — the comments themselves never stream.
// Comments carry "via Claude" when a session wrote them as their person
// (`via == "mcp"`).

@MainActor @Observable
final class CommentThread {
    enum Target: Hashable {
        case task(String)
        case project(String)

        var route: (kind: String, id: String) {
            switch self {
            case .task(let id): ("tasks", id)
            case .project(let id): ("projects", id)
            }
        }
    }

    let target: Target
    private(set) var comments: [HQComment] = []
    private(set) var isLoaded = false
    private(set) var isPosting = false
    var failure: String?

    init(target: Target) {
        self.target = target
    }

    /// Whether an open panel should read the comments again: on first open,
    /// and whenever the hub's count (carried on every `tasks` frame) differs
    /// from what the thread holds — someone else commented. An unknown count
    /// (an older hub's board) only loads once.
    nonisolated static func needsLoad(isLoaded: Bool, held: Int, hubCount: Int?) -> Bool {
        !isLoaded || (hubCount != nil && held != hubCount!)
    }

    func needsLoad(hubCount: Int?) -> Bool {
        Self.needsLoad(isLoaded: isLoaded, held: comments.count, hubCount: hubCount)
    }

    func load(_ client: HQClient?) async {
        guard let client else { return }
        do {
            switch target {
            case .task(let id): comments = try await client.taskComments(id: id)
            case .project(let id): comments = try await client.projectComments(id: id)
            }
            isLoaded = true
            failure = nil
        } catch {
            guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
            failure = "Couldn’t load comments."
        }
    }

    /// Posts, then re-reads. Returns whether it landed, so the composer keeps
    /// what was typed when it did not.
    func didPost(_ body: String, client: HQClient?) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isPosting, let client else { return false }
        isPosting = true
        defer { isPosting = false }
        do {
            try await client.addComment(kind: target.route.kind, id: target.route.id, body: text)
            await load(client)
            return true
        } catch {
            failure = "Your comment could not be saved. Please try again."
            return false
        }
    }
}

/// "Comments and activity": the feed oldest first, the composer
/// under the latest. Each comment is a name over a bordered block, with
/// "via Claude" when a session wrote it as their person. In a column of its own (the board's comments) the
/// feed scrolls by itself, opens on the latest and follows each post; a
/// card's panel draws the feed and the composer apart (`CardActivityFeed`,
/// `CardComposer`) so its composer stays pinned at the panel's foot.
struct CardActivity<Extra: View>: View {
    let thread: CommentThread?
    var placeholder = "Write a comment…"
    var isScrolling = false
    var showsHeader = true
    /// After a post lands: the board re-reads, so a card's count follows.
    var onPosted: (() -> Void)?
    @ViewBuilder var extra: Extra

    private static var latest: String { "comments-latest" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                CardActivityHeader()
            }
            if isScrolling {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        CardActivityFeed(thread: thread) { extra }
                        Color.clear.frame(height: 1).id(Self.latest)
                    }
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    .scrollIndicators(.automatic)
                    .frame(maxHeight: .infinity)
                    .onChange(of: thread?.comments.last?.id) { _, _ in
                        proxy.scrollTo(Self.latest, anchor: .bottom)
                    }
                }
            } else {
                CardActivityFeed(thread: thread) { extra }
            }
            if let thread {
                CardComposer(thread: thread, placeholder: placeholder, onPosted: onPosted)
            }
        }
    }
}

/// The feed alone, oldest first.
struct CardActivityFeed<Extra: View>: View {
    let thread: CommentThread?
    @ViewBuilder var extra: Extra

    private var comments: [HQComment] { ProjectsModel.feed(thread?.comments ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(comments) { comment in
                FeedCommentRow(comment: comment)
            }
            extra
            if let thread, thread.isLoaded, comments.isEmpty, Extra.self == EmptyView.self {
                Text("No comments yet.")
                    .font(Tokens.Projects.feedEvent)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .padding(.leading, Tokens.Projects.panelGutter)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The composer: my face, the field, Send (⌘Return). What was typed stays
/// when a post does not land.
struct CardComposer: View {
    @Environment(AppStore.self) private var store
    let thread: CommentThread
    var placeholder = "Write a comment…"
    var onPosted: (() -> Void)?
    @State private var draft = ""

    private var canSend: Bool {
        !thread.isPosting && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let field = RoundedRectangle(cornerRadius: 17, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            if let failure = thread.failure {
                Text(failure).font(Tokens.Projects.feedEvent).foregroundStyle(Tokens.Palette.danger)
            }
            HStack(alignment: .top, spacing: 0) {
                AvatarView(name: store.me?.name ?? "", isGroup: false, size: Tokens.Projects.panelFace)
                    .padding(.top, 3)
                    .frame(width: Tokens.Projects.panelGutter, alignment: .leading)
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Tokens.Projects.panelBody)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(minHeight: 34)
                    .background(Tokens.Projects.panelWell, in: field)
                    .onSubmit(send)
                    .accessibilityLabel("Comment")
                Button("Save", action: send)
                    .buttonStyle(PanelButtonStyle(isProminent: true))
                    .opacity(canSend ? 1 : 0.45)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .padding(.leading, 8)
                    .padding(.top, 2)
                    .accessibilityLabel("Save comment")
            }
        }
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        Task { @MainActor in
            if await thread.didPost(text, client: store.client) {
                draft = ""
                onPosted?()
            }
        }
    }
}

/// A board's comments' heading.
struct CardActivityHeader: View {
    var body: some View {
        Text("Comments")
            .font(Tokens.Projects.panelSection)
            .foregroundStyle(Tokens.Palette.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

extension CardActivity where Extra == EmptyView {
    init(
        thread: CommentThread?, placeholder: String = "Write a comment…", isScrolling: Bool = false,
        showsHeader: Bool = true, onPosted: (() -> Void)? = nil
    ) {
        self.init(
            thread: thread, placeholder: placeholder, isScrolling: isScrolling, showsHeader: showsHeader,
            onPosted: onPosted
        ) { EmptyView() }
    }
}

/// A person's comment: their face, "Ada · via Claude" and the time, then
/// the words in a bordered block.
struct FeedCommentRow: View {
    let comment: HQComment

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            AvatarView(name: comment.authorName, isGroup: false, size: Tokens.Projects.panelFace)
                .frame(width: Tokens.Projects.panelGutter, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(comment.authorName).font(Tokens.Projects.feedName).foregroundStyle(Tokens.Palette.ink)
                    if comment.isViaAgent {
                        Text("via Claude")
                            .font(Tokens.Projects.feedWhen)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                    }
                    Text(ActivityStamp.text(ISO8601.parse(comment.createdAt)))
                        .font(Tokens.Projects.feedWhen)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .fixedSize()
                }
                .lineLimit(1)
                Text(comment.body)
                    .font(Tokens.Projects.panelBody)
                    .foregroundStyle(Tokens.Palette.ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.Projects.panelWell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

enum ActivityStamp {
    /// Today's events by the clock, older ones by the day.
    static func text(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? ListStamp.time(date) : ListStamp.day(date)
    }
}

/// A board's own comments, behind the bar's Comments
/// button: the card dialog's "Comments and activity" column, standing beside
/// the board on the Mac and in a sheet on the iPhone. Above the feed, where
/// Trello keeps "About this board", the board's description.
struct ProjectCommentsPanel: View {
    @Environment(AppStore.self) private var store
    let project: Project
    @Bindable var text: PlanningTextAutosave
    let onPosted: () -> Void
    let onClose: () -> Void
    @State private var thread: CommentThread

    init(
        project: Project, text: PlanningTextAutosave, onPosted: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.project = project
        self.text = text
        self.onPosted = onPosted
        self.onClose = onClose
        _thread = State(initialValue: CommentThread(target: .project(project.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                CardActivityHeader()
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                        .hqMinimumControlTarget()
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close comments")
            }
            about
            CardActivity(thread: thread, isScrolling: true, showsHeader: false, onPosted: onPosted)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(project.id)|\(project.commentCount.map(String.init) ?? "")") {
            if thread.needsLoad(hubCount: project.commentCount) { await thread.load(store.client) }
        }
        // The board under the panel keeps the text in step with the hub.
        .onDisappear { text.flush() }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About this board")
                .font(Tokens.Projects.panelLabel)
                .foregroundStyle(Tokens.Palette.inkSecondary)
            TextField("What this board is for…", text: $text.body, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Tokens.Projects.panelBody)
                .lineLimit(1...5)
                .foregroundStyle(Tokens.Palette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Projects.panelWell, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Board description")
            if let error = text.error {
                HStack {
                    Text(error).font(Tokens.Projects.feedEvent).foregroundStyle(Tokens.Palette.danger)
                    Button("Retry") { text.flush() }.buttonStyle(.plain).foregroundStyle(Tokens.Palette.accent)
                }
            }
        }
    }
}

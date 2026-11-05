import SwiftUI

typealias ProjectsRun = (@escaping (HQClient) async throws -> Void) -> Void

/// What every board and card can ask of the workspace: go somewhere, come
/// back, create, and write through the one save path.
struct ProjectsActions {
    let open: (ProjectsRoute) -> Void
    let back: () -> Void
    /// Closes the right panel — a card, or the board's comments.
    let closeCard: () -> Void
    let newProject: (String?) -> Void
    /// A card typed into a list: its title, the list's status, the board's
    /// project (nil on My tasks) and who owns it.
    let createCard: (String, String, String?, String) -> Void
    let setStatus: (TeamTask, String) -> Void
    let assign: (TeamTask, String) -> Void
    let move: (TeamTask, String?) -> Void
    /// A task dragged to a list and slot (or moved by its menu), drawn there
    /// at once and taken back quietly if the hub refuses.
    let dropTask: (TeamTask, TaskDrop) -> Void
    let deleteProject: (Project) -> Void
    let patchProject: (Project, [String: String?]) -> Void
    let refresh: () -> Void
    let toast: (String) -> Void
    let run: ProjectsRun
    let text: (TeamTask) -> PlanningTextAutosave
    /// What a queued write starts from and hands its answer to: the card or
    /// board as the last write in this burst got it back, else the store's.
    let latestTask: (String) -> TeamTask?
    let applyTask: (TeamTask) -> Void
    let latestProject: (String) -> Project?
    let applyProject: (Project) -> Void
}

/// What the workspace's width decides — whether a card sits beside the board
/// and how wide its panel is. Stored instead of the raw width, so a window
/// resize or a sidebar drag redraws the workspace only when one of them moves.
struct ProjectsWidth: Equatable {
    let isBeside: Bool
    let panelWidth: CGFloat

    init(width: CGFloat) {
        isBeside = width >= Tokens.Projects.panelBelow
        panelWidth = min(Tokens.Projects.panelWidth, max(width * 0.5, 320))
    }
}

/// The Tasks shortcut, drawn the way Trello draws it: a home that is the
/// Agents list of everyone's agents, a board per project (and My tasks), and a
/// card that opens in a panel at the board's right — the board still live
/// and scrolling beside it. A phone has no room beside, so there the card
/// fills the screen. `AppStore.projectsPath` routes it; one view on both
/// platforms.
struct ProjectsWorkspace: View {
    @Environment(AppStore.self) private var store
    /// The Agents list's state lives in the app's store, which outlasts this view.
    private var live: LiveThreadsStore { store.liveThreads }
    @State private var draft: PlanningDraft?
    @State private var textEditors = PlanningTextEditors()
    @State private var writes = ProjectsWriteQueue()
    @State private var failure: String?
    @State private var toast: String?
    /// What the workspace's own width decides: under 720pt a card fills the
    /// screen.
    #if os(macOS)
        @State private var layout = ProjectsWidth(width: 1_000)
    #else
        @State private var layout = ProjectsWidth(width: 0)
    #endif
    @State private var undoHistory = PlanningUndoHistory()
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let isBeside = layout.isBeside
        let panel = ProjectsRouting.panel(store.projectsPath)
        let isFilling = panel != nil && !isBeside && !isCommentsSheet(panel)
        ZStack(alignment: .topTrailing) {
            // A card that fills the screen has nothing drawn under it. Only
            // the bars group their glass (`hqGlassContainer`): a container
            // around the lists draws their glass outside the scroll view's
            // clip, under the panel.
            if !isFilling {
                board
                    .id(boardRoute)
                    .environment(
                        \.projectsPanelInset, panel != nil && isBeside ? panelWidth + Tokens.Projects.panelMargin * 2 : 0)
                    .environment(\.projectsOpenCardID, ProjectsRouting.openCardID(store.projectsPath))
            }
            if let panel {
                if isBeside {
                    sidePanel(panel)
                } else if isFilling {
                    panelContent(panel, isFullScreen: true)
                        .id(panel)
                        .background(Tokens.Palette.surface.ignoresSafeArea())
                }
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .background(Tokens.Palette.surface)
        .foregroundStyle(Tokens.Palette.ink)
        .onGeometryChange(for: ProjectsWidth.self, of: { ProjectsWidth(width: $0.size.width) }, action: { layout = $0 })
        .transaction { $0.animation = nil }
        #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
        #endif
        .task { await refresh() }
        .sheet(item: $draft) { PlanningCreateSheet(draft: $0) }
        #if os(iOS)
            .sheet(isPresented: isShowingCommentsSheet(isBeside: isBeside)) {
                if let project = commentsProject {
                    ProjectCommentsPanel(
                        project: project, text: projectText(project), onPosted: actions.refresh,
                        onClose: closeCard
                    )
                    .environment(store)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Tokens.Palette.surface)
                }
            }
        #endif
        .alert(
            "Tasks",
            isPresented: Binding(
                get: { failure != nil || store.taskMutationError != nil },
                set: { isShown in
                    guard !isShown else { return }
                    failure = nil
                    store.taskMutationError = nil
                })
        ) {
            Button("OK") {}
        } message: {
            Text(failure ?? store.taskMutationError ?? "")
        }
    }

    // MARK: Routing

    private var panelWidth: CGFloat { layout.panelWidth }

    /// The board whose comments are open, when the path ends in them.
    private var commentsProject: Project? {
        guard case .projectComments(let id) = store.projectsPath.last else { return nil }
        return store.projects.first { $0.id == id }
    }

    /// A phone keeps a board's comments in a sheet over the board.
    private func isCommentsSheet(_ panel: ProjectsRoute?) -> Bool {
        #if os(iOS)
            if case .projectComments = panel { return true }
        #endif
        return false
    }

    #if os(iOS)
        private func isShowingCommentsSheet(isBeside: Bool) -> Binding<Bool> {
            Binding(
                get: { !isBeside && commentsProject != nil },
                set: { isShown in
                    if !isShown, store.projectsPath.last?.isPanel == true { closeCard() }
                })
        }
    #endif

    /// The right panel: the sidebar's own glass pane, mirrored — full
    /// height, the same shape inset inside its frame
    /// (`RootView.sidebarPaneShape`), which is what leaves native glass the
    /// room to draw its shadow; a shape that fills its frame has its shadow
    /// clipped away. It floats over the lists, which run on under it and
    /// take its shadow (`projectsPanelInset`); the bar stops at its edge. A
    /// card and the comments take turns in it.
    private func sidePanel(_ route: ProjectsRoute) -> some View {
        let inset = Tokens.Projects.panelMargin
        let pane = RoundedRectangle(cornerRadius: 28, style: .continuous).inset(by: inset)
        return panelContent(route, isFullScreen: false)
            .id(route)
            .padding(inset)
            .frame(width: panelWidth + inset * 2)
            .frame(maxHeight: .infinity, alignment: .top)
            .clipShape(pane)
            .hqGlass(in: pane)
    }

    @ViewBuilder private func panelContent(_ route: ProjectsRoute, isFullScreen: Bool) -> some View {
        switch route {
        case .task(let id):
            if let task = store.tasks.first(where: { $0.id == id }) {
                TaskCardPanel(task: task, actions: actions, text: taskText(task), isFullScreen: isFullScreen)
            } else {
                panelMissing("That card is gone.")
            }
        case .projectComments(let id):
            if let project = store.projects.first(where: { $0.id == id }) {
                ProjectCommentsPanel(
                    project: project, text: projectText(project), onPosted: actions.refresh, onClose: closeCard)
            } else {
                panelMissing("That board is gone.")
            }
        default:
            EmptyView()
        }
    }

    private func panelMissing(_ sentence: String) -> some View {
        CardPanelFrame(isFullScreen: false, onClose: closeCard) {
            EmptyView()
        } menu: {
            EmptyView()
        } content: {
            Text(sentence)
                .font(Tokens.Projects.panelBody)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .padding(20)
        } footer: {
            EmptyView()
        }
    }

    /// The board under everything: the last board on the path, or — for a
    /// card or panel opened straight from the room or a fixture — its own.
    private var boardRoute: ProjectsRoute? {
        if let board = store.projectsPath.last(where: \.isBoard) { return board }
        switch store.projectsPath.last {
        case .projectComments(let id): return .project(id)
        case .task(let id):
            guard let task = store.tasks.first(where: { $0.id == id }) else { return nil }
            return task.projectId.map { .project($0) } ?? .mine
        default: return nil
        }
    }

    @ViewBuilder private var board: some View {
        switch boardRoute {
        case nil:
            ProjectsHome(actions: actions, live: live)
        case .thread(let id):
            CodingThreadView(id: id, actions: actions)
        case .project(let id):
            if let project = store.projects.first(where: { $0.id == id }) {
                ProjectBoard(project: project, actions: actions, text: projectText(project))
            } else {
                missing("That board is gone.")
            }
        case .mine:
            MyTasksBoard(actions: actions)
        case .task, .projectComments:
            missing("That card is gone.")
        }
    }

    private func missing(_ sentence: String) -> some View {
        VStack(spacing: 0) {
            BoardBar(title: "Tasks", onBack: actions.back) { EmptyView() } menu: { EmptyView() }
            Text(sentence)
                .font(Tokens.Projects.quiet)
                .foregroundStyle(Tokens.Palette.inkTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast)
                .font(Tokens.Projects.quiet.weight(.semibold))
                .padding(.horizontal, Tokens.Space.x4)
                .padding(.vertical, 9)
                .hqGlass(in: Capsule())
                .padding(.bottom, 26)
                .allowsHitTesting(false)
        }
    }

    // MARK: Actions

    private var actions: ProjectsActions {
        ProjectsActions(
            open: { route in
                // A panel opened from a board the path does not name (a card
                // that came from the room) pins that board under it first,
                // so the next card swaps beside the same board.
                var path = store.projectsPath
                if route.isInPanel, path.last(where: \.isBoard) == nil, let under = boardRoute {
                    path = ProjectsRouting.closingPanel(path, under: under)
                }
                store.projectsPath = ProjectsRouting.opening(route, on: path)
            },
            back: {
                // Back leaves the board, not just the comments beside it.
                while store.projectsPath.last?.isPanel == true { store.projectsPath.removeLast() }
                if store.projectsPath.isEmpty {
                    store.destination = .none
                } else {
                    store.projectsPath.removeLast()
                }
            },
            closeCard: closeCard,
            newProject: { category in draft = .project(category: category ?? "Product", state: "Next") },
            createCard: createCard,
            setStatus: { task, status in
                run { client in
                    try await ProjectsTaskWrite.status(
                        of: task, to: status, latest: latestTask,
                        send: { try await client.updateTaskStatus(id: task.id, status: $0) },
                        apply: applyTask)
                }
            },
            // Each task write hands the hub's answer to the store, so a write
            // queued behind it starts from the card as it now stands.
            assign: { task, person in
                run { client in applyTask(try await client.assignTask(id: task.id, ownerPersonId: person)) }
            },
            move: { task, projectId in
                run { client in applyTask(try await client.moveTaskToProject(id: task.id, projectId: projectId)) }
            },
            dropTask: { task, drop in
                // A drag (or Move To) skips the queue, so the store's copy
                // is newer than any answer held for the card.
                writes.forget(TeamTask.self, id: task.id)
                let move = store.moveTaskOnBoard(task.id, drop: drop)
                Task { @MainActor in
                    if await !move.value { showToast("Couldn’t move that card.") }
                }
            },
            deleteProject: deleteProject,
            patchProject: { project, fields in
                run { client in _ = try await client.patchPlanningProject(id: project.id, fields: fields) }
            },
            refresh: { Task { await refresh() } },
            toast: showToast,
            run: run,
            text: taskText,
            latestTask: latestTask,
            applyTask: applyTask,
            latestProject: { id in writes.latest(id, in: store.projects) },
            applyProject: { project in
                writes.hold(project)
                store.applyPlanningProject(project)
            }
        )
    }

    private func latestTask(_ id: String) -> TeamTask? { writes.latest(id, in: store.tasks) }

    private func applyTask(_ task: TeamTask) {
        writes.hold(task)
        store.applyPlanningTask(task)
    }

    /// Closing the panel (a card, or a board's comments) lands on the board
    /// under it — the one it was opened from, or its own when it was opened
    /// from the room or a fixture.
    private func closeCard() {
        guard ProjectsRouting.panel(store.projectsPath) != nil else { return }
        store.projectsPath = ProjectsRouting.closingPanel(store.projectsPath, under: boardRoute)
    }

    /// A card typed into a list is a task in that list's status, through
    /// the same create call the sheet makes.
    private func createCard(title: String, status: String, projectId: String?, owner: String) {
        run { client in
            let task = try await client.createTask(title: title, ownerPersonId: owner, projectId: projectId)
            if status != task.status {
                _ = try await client.updateTaskStatus(id: task.id, status: status)
            }
        }
    }

    /// Deleting archives, and ⌘Z brings it back — the old board's promise.
    private func deleteProject(_ project: Project) {
        run { client in
            try await client.archivePlanningProject(id: project.id, archived: true)
            undoHistory.recordDeletion(manager: undoManager) { restore in
                do {
                    try await client.archivePlanningProject(id: project.id, archived: !restore)
                    try await store.refreshPlanning()
                } catch {
                    failure = "Couldn’t restore the change. Please try again."
                }
            }
        }
        store.projectsPath.removeAll { $0 == .project(project.id) }
    }

    private func showToast(_ message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            if toast == message { toast = nil }
        }
    }

    /// A board's name and description, autosaved as the old project page
    /// saved them: a draft survives navigation and a refused write.
    private func projectText(_ project: Project) -> PlanningTextAutosave {
        textEditors.editor(
            scope: [HQConfig.baseURLString, store.me?.id ?? "", "project", project.id],
            value: .init(title: project.name, body: project.body ?? ""), titleLimit: 60, bodyLimit: 2000
        ) { next, saved in
            guard let client = store.client else { throw PlanningError.serverUpdateRequired }
            var fields: [String: String?] = [:]
            if next.title != saved.title { fields["name"] = next.title }
            if next.body != saved.body { fields["body"] = next.body }
            // The PATCH answers with the project as the hub has it: the board
            // shows that now. The hub's own `tasks` frame follows and the
            // store re-reads the projects once for it.
            let updated = try await client.patchPlanningProject(id: project.id, fields: fields)
            store.applyPlanningProject(updated)
            await refreshIfSocketDown()
        }
    }

    /// The task's title and description, autosaved as they always were: a
    /// draft survives navigation and a refused write.
    private func taskText(_ task: TeamTask) -> PlanningTextAutosave {
        textEditors.editor(
            scope: [HQConfig.baseURLString, store.me?.id ?? "", "task", task.id],
            value: .init(title: task.title, body: task.body ?? ""), titleLimit: 200, bodyLimit: 8000
        ) { next, saved in
            guard let client = store.client else { throw PlanningError.serverUpdateRequired }
            var fields: [String: String?] = [:]
            if next.title != saved.title { fields["title"] = next.title }
            if next.body != saved.body { fields["body"] = next.body }
            let updated = try await client.editPlanningTask(id: task.id, fields: fields)
            store.applyPlanningTask(updated)
            await refreshIfSocketDown()
        }
    }

    /// After an autosaved write: the hub answers every planning edit with a
    /// `tasks` frame, and the store answers that frame by replacing the tasks
    /// and re-reading the projects, so a refresh of our own would only repeat
    /// it (two more reads and a board re-render per typing pause). With the
    /// socket down nothing else will bring the change back, so then it reads.
    private func refreshIfSocketDown() async {
        guard !store.isSocketLive else { return }
        try? await store.refreshPlanning()
    }

    private func refresh() async {
        do { try await store.refreshPlanning() } catch {
            if !Task.isCancelled, (error as? URLError)?.code != .cancelled {
                failure = "Couldn’t load projects. Please try again."
            }
        }
    }

    /// Every board write waits its turn behind the one in flight rather than
    /// being dropped; the board re-reads once when the burst is done.
    private func run(_ operation: @escaping (HQClient) async throws -> Void) {
        guard let client = store.client else { return }
        writes.enqueue(
            { try await operation(client) },
            onFailure: { error in
                failure =
                    (error as? PlanningError)?.errorDescription
                    ?? "Your change could not be saved. Please try again."
            },
            refresh: {
                do { try await store.refreshPlanning() } catch {
                    failure = "Saved, but couldn’t refresh. Pull to refresh."
                }
            })
    }
}

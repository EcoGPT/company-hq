import SwiftUI

// A card, opened the way Trello opens one, as a glass sheet at the board's
// right — kept minimal: the list pill and HQ-n; the completion mark and a
// bold title; the owner and due date as two chips; then Description, Pull
// requests and Activity under plain small headings.
// Comments read oldest first, so the field sits under the
// latest, pinned at the sheet's foot. Text is plain until clicked. Inside
// the glass, chips and wells are translucent tints — never glass on glass.
// A phone has no room beside the board, so there the column fills the
// screen on the window's surface.

// MARK: - Frame

struct CardPanelFrame<Top: View, Menu: View, Content: View, Footer: View>: View {
    let isFullScreen: Bool
    let onClose: () -> Void
    /// Bumped after a post, so the panel follows it to the latest comment.
    var follow = 0
    /// The header's left: the list pill and the card's `HQ-<n>`.
    @ViewBuilder var top: Top
    /// The header's right, beside ✕: the card's "…".
    @ViewBuilder var menu: Menu
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    static var latest: String { "card-panel-latest" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                top
                Spacer(minLength: 8)
                menu
                closeButton
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(minHeight: 50)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        content
                        Color.clear.frame(height: 1).id(Self.latest)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: follow) { _, _ in
                    proxy.scrollTo(Self.latest, anchor: .bottom)
                }
            }
            if Footer.self != EmptyView.self {
                footer
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, isFullScreen ? 10 : 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(isFullScreen ? Tokens.Palette.surface : .clear)
    }

    private var closeButton: some View {
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
        .accessibilityLabel("Close card")
    }
}

/// The column's padding and rhythm, shared by both kinds of card.
private struct PanelColumn: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 18)
            .padding(.top, 2)
            .padding(.bottom, 20)
    }
}

// MARK: - Pieces

/// A section: a small plain heading over what it holds.
struct CardSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Tokens.Projects.panelLabel)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// The panel's chip: the list pill, the owner, a date. Prominent is blue.
struct PanelButtonStyle: ButtonStyle {
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        PanelChip(isProminent: isProminent) { configuration.label }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The chip's face, for menus whose label is drawn by the caller: a
/// translucent capsule on the sheet's glass; prominent, a solid blue one.
struct PanelChip<Label: View>: View {
    var isProminent = false
    @ViewBuilder var label: Label

    var body: some View {
        HStack(spacing: 6) { label }
            .font(Tokens.Projects.panelButton)
            .foregroundStyle(isProminent ? Color.white : Tokens.Palette.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(isProminent ? Tokens.Palette.accent : Tokens.Projects.panelWell, in: Capsule())
            .contentShape(Capsule())
    }
}

/// A plain menu whose label is drawn by the caller.
private struct QuietMenu<Items: View, Label: View>: View {
    @ViewBuilder var items: Items
    @ViewBuilder var label: Label

    var body: some View {
        Menu {
            items
        } label: {
            label
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The panel's "…".
private struct PanelMenuGlyph: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Tokens.Palette.inkSecondary)
            .frame(width: 30, height: 30)
            .contentShape(Circle())
    }
}

/// Trello's title: text until clicked, then a field; Return or clicking
/// away ends it. The autosave writes what was typed either way.
struct CardTitle: View {
    @Binding var title: String
    var isEditable = true
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField("Title", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Tokens.Projects.panelTitle)
                .focused($isFocused)
                .onSubmit { isEditing = false }
                .onChange(of: isFocused) { _, isNowFocused in
                    if !isNowFocused { isEditing = false }
                }
                .onAppear { isFocused = true }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Tokens.Palette.accent, lineWidth: 2)
                )
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
                .accessibilityLabel("Title")
        } else {
            Text(title.isEmpty ? "Untitled" : title)
                .font(Tokens.Projects.panelTitle)
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if isEditable { isEditing = true } }
                .accessibilityAddTraits(isEditable ? [.isHeader, .isButton] : .isHeader)
                .accessibilityAction { if isEditable { isEditing = true } }
        }
    }
}

// MARK: - Task

struct TaskCardPanel: View {
    @Environment(AppStore.self) private var store
    let task: TeamTask
    let actions: ProjectsActions
    @Bindable var text: PlanningTextAutosave
    let isFullScreen: Bool
    @State private var thread: CommentThread
    @State private var isPickingDate = false
    @State private var date = Date()
    @State private var follow = 0
    @State private var isEditingBody = false
    @FocusState private var isBodyFocused: Bool

    init(task: TeamTask, actions: ProjectsActions, text: PlanningTextAutosave, isFullScreen: Bool) {
        self.task = task
        self.actions = actions
        self.text = text
        self.isFullScreen = isFullScreen
        _thread = State(initialValue: CommentThread(target: .task(task.id)))
    }

    private var project: Project? { store.projects.first { $0.id == task.projectId } }

    var body: some View {
        CardPanelFrame(isFullScreen: isFullScreen, onClose: actions.closeCard, follow: follow) {
            listPill
            if let ref = task.ref {
                Text(ref)
                    .font(Tokens.Projects.mono)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .textSelection(.enabled)
            }
        } menu: {
            cardMenu
        } content: {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    titleRow
                    if let error = text.error {
                        HStack {
                            Text(error).font(Tokens.Projects.quiet).foregroundStyle(Tokens.Palette.danger)
                            Button("Retry") { text.flush() }
                                .buttonStyle(.plain)
                                .foregroundStyle(Tokens.Palette.accent)
                        }
                    }
                    fields
                }
                projectLinks
                CodingSessionSection(task: task, actions: actions).id(task.id)
                description
                CardSection(title: "Activity") {
                    CardActivityFeed(thread: thread) { EmptyView() }
                }
            }
            .modifier(PanelColumn())
        } footer: {
            CardComposer(thread: thread) {
                follow += 1
                actions.refresh()
            }
        }
        .task(id: "\(task.id)|\(task.commentCount)") {
            if thread.needsLoad(hubCount: task.commentCount) { await thread.load(store.client) }
        }
        .onAppear {
            text.receive(.init(title: task.title, body: task.body ?? ""))
            text.flush()
        }
        .onDisappear { text.flush() }
        .onChange(of: PlanningTextValue(title: task.title, body: task.body ?? "")) { _, value in
            text.receive(value)
        }
    }

    /// Trello's "To Do ▾": the list the card is in, and a menu of the others.
    private var listPill: some View {
        QuietMenu {
            ForEach(ProjectsModel.statusOrder, id: \.self) { status in
                Button(ProjectsModel.statusTitle(status)) { actions.setStatus(task, status) }
            }
        } label: {
            PanelChip {
                Text(ProjectsModel.statusTitle(task.status))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
        }
        .help("Move to another list")
        .accessibilityLabel("List, \(ProjectsModel.statusTitle(task.status))")
    }

    /// The completion mark, then the title.
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                actions.setStatus(task, task.status == "done" ? "open" : "done")
            } label: {
                ListMarkView(mark: .task(status: task.status), box: 18)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 7 }
            .help(task.status == "done" ? "Mark incomplete" : "Mark complete")
            .accessibilityLabel(task.status == "done" ? "Mark incomplete" : "Mark complete")
            CardTitle(title: $text.title)
        }
    }

    /// Who has it and when it is due, as two chips; a repeat joins them
    /// once there is one.
    private var fields: some View {
        HStack(spacing: 8) {
            QuietMenu {
                ForEach(store.roster) { person in
                    Button(person.id == store.me?.id ? "\(person.name) (you)" : person.name) {
                        actions.assign(task, person.id)
                    }
                }
            } label: {
                PanelChip {
                    CardFace(name: task.ownerName, personId: task.ownerPersonId, size: 20)
                        .padding(.leading, -6)
                    Text(task.ownerName)
                }
            }
            .help("Assign")
            .accessibilityLabel("Owner, \(task.ownerName)")
            Button {
                date = task.dueAt.map(ISO8601.parse) ?? Date()
                isPickingDate = true
            } label: {
                let due = task.dueAt.map { ISO8601.parse($0).formatted(.dateTime.month(.abbreviated).day()) }
                Image(systemName: "calendar").font(.system(size: 12, weight: .medium))
                Text(due ?? "Due date")
                    .foregroundStyle(task.dueAt == nil ? Tokens.Palette.inkSecondary : Tokens.Palette.ink)
            }
            .buttonStyle(PanelButtonStyle())
            .popover(isPresented: $isPickingDate) { datePicker }
            .accessibilityLabel(task.dueAt == nil ? "Add a due date" : "Due date")
            if let label = ProjectsModel.repeatText(ProjectsModel.repeatOption(task)) {
                PanelChip {
                    Image(systemName: "repeat").font(.system(size: 11, weight: .medium))
                    Text(label)
                }
            }
        }
    }

    private var projectLinks: some View {
        CardSection(title: "Projects") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(store.projects.filter { task.associatedProjectIds.contains($0.id) && !$0.isObjective }) { linked in
                    HStack {
                        Button(linked.name) { actions.open(.project(linked.id)) }
                        if linked.id == task.projectId {
                            Text("Primary").foregroundStyle(.secondary)
                        } else {
                            Spacer()
                            Button { changeProjects { $0.filter { $0 != linked.id } } } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("Unlink \(linked.name)")
                        }
                    }
                }
                Menu("Link another project") {
                    ForEach(store.projects.filter { $0.isActive && !$0.isObjective && !task.associatedProjectIds.contains($0.id) }) { candidate in
                        Button(candidate.name) { changeProjects { $0 + [candidate.id] } }
                    }
                }
            }.font(Tokens.Projects.quiet)
        }
    }

    /// The new list is built when the write runs, from the card as the store
    /// holds it then, so a second click before the hub answers keeps the first.
    private func changeProjects(_ change: @escaping ([String]) -> [String]) {
        let task = task
        actions.run { client in
            try await ProjectsTaskWrite.links(
                of: task, change, latest: actions.latestTask,
                send: { try await client.setTaskProjects(id: task.id, projectIds: $0) },
                apply: actions.applyTask)
        }
    }

    /// The card's "…": moving it, its repeat, the thread it came from,
    /// copying, and Delete for its owner or an admin.
    private var cardMenu: some View {
        QuietMenu {
            Menu("Move to Board") {
                ForEach(store.projects.filter { $0.isActive && !$0.isObjective && $0.id != project?.id }) { candidate in
                    Button(candidate.name) { actions.move(task, candidate.id) }
                }

            }
            repeatMenu
            Divider()
            if let origin = task.originConversationId {
                Button("Open Thread") { store.openConversation(origin) }
            }
            Button("Copy Title") { ProjectsPasteboard.copy(task.title) }
            if let ref = task.ref, let number = task.number {
                Button("Copy \(ref)") { ProjectsPasteboard.copy(ref) }
                Button("Copy Link") { ProjectsPasteboard.copy(TaskLink.url(number)) }
            }
            if task.ownerPersonId == store.me?.id || store.me?.isAdmin == true {
                Divider()
                Button("Delete Card", role: .destructive) {
                    let id = task.id
                    ProjectsTaskWrite.delete(close: actions.closeCard, run: actions.run) { try await $0.deleteTask(id: id) }
                }
            }
        } label: {
            PanelMenuGlyph()
        }
        .help("Card actions")
        .accessibilityLabel("Card actions")
    }

    /// Repeat, in the card's "…": the old task page's schedule, written
    /// through the store's one recurrence call. Only the open head of a
    /// series takes a new rule.
    @ViewBuilder private var repeatMenu: some View {
        if ProjectsModel.canChangeRepeat(task) {
            let current = ProjectsModel.repeatOption(task)
            Picker(
                "Repeat",
                selection: Binding(
                    get: { current },
                    set: { option in
                        guard option != current else { return }
                        store.setTaskRecurrence(task, repeat: option)
                    })
            ) {
                ForEach(TaskRepeat.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        }
    }

    private var datePicker: some View {
        VStack(spacing: Tokens.Space.x4) {
            DatePicker("Due date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
            HStack {
                if task.dueAt != nil {
                    Button("Remove") {
                        setDue(nil)
                        isPickingDate = false
                    }
                    .buttonStyle(PanelButtonStyle())
                }
                Spacer()
                Button("Save") {
                    setDue(ISO8601DateFormatter().string(from: date))
                    isPickingDate = false
                }
                .buttonStyle(PanelButtonStyle(isProminent: true))
            }
        }
        .padding(Tokens.Space.x4)
        .frame(width: 320)
        .presentationCompactAdaptation(.popover)
    }

    private func setDue(_ value: String?) {
        actions.run { client in actions.applyTask(try await client.editPlanningTask(id: task.id, fields: ["due_at": value])) }
    }

    /// The description as text; a click edits it in place, Save closes it.
    /// The autosave writes as you type.
    private var description: some View {
        CardSection(title: "Description") {
            if isEditingBody {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Add a description…", text: $text.body, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Tokens.Projects.panelBody)
                        .lineLimit(4...)
                        .focused($isBodyFocused)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tokens.Projects.panelWell, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onAppear { isBodyFocused = true }
                        .accessibilityLabel("Description")
                    Button("Save") {
                        isEditingBody = false
                        text.flush()
                    }
                    .buttonStyle(PanelButtonStyle(isProminent: true))
                    .keyboardShortcut(.return, modifiers: .command)
                }
            } else {
                Text(text.body.isEmpty ? "Add a description…" : text.body)
                    .font(Tokens.Projects.panelBody)
                    .foregroundStyle(text.body.isEmpty ? Tokens.Palette.inkSecondary : Tokens.Palette.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { isEditingBody = true }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { isEditingBody = true }
                    .help("Edit the description")
            }
        }
    }
}

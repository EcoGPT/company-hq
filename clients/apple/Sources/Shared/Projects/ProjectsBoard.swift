import SwiftUI

// A board, the way Trello draws one: a thin bar (back, the name, the member
// faces, Comments, "…"), then lists side by side that scroll sideways — on a phone
// each list is most of the screen and they page. A list is its name and
// count over its cards, with "Add a card" at the foot. The lists are fixed:
// nobody adds one.

// MARK: - Bar

struct BoardBar<Trailing: View, Items: View>: View {
    @Environment(\.projectsPanelInset) private var panelInset
    let title: String
    /// A project's name, renamed in place the way Trello's is; nil for the
    /// boards nobody names (My tasks).
    var editableTitle: Binding<String>?
    var faces: [String] = []
    let onBack: () -> Void
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var menu: Items

    var body: some View {
        HStack(spacing: 12) {
            BarCircleButton(symbol: "chevron.left", label: "Back", action: onBack)
                .keyboardShortcut("[", modifiers: .command)
            if let editableTitle {
                // The name's own width, truncating like the label it
                // replaces when the bar runs short; the field fills it.
                Text(editableTitle.wrappedValue.isEmpty ? "Board name" : editableTitle.wrappedValue)
                    .font(Tokens.Projects.boardName)
                    .lineLimit(1)
                    .hidden()
                    .overlay(alignment: .leading) {
                        TextField("Board name", text: editableTitle)
                            .textFieldStyle(.plain)
                            .font(Tokens.Projects.boardName)
                            .lineLimit(1)
                            .accessibilityLabel("Board name")
                            .accessibilityAddTraits(.isHeader)
                    }
            } else {
                Text(title)
                    .font(Tokens.Projects.boardName)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            if !faces.isEmpty {
                FaceStack(names: faces)
            }
            Spacer(minLength: 0)
            trailing
            if Items.self != EmptyView.self {
                BarMenu { menu }
            }
        }
        .padding(.horizontal, barGutter)
        .frame(height: Tokens.Projects.boardBarHeight)
        .hqGlassContainer()
        .padding(.trailing, panelInset)
    }

    private var barGutter: CGFloat {
        #if os(macOS)
            Tokens.Projects.boardGutter
        #else
            12
        #endif
    }
}

/// The bar's Comments: the board's own "Comments and activity", a bubble
/// and its count on glass, left of the "…". Words beside the bubble where
/// the bar has room (the Mac).
struct BarCommentsButton: View {
    let count: Int
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOpen ? "bubble.left.fill" : "bubble.left")
                    .font(.system(size: 12, weight: .semibold))
                #if os(macOS)
                    Text("Comments")
                #endif
                if count > 0 {
                    Text(count, format: .number).monospacedDigit()
                }
            }
            .font(Tokens.Projects.quiet.weight(.medium))
            .foregroundStyle(Tokens.Palette.ink)
            .padding(.horizontal, 11)
            .frame(minWidth: Tokens.Projects.barButton, minHeight: Tokens.Projects.barButton)
            .hqGlass(in: Capsule(), interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(isOpen ? "Hide comments" : "Comments")
        .accessibilityLabel(count > 0 ? "Comments, \(count)" : "Comments")
    }
}

// MARK: - Lists

extension EnvironmentValues {
    /// How much of the board's right the panel covers. The panel floats
    /// over the lists, casting its shadow on them: the lists run on under
    /// it with that much more room at their end, and the bar stops at it.
    @Entry var projectsPanelInset: CGFloat = 0
    /// The card open in the panel — a task's id — which its board card
    /// wears highlighted.
    @Entry var projectsOpenCardID: String?
}

/// The lists, side by side, scrolling sideways — and, given `onDrop`, the
/// board a card can be dragged across (`ProjectsDrag.swift`).
struct BoardLists<Content: View>: View {
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(\.projectsPanelInset) private var panelInset
    /// Where a dropped card goes; nil on a board nothing drops on.
    var onDrop: ((BoardDragItem, BoardDropSpot) -> Void)?
    @ViewBuilder var content: Content
    @State private var drag = BoardDrag()
    @State private var position = ScrollPosition(edge: .leading)

    private var isPaging: Bool {
        #if os(iOS)
            sizeClass == .compact
        #else
            false
        #endif
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: isPaging ? 10 : Tokens.Projects.listGap) { content }
                .scrollTargetLayout()
                .padding(.top, 4)
                .padding(.bottom, isPaging ? 30 : 24)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .contentMargins(.leading, Tokens.Projects.boardGutter, for: .scrollContent)
        .contentMargins(.trailing, Tokens.Projects.boardGutter + panelInset, for: .scrollContent)
        .modifier(PagingBehavior(isPaging: isPaging))
        .scrollPosition($position)
        // Kept off observation: a scroll redraws nothing.
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }, action: { _, next in drag.scroll = next })
        .modifier(
            BoardDropArea(
                drag: drag, isPaging: isPaging, perform: onDrop, panelInset: panelInset, position: $position)
        )
        .environment(drag)
    }
}

private struct PagingBehavior: ViewModifier {
    let isPaging: Bool

    func body(content: Content) -> some View {
        if isPaging {
            content.scrollTargetBehavior(.viewAligned)
        } else {
            content
        }
    }
}

/// What a list's "Add a card" creates: a task in this status on this board.
struct BoardListAdd {
    let status: String
    let create: (String) -> Void
}

/// A list's foot when it is not "Add a card": the home's "New board".
struct BoardListFooter {
    let symbol: String
    let title: String
    let action: () -> Void
}

/// One list: its name and count, its cards, and "Add a card". It hugs its
/// cards until the board's height runs out, then its cards scroll inside it.
/// The home's lists also wear their category's square, say what the count
/// means, and may open a board from the header.
struct BoardList<Cards: View>: View {
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(BoardDrag.self) private var drag: BoardDrag?
    /// The list's key on its board — a status, a category — which a drag
    /// lands on.
    var id: String
    /// What a drag may drop here; nil for a list that takes nothing.
    var accepts: BoardDragKind?
    let title: String
    let count: Int
    /// The category's square before the name.
    var swatch: Color?
    /// Words in place of the bare count: "50 open", "4 need an owner".
    var note: String?
    var isNoteUrgent = false
    /// A chevron in place of the "…": the whole board this list previews.
    var onOpen: (() -> Void)?
    var add: BoardListAdd?
    var footer: BoardListFooter?
    var width: CGFloat = Tokens.Projects.listWidth
    @ViewBuilder var cards: Cards
    @State private var isAdding = false
    @State private var draft = ""
    @State private var cardsHeight: CGFloat = 0
    @FocusState private var isFieldFocused: Bool

    /// The list a dragged card would land in lights up.
    private var isDropTarget: Bool { drag?.spot?.list == id }

    private var isPaging: Bool {
        #if os(iOS)
            sizeClass == .compact
        #else
            false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // One scroll view that hugs its cards until the board's height
            // runs out — never a swap between two trees, which would drop
            // the card a drag is lifting.
            ScrollView(.vertical) {
                stack.onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { cardsHeight = $0 })
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: cardsHeight)
            if add != nil {
                if isAdding { newCardField } else { addRow }
            } else if let footer {
                footRow(footer)
            }
        }
        .padding(Tokens.Projects.listPadding)
        // A list is glass, its cards solid on it — Trello's columns in
        // Liquid Glass. The one a dragged card is over takes the accent.
        .hqGlass(in: shape, tint: isDropTarget ? Tokens.Palette.accent.opacity(0.16) : .clear)
        .modifier(ListWidth(isPaging: isPaging, width: width))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BoardDrag.space)) } action: { frame in
            drag?.listFrames[id] = frame
            drag?.accepting[id] = accepts
        }
        .onDisappear {
            drag?.listFrames[id] = nil
            drag?.accepting[id] = nil
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Tokens.Projects.listRadius, style: .continuous)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let swatch { CategorySquare(color: swatch) }
            Text(title).font(Tokens.Projects.listTitle).lineLimit(1)
            Group {
                if let note {
                    Text(note)
                } else {
                    Text(count, format: .number)
                }
            }
            .font(Tokens.Projects.listCount)
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(isNoteUrgent ? Tokens.Palette.danger : Tokens.Palette.inkTertiary)
            Spacer(minLength: 0)
            if let onOpen {
                Button(action: onOpen) { headerGlyph("chevron.right") }
                    .buttonStyle(.plain)
                    .help("Open \(title)")
                    .accessibilityLabel("Open \(title)")
            }
        }
        .frame(minHeight: 24)
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    private func headerGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Tokens.Palette.inkSecondary)
            .frame(width: 24, height: 24)
            .contentShape(Circle())
    }

    /// Cards space themselves (their foot padding), so a drag can close
    /// one's place without a seam.
    private var stack: some View {
        VStack(spacing: 0) { cards }
            .padding(.horizontal, 2)
            .padding(.top, 2)
    }

    private var addRow: some View {
        Button {
            isAdding = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text("Add a card")
            }
            .font(Tokens.Projects.addRow)
            .foregroundStyle(Tokens.Palette.inkTertiary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func footRow(_ footer: BoardListFooter) -> some View {
        Button(action: footer.action) {
            HStack(spacing: 6) {
                Image(systemName: footer.symbol).font(.system(size: 11, weight: .bold))
                Text(footer.title).monospacedDigit()
            }
            .font(Tokens.Projects.addRow)
            .foregroundStyle(Tokens.Palette.inkTertiary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Trello's inline card: type a title, Return files it and leaves the
    /// field open for the next; Return on an empty field (or Escape) closes.
    private var newCardField: some View {
        TextField("Enter a title for this card…", text: $draft)
            .textFieldStyle(.plain)
            .font(Tokens.Projects.cardTitle)
            .focused($isFieldFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Tokens.Projects.cardFill, in: RoundedRectangle(cornerRadius: Tokens.Projects.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Projects.cardRadius)
                    .strokeBorder(Tokens.Palette.accent, lineWidth: 1))
            .padding(.horizontal, 2)
            .padding(.top, 2)
            .onAppear { isFieldFocused = true }
            .onSubmit(submit)
            #if os(macOS)
                .onExitCommand { close() }
            #endif
            .onChange(of: isFieldFocused) { _, isFocused in
                if !isFocused && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { close() }
            }
            .accessibilityLabel("New card in \(title)")
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let add else {
            close()
            return
        }
        add.create(text)
        draft = ""
        isFieldFocused = true
    }

    private func close() {
        draft = ""
        isAdding = false
    }
}

private struct ListWidth: ViewModifier {
    let isPaging: Bool
    let width: CGFloat

    func body(content: Content) -> some View {
        if isPaging {
            content.containerRelativeFrame(.horizontal) { width, _ in width * 0.86 }
        } else {
            content.frame(width: width)
        }
    }
}

// MARK: - Cards

/// A card's frame: solid on its list's glass, no hairline, the lift of one
/// pixel; on the Mac a little more under the pointer, and an accent edge on
/// the card whose panel is open.
private struct CardChrome: ViewModifier {
    var isOpen = false
    @State private var isHovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Projects.cardRadius, style: .continuous)
        content
            .padding(.horizontal, Tokens.Projects.cardPaddingH)
            .padding(.top, Tokens.Projects.cardPaddingV)
            .padding(.bottom, Tokens.Projects.cardPaddingV - 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Projects.cardFill, in: shape)
            .overlay {
                if isOpen { shape.strokeBorder(Tokens.Palette.accent, lineWidth: 1.5) }
            }
            .shadow(
                color: .black.opacity(isHovering ? 0.12 : 0.06), radius: isHovering ? 3 : 1,
                y: isHovering ? 2 : 1
            )
            .contentShape(shape)
            #if os(macOS)
                .onHover { isHovering = $0 }
            #endif
    }
}

/// A small count on a card's foot: its comments.
private struct CardBadge: View {
    let symbol: String
    var count: Int?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            if let count { Text(count, format: .number).monospacedDigit() }
        }
        .font(Tokens.Projects.cardMeta)
        .foregroundStyle(Tokens.Palette.inkTertiary)
    }
}

/// A card's `HQ-<n>`: quiet, at the left of its foot.
private struct CardRef: View {
    let ref: String?

    var body: some View {
        if let ref {
            Text(ref)
                .font(Tokens.Projects.cardRef)
                .foregroundStyle(Tokens.Palette.inkTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// A task's card: its title, and a foot of its `HQ-<n>`, its comment count
/// and the owner's face.
struct TaskCard: View {
    let task: TeamTask
    /// My tasks names the board each card came from.
    var project: Project?
    let actions: ProjectsActions
    /// The cards either side in its list, for Move Up / Move Down.
    var above: TeamTask?
    var below: TeamTask?
    /// The lists its board has, for "Move To ▸" — dragging's equivalent
    /// for a menu, a keyboard and VoiceOver.
    var lists: [String] = []
    var moveTo: ((String) -> Void)?
    @Environment(AppStore.self) private var store
    @Environment(\.projectsOpenCardID) private var openCardID

    private var targets: [String] {
        lists.filter { $0 != ProjectsModel.list(of: task) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title)
                .font(Tokens.Projects.cardTitle)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let project {
                BoardLabel(
                    name: project.name, color: ProjectsCategory.color(for: project.planningCategory), isSmall: true)
            }
            HStack(spacing: 8) {
                CardRef(ref: ProjectsModel.cardRef(task))
                if task.commentCount > 0 {
                    CardBadge(symbol: "bubble.left", count: task.commentCount)
                }
                Spacer(minLength: 0)
                CardFace(name: task.ownerName, personId: task.ownerPersonId)
            }
            .frame(minHeight: 22)
        }
        .modifier(CardChrome(isOpen: openCardID == task.id))
        .onTapGesture { actions.open(.task(task.id)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        // The trait promises a press; VoiceOver and keyboard users need it to open.
        .accessibilityAction { actions.open(.task(task.id)) }
        .accessibilityActions {
            if let moveTo {
                ForEach(targets, id: \.self) { list in
                    Button("Move to \(ProjectsModel.statusTitle(list))") { moveTo(list) }
                }
            }
            if let above {
                Button("Move up") { store.reorderTask(task.id, anchorId: above.id, isAfter: false) }
            }
            if let below {
                Button("Move down") { store.reorderTask(task.id, anchorId: below.id, isAfter: true) }
            }
        }
        .taskVerbs(
            task,
            onStatus: { actions.setStatus(task, $0) },
            onAssign: { actions.assign(task, $0) },
            onDelete: { ProjectsTaskWrite.delete(close: {}, run: actions.run) { try await $0.deleteTask(id: task.id) } },
            onMoveUp: above.map { anchor in { store.reorderTask(task.id, anchorId: anchor.id, isAfter: false) } },
            onMoveDown: below.map { anchor in { store.reorderTask(task.id, anchorId: anchor.id, isAfter: true) } },
            moveTargets: moveTo == nil ? [] : targets,
            onMoveTo: moveTo
        )
    }
}

// MARK: - Boards

/// A project's board: To do, In progress, Blocked, Done. Its name renames
/// in place; its Comments open beside it.
struct ProjectBoard: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let actions: ProjectsActions
    /// The name and description, autosaved as the old project page did.
    @Bindable var text: PlanningTextAutosave

    @State private var isEditingTags = false
    private var tasks: [TeamTask] { ProjectsModel.tasks(of: project, in: store.tasks) }
    private var isShowingComments: Bool { store.projectsPath.last == .projectComments(project.id) }

    var body: some View {
        // The board's cards once per body; each list filters these.
        let held = tasks
        VStack(spacing: 0) {
            BoardBar(
                title: project.name, editableTitle: $text.title,
                onBack: actions.back
            ) {
                BarCommentsButton(count: project.commentCount ?? 0, isOpen: isShowingComments) {
                    if isShowingComments {
                        actions.closeCard()
                    } else {
                        actions.open(.projectComments(project.id))
                    }
                }
            } menu: {
                menu
            }
            if let error = text.error {
                HStack {
                    Text(error).font(Tokens.Projects.quiet).foregroundStyle(Tokens.Palette.danger)
                    Button("Retry") { text.flush() }.buttonStyle(.plain).foregroundStyle(Tokens.Palette.accent)
                }
                .padding(.horizontal, Tokens.Projects.boardGutter)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            BoardLists(onDrop: drop) {
                ForEach(ProjectsModel.statusOrder, id: \.self) { status in
                    let cards = Self.cards(in: status, from: held)
                    let positions = Self.positions(of: cards)
                    BoardList(
                        id: status, accepts: .task, title: ProjectsModel.statusTitle(status), count: cards.count,
                        add: status == "done" || !project.isActive ? nil : add(status)
                    ) {
                        BoardCardStack(list: status, items: cards, kind: .task) { task in
                            // Done sorts by when, so only the working lists reorder.
                            let isOrdered = status != "done"
                            let index = positions[task.id] ?? 0
                            TaskCard(
                                task: task, actions: actions,
                                above: isOrdered && index > 0 ? cards[index - 1] : nil,
                                below: isOrdered && index + 1 < cards.count ? cards[index + 1] : nil,
                                lists: ProjectsModel.statusOrder,
                                moveTo: { list in move(task, to: list) })
                        }
                    }
                }
            }
        }
        .onAppear {
            text.receive(.init(title: project.name, body: project.body ?? ""))
            text.flush()
        }
        .onDisappear { text.flush() }
        .onChange(of: PlanningTextValue(title: project.name, body: project.body ?? "")) { _, value in
            text.receive(value)
        }
        .sheet(isPresented: $isEditingTags) { ProjectTagsSheet(project: project, actions: actions) }
    }

    private func cards(in status: String) -> [TeamTask] {
        Self.cards(in: status, from: tasks)
    }

    /// One list's cards out of the board's: Done newest first, the working
    /// lists in the hub's order.
    static func cards(in status: String, from held: [TeamTask]) -> [TeamTask] {
        let rows = held.filter { ProjectsModel.list(of: $0) == status }
        return status == "done" ? rows.sorted { $0.touchedDate > $1.touchedDate } : rows
    }

    /// Each card's place in its list, looked up once per list rather than
    /// searched for once per card. A repeated id keeps its first place.
    static func positions(of cards: [TeamTask]) -> [String: Int] {
        Dictionary(cards.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func add(_ status: String) -> BoardListAdd {
        BoardListAdd(status: status) { title in
            actions.createCard(title, status, project.id, store.defaultOwner(lead: project.ownerPersonId) ?? project.ownerPersonId)
        }
    }

    private func drop(_ item: BoardDragItem, _ spot: BoardDropSpot) {
        guard let task = tasks.first(where: { $0.id == item.id }),
            let drop = ProjectsModel.taskDrop(task, into: spot.list, at: spot.index, cards: cards(in: spot.list))
        else { return }
        actions.dropTask(task, drop)
    }

    private func move(_ task: TeamTask, to list: String) {
        guard let drop = ProjectsModel.taskMove(task, to: list, cards: cards(in: list)) else { return }
        actions.dropTask(task, drop)
    }

    /// The board's own verbs: stage, lead, category, complete, delete.
    @ViewBuilder private var menu: some View {
        Menu("Activity") {
            ForEach(["Now", "Next", "Backlog"], id: \.self) { state in
                Button(state == "Now" ? "Active" : state == "Next" ? "Maintained" : "Paused") { actions.patchProject(project, ["status": "active", "planning_state": state]) }
            }
        }
        Menu("Lead") {
            ForEach(store.roster) { person in
                Button(person.name) { actions.patchProject(project, ["owner_person_id": person.id]) }
            }
        }
        Button("Edit Tags") { isEditingTags = true }
        Divider()
        Button(project.status == "done" ? "Reopen Board" : "Complete Board") {
            actions.patchProject(project, ["status": project.status == "done" ? "active" : "done"])
        }
        .disabled(project.status != "done" && project.openTasks > 0)
        Button("Delete Board", role: .destructive) { actions.deleteProject(project) }
    }
}

/// My tasks as a board: every open card I own, in every project. Nothing is
/// hidden by a project's planning state.
struct MyTasksBoard: View {
    @Environment(AppStore.self) private var store
    let actions: ProjectsActions

    var body: some View {
        let owner = store.me?.id ?? ""
        let open = ProjectsModel.mine(store.tasks, projects: store.projects, owner: owner)
        VStack(spacing: 0) {
            BoardBar(title: "My tasks", onBack: actions.back) {
                EmptyView()
            } menu: {
                Button("Refresh") { actions.refresh() }
            }
            BoardLists(onDrop: dropper(open: open)) {
                ForEach(Self.lists, id: \.self) { status in
                    let cards = cards(in: status, open: open)
                    let positions = ProjectBoard.positions(of: cards)
                    BoardList(
                        id: status, accepts: .task, title: ProjectsModel.statusTitle(status), count: cards.count,
                        add: status == "blocked" ? nil : add(status, owner: owner)
                    ) {
                        BoardCardStack(list: status, items: cards, kind: .task) { task in
                            let index = positions[task.id] ?? 0
                            TaskCard(
                                task: task, project: store.projects.first { $0.id == task.projectId },
                                actions: actions, above: index > 0 ? cards[index - 1] : nil,
                                below: index + 1 < cards.count ? cards[index + 1] : nil,
                                lists: Self.lists + ["done"], moveTo: { list in move(task, to: list, open: open) })
                        }
                    }
                }
            }
        }
    }

    /// My tasks' lists: what is open, by status. Done leaves the board.
    private static let lists = ["open", "in_progress", "blocked"]

    private func cards(in status: String, open: [TeamTask]) -> [TeamTask] {
        open.filter { ProjectsModel.list(of: $0) == status }
    }

    private func add(_ status: String, owner: String) -> BoardListAdd {
        BoardListAdd(status: status) { title in actions.createCard(title, status, nil, owner) }
    }

    private func dropper(open: [TeamTask]) -> (BoardDragItem, BoardDropSpot) -> Void {
        { item, spot in drop(item, spot, open: open) }
    }

    private func drop(_ item: BoardDragItem, _ spot: BoardDropSpot, open: [TeamTask]) {
        guard Self.lists.contains(spot.list), let task = open.first(where: { $0.id == item.id }),
            let drop = ProjectsModel.taskDrop(
                task, into: spot.list, at: spot.index, cards: cards(in: spot.list, open: open))
        else { return }
        actions.dropTask(task, drop)
    }

    private func move(_ task: TeamTask, to list: String, open: [TeamTask]) {
        guard let drop = ProjectsModel.taskMove(task, to: list, cards: cards(in: list, open: open)) else { return }
        actions.dropTask(task, drop)
    }
}
